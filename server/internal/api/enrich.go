package api

import (
	"bufio"
	"cmp"
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"maps"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"aria/internal/enrich"
	"aria/internal/repo"
)

func init() { register(registerEnrich) }

// imgClient fetches external portraits; short timeout so a slow CDN can't pin
// a request goroutine.
var imgClient = &http.Client{Timeout: 15 * time.Second}

// serveCachedImg serves a proxied image off disk; false when the file is
// absent, empty, or older than ttl (ttl 0 = never stale), which tells the
// caller to re-fetch. maxAge is the client-side cache window in seconds, and
// must not outlive ttl or the browser keeps showing what the server expired.
// Content-Type is sniffed by ServeContent (jpeg/png/webp).
func serveCachedImg(w http.ResponseWriter, r *http.Request, path string, ttl time.Duration, maxAge int) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || fi.IsDir() || fi.Size() == 0 {
		return false
	}
	if ttl > 0 && time.Since(fi.ModTime()) > ttl {
		return false
	}
	w.Header().Set("Cache-Control", fmt.Sprintf("public, max-age=%d", maxAge))
	w.Header().Set("ETag", fmt.Sprintf(`"%x-%x"`, fi.ModTime().UnixNano(), fi.Size()))
	http.ServeContent(w, r, filepath.Base(path), fi.ModTime(), f)
	return true
}

// cacheRemoteImg fetches src and writes it to dst atomically. Verifies the
// payload really is an image (a 200 HTML error page would otherwise be cached
// and served forever). maxArtBytes cap shared with the upload path.
func cacheRemoteImg(ctx context.Context, src, dst string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, src, nil)
	if err != nil {
		return err
	}
	resp, err := imgClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("upstream %d", resp.StatusCode)
	}
	body := bufio.NewReader(io.LimitReader(resp.Body, maxArtBytes))
	head, _ := body.Peek(512)
	if !strings.HasPrefix(http.DetectContentType(head), "image/") {
		return fmt.Errorf("not an image")
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), "*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := io.Copy(tmp, body); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), dst)
}

// peopleIdx is the memoized portrait index behind /api/people.
type peopleIdx struct {
	urls  map[string]string        // name -> portrait URL, what /api/people serves
	local map[string]repo.LocalArt // name -> the library's own image it points at
}

// people builds name -> portrait URL: an edited portrait, else the library's
// own image, else the enrichment cache's. Memoized: recompute scans every
// artist+composer cache blob, and InvalidateTracks drops it whenever an edit,
// scan or enrichment pass lands.
func people(ctx context.Context, d *Deps) (peopleIdx, error) {
	return d.people.get(time.Minute, func() (peopleIdx, error) {
		idx := peopleIdx{urls: map[string]string{}, local: map[string]repo.LocalArt{}}
		if we, ok := d.Enricher.(warmEnricher); ok {
			m, err := we.People(ctx)
			if err != nil {
				return idx, err
			}
			idx.urls = m
		}
		// raw names come with a Latin spelling the app asks under instead
		var latin map[string]string
		if ln, ok := d.Enricher.(latinNamer); ok {
			latin, _ = ln.LatinNames(ctx)
		}
		// a library image goes under the album artist tag its folder belongs
		// to, and under what an album edit or a MusicBrainz correction renames
		// that artist to. Not under the classical display artist the album may
		// be shown with: that is the lead performer, another person entirely.
		local, err := d.Albums.LocalArts(ctx, "artist")
		if err != nil {
			return idx, err
		}
		if len(local) > 0 {
			fixes, err := d.EnrichCache.ListKind(ctx, "album")
			if err != nil {
				return idx, err
			}
			edits, err := d.Edits.ListKind(ctx, "album")
			if err != nil {
				return idx, err
			}
			file := func(n string, a repo.LocalArt) {
				for _, n := range []string{n, latin[n]} {
					if n != "" {
						idx.urls[n], idx.local[n] = localPortraitURL(n, a), a
					}
				}
			}
			for _, id := range slices.Sorted(maps.Keys(local)) { // sorted: one winner per name
				a := local[id]
				file(a.Name, a)
				var fix, ed struct {
					AlbumArtist string `json:"albumArtist"`
				}
				json.Unmarshal(fixes[id], &fix)
				json.Unmarshal(edits[id], &ed)
				if n := cmp.Or(ed.AlbumArtist, fix.AlbumArtist); n != "" {
					file(n, a)
				}
			}
		}
		// edited portraits win; keyed by the raw name, so the Latin one too
		artists, err := d.Edits.ListKind(ctx, "artist")
		if err != nil {
			return idx, err
		}
		for n, raw := range artists {
			var e struct {
				Image string `json:"image"`
			}
			if json.Unmarshal(raw, &e) == nil && e.Image != "" {
				idx.urls[n] = e.Image
				if l := latin[n]; l != "" {
					idx.urls[l] = e.Image
				}
			}
		}
		return idx, nil
	})
}

// localPortrait is the URL of the library's own image for an artist asked for
// under any of names (as shown, as stored); ok false when there is none.
func localPortrait(ctx context.Context, d *Deps, names ...string) (string, bool) {
	idx, err := people(ctx, d)
	if err != nil {
		return "", false
	}
	for _, n := range names {
		if a, ok := idx.local[n]; ok {
			return localPortraitURL(n, a), true
		}
	}
	return "", false
}

// localPortraitURL is the server-relative URL /api/people and /api/artist
// carry for an artist image found in the library; the app resolves it against
// its server. v changes when the file does, so a replaced image reloads.
func localPortraitURL(name string, a repo.LocalArt) string {
	return "/api/people/img/" + url.PathEscape(name) + "?v=" + strconv.FormatInt(a.Mtime, 36)
}

// warmEnricher is the people/warm-up surface beyond Deps.Enricher (matched
// structurally by *enrich.Enricher, like onDemandEnricher in library.go).
type warmEnricher interface {
	People(ctx context.Context) (map[string]string, error)
	Warm(names []string) int
}

// The concrete enricher must satisfy every optional surface route files
// assert structurally — a signature drift is a compile error here, not a
// silent cache-only downgrade at runtime.
var (
	_ onDemandEnricher = (*enrich.Enricher)(nil)
	_ warmEnricher     = (*enrich.Enricher)(nil)
	_ latinNamer       = (*enrich.Enricher)(nil)
	_ identifier       = (*enrich.Enricher)(nil)
	_ artPreviewer     = (*enrich.Enricher)(nil)
)

// registerEnrich mounts the legacy enrichment group: status polling, manual
// re-kick, the bulk portrait map, and viewport-driven warm-up
// (server.js:286-312).
func registerEnrich(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/enrich/status", func(w http.ResponseWriter, r *http.Request) {
		if d.Enricher == nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, d.Enricher.Status())
	})

	// legacy kickEnrich(): fire-and-forget (single-flight inside Run), then
	// report status immediately.
	mux.HandleFunc("POST /api/enrich", func(w http.ResponseWriter, r *http.Request) {
		if d.Enricher == nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		d.GoBg(func(ctx context.Context) {
			if err := d.Enricher.Run(ctx); err != nil {
				log.Printf("enrich: %v", err)
			}
			d.InvalidateTracks() // enrichment feeds credits/hasArt into the merge
		})
		writeJSON(w, http.StatusOK, d.Enricher.Status())
	})

	mux.HandleFunc("GET /api/people", func(w http.ResponseWriter, r *http.Request) {
		idx, err := people(r.Context(), d)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, idx.urls)
	})

	// Portrait proxy: the map holds external CDN URLs (Deezer/Wikimedia).
	// Loading dozens straight from the app bursts those hosts and a random
	// subset drops each render. Fetch once, cache to DATA_DIR/people/, and
	// serve from the LAN like album art. A library image is served straight
	// from the music dir. 404 -> app shows initials.
	mux.HandleFunc("GET /api/people/img/{name}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if name == "" || utf8.RuneCountInString(name) > 200 {
			notFound(w)
			return
		}
		idx, err := people(r.Context(), d)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		src := idx.urls[name]
		if src == "" {
			notFound(w)
			return
		}
		if strings.HasPrefix(src, "/") { // localPortraitURL: the library's own image
			a, ok := idx.local[name]
			if !ok || !serveArtFile(w, r, filepath.Join(d.Cfg.MusicDir, a.Path)) {
				notFound(w)
			}
			return
		}
		// Key by source URL: a re-identified/edited portrait has a new URL, so
		// it lands in a fresh slot instead of serving the old file forever. The
		// app versions its proxy URL by the /api/people value for the same
		// reason on its side.
		sum := sha1.Sum([]byte(src))
		path := filepath.Join(d.Cfg.DataDir, "people", hex.EncodeToString(sum[:])+".jpg")
		if serveCachedImg(w, r, path, 0, 31536000) {
			return
		}
		if err := cacheRemoteImg(r.Context(), src, path); err != nil {
			notFound(w)
			return
		}
		serveCachedImg(w, r, path, 0, 31536000)
	})

	// warm faces/bios for names currently on the user's screen
	mux.HandleFunc("POST /api/enrich/people", func(w http.ResponseWriter, r *http.Request) {
		body, ok := bodyMap(w, r)
		if !ok {
			return
		}
		raw, _ := body["names"].([]any) // non-array reads as [] (legacy Array.isArray)
		var names []string
		for _, v := range raw {
			if s, isStr := v.(string); isStr && utf8.RuneCountInString(s) < 200 {
				names = append(names, s)
				if len(names) == 50 {
					break
				}
			}
		}
		queued := 0
		if we, ok := d.Enricher.(warmEnricher); ok {
			queued = we.Warm(names)
		}
		writeJSON(w, http.StatusOK, map[string]int{"queued": queued})
	})
}
