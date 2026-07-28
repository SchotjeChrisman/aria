package api

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"aria/internal/enrich"
)

func init() { register(registerExtAlbum) }

// ponytail: infused album data — text and cover alike — is cached 30 days.
// There is no background refresh loop in this server, so the TTL is only
// honoured on demand, inside the handler (same shape as registerEq).
const (
	extAlbumTTL = 30 * 24 * time.Hour
	extArtTTL   = 30 * 24 * time.Hour
)

var (
	extDeezer = enrich.NewDeezer()
	extMB     = enrich.NewMB()
)

// extAlbum is an album nobody in this library owns: identity plus everything
// the detail page renders. ID is the universal key — "rg:<release-group mbid>"
// when MusicBrainz knows the record, "dz:<deezer id>" until it does.
type extAlbum struct {
	ID       string            `json:"id"`
	RGMbid   string            `json:"rgMbid,omitempty"`
	UPC      string            `json:"upc,omitempty"`
	DeezerID int64             `json:"deezerId,omitempty"`
	Artist   string            `json:"artist"`
	Title    string            `json:"title"`
	Cover    *string           `json:"cover"`
	Date     string            `json:"date"`
	Type     string            `json:"type"`
	Label    string            `json:"label,omitempty"`
	Link     string            `json:"link,omitempty"`
	Tracks   []enrich.ExtTrack `json:"tracks"`

	// Releases are the MusicBrainz release MBIDs in the group. A rip is tagged
	// with one specific release, so this set is what proves the album has
	// arrived in the library, whichever edition was bought.
	Releases []string `json:"releases,omitempty"`
}

// extKey is the cache key for a lookup by name. Entries are keyed by what the
// caller asked for, not by the id they resolve to, so a resolution that fails
// today and succeeds next month replaces itself in place.
func extKey(artist, title string) string {
	return strings.ToLower(artist) + "\x00" + normTitle(title)
}

// resolveExtAlbum walks Deezer -> UPC -> MusicBrainz to a universal identity,
// serving a cached answer when one is less than 30 days old. deezerID may be 0
// (the caller's discography blob predates the id being kept), in which case it
// falls back to a name search.
//
// Never caches a failure: a transient Deezer outage must not become a
// permanent "this album does not exist" the way the enrich_cache "null"
// negative entries do.
func resolveExtAlbum(ctx context.Context, d *Deps, artist, title string, deezerID int64) (*extAlbum, error) {
	key := extKey(artist, title)
	cached, at, ok, err := d.EnrichCache.GetFetched(ctx, "extAlbum", key)
	if err != nil {
		return nil, err
	}
	fresh := false
	if ok {
		if t, perr := time.Parse("2006-01-02T15:04:05.000Z", at); perr == nil && time.Since(t) < extAlbumTTL {
			fresh = true
		}
	}
	var prev *extAlbum
	if ok {
		var p extAlbum
		if json.Unmarshal(cached, &p) == nil && p.ID != "" {
			prev = &p
			if fresh {
				return prev, nil
			}
		}
	}

	out, ferr := fetchExtAlbum(ctx, artist, title, deezerID)
	if ferr != nil || out == nil {
		if prev != nil {
			return prev, nil // stale beats nothing
		}
		return nil, ferr
	}
	doc, err := json.Marshal(out)
	if err != nil {
		return nil, err
	}
	if err := d.EnrichCache.Put(ctx, "extAlbum", key, doc, isoNow()); err != nil {
		return nil, err
	}
	return out, nil
}

// fetchExtAlbum does the network work: Deezer album detail for the content and
// the UPC, then MusicBrainz for the release-group identity. Returns (nil, nil)
// when Deezer has never heard of the album, which is the one case where there
// is genuinely nothing to show.
func fetchExtAlbum(ctx context.Context, artist, title string, deezerID int64) (*extAlbum, error) {
	if deezerID == 0 {
		id, err := extDeezer.AlbumID(ctx, artist, title)
		if err != nil {
			return nil, err
		}
		deezerID = id
	}
	if deezerID == 0 {
		return nil, nil
	}
	da, err := extDeezer.Album(ctx, deezerID)
	if err != nil {
		return nil, err
	}
	if da == nil {
		return nil, nil
	}

	out := &extAlbum{
		DeezerID: da.DeezerID, UPC: da.UPC, Artist: da.Artist, Title: da.Title,
		Cover: da.Cover, Date: da.Date, Type: da.Type, Label: da.Label,
		Link: da.Link, Tracks: da.Tracks,
	}
	if out.Artist == "" {
		out.Artist = artist
	}
	if out.Tracks == nil {
		out.Tracks = []enrich.ExtTrack{}
	}

	// Barcode first — it is the field Deezer, MusicBrainz and Qobuz all carry,
	// so it is the only thing that can bridge the three. Name search is the
	// fallback for catalogue rows with no UPC.
	rg := extMB.ReleaseGroupByBarcode(ctx, da.UPC)
	if rg == "" {
		year := ""
		if len(da.Date) >= 4 {
			year = da.Date[:4]
		}
		rg = extMB.ReleaseGroupByName(ctx, out.Artist, out.Title, year)
	}
	if rg != "" {
		out.RGMbid = rg
		out.ID = "rg:" + rg
		out.Releases = extMB.ReleasesInGroup(ctx, rg)
	} else {
		// MusicBrainz lags streaming by days to weeks, and this feature lives
		// in exactly that window. A Deezer-keyed entry still works; the 30-day
		// refresh re-attempts the MBID.
		out.ID = "dz:" + strconv.FormatInt(da.DeezerID, 10)
	}
	return out, nil
}

// coverHosts are the CDNs album covers legitimately come from. The proxy
// refuses everything else: it takes a URL from the client, so without this it
// would fetch any address the server can reach, including link-local metadata
// endpoints and hosts behind the LAN.
var coverHosts = []string{
	"cdn-images.dzcdn.net",
	"e-cdns-images.dzcdn.net",
	"api.deezer.com",
	"coverartarchive.org",
	"archive.org",
}

func allowedCoverHost(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" {
		return false
	}
	host := strings.ToLower(u.Hostname())
	for _, h := range coverHosts {
		if host == h || strings.HasSuffix(host, "."+h) {
			return true
		}
	}
	return false
}

func registerExtAlbum(mux *http.ServeMux, d *Deps) {
	// Album detail for something not in the library — the discovery counterpart
	// of /api/artist/{name}, and keyed the same human-readable way so the app
	// can route to it with what a shelf card already holds.
	mux.HandleFunc("GET /api/extalbum", func(w http.ResponseWriter, r *http.Request) {
		artist, title := r.URL.Query().Get("artist"), r.URL.Query().Get("title")
		if artist == "" || title == "" {
			httpError(w, http.StatusBadRequest, "artist and title required")
			return
		}
		dzID, _ := strconv.ParseInt(r.URL.Query().Get("deezerId"), 10, 64)
		a, err := resolveExtAlbum(r.Context(), d, artist, title, dzID)
		if err != nil {
			httpError(w, http.StatusBadGateway, "lookup failed: "+err.Error())
			return
		}
		if a == nil {
			notFound(w)
			return
		}
		writeJSON(w, http.StatusOK, a)
	})

	// Cover proxy. Same reasoning as the portrait proxy: these are CDN URLs,
	// and loading dozens straight from the app bursts that host.
	//
	// Takes the cover URL the caller already holds and does NO identity
	// resolution — a shelf of 20 cards would otherwise be 20 resolve chains,
	// each queueing behind MusicBrainz's 1 req/s limit, just to draw
	// thumbnails. The host allowlist is what keeps that safe: without it, a
	// URL parameter would make this an open proxy onto the server's network.
	mux.HandleFunc("GET /api/extalbum/img", func(w http.ResponseWriter, r *http.Request) {
		src := r.URL.Query().Get("u")
		if !allowedCoverHost(src) {
			notFound(w)
			return
		}
		sum := sha1.Sum([]byte(src))
		dir := filepath.Join(d.Cfg.DataDir, "extart")
		path := filepath.Join(dir, hex.EncodeToString(sum[:])+".jpg")
		// max-age tracks the server TTL: a one-year client cache would keep
		// showing a cover the server had already expired.
		const maxAge = int(extArtTTL / time.Second)
		if serveCachedImg(w, r, path, extArtTTL, maxAge) {
			return
		}
		if err := cacheRemoteImg(r.Context(), src, path); err != nil {
			// Stale beats nothing when the CDN is down or the URL has rotated.
			if serveCachedImg(w, r, path, 0, maxAge) {
				return
			}
			notFound(w)
			return
		}
		sweepCache(dir, int64(d.Cfg.ExtArtCacheMB)<<20, path, ".jpg")
		serveCachedImg(w, r, path, extArtTTL, maxAge)
	})
}
