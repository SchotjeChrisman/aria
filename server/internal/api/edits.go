package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"os"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"

	"aria/internal/enrich"
	"aria/internal/repo"
)

// identifier is the enricher surface the identify endpoints need beyond
// api.Enricher (matched structurally by *enrich.Enricher). mbid == "" means
// "no pin, fresh search". Reidentify results: nil or literal "null" means
// "re-enrichment yielded nothing" — handlers send {}.
type identifier interface {
	IdentifyArtist(ctx context.Context, name string) ([]enrich.ArtistCandidate, error)
	ReidentifyArtist(ctx context.Context, name, mbid string) (json.RawMessage, error)
	IdentifyAlbum(ctx context.Context, ts []repo.Track) ([]enrich.AlbumCandidate, error)
	ReidentifyAlbum(ctx context.Context, albumID string, ts []repo.Track, mbid string) (json.RawMessage, error)
}

// unmatcher is the enricher surface the state revert needs (matched
// structurally by *enrich.Enricher, like identifier above). local=true drops the
// album's derived MusicBrainz layer and marks it settled; false drops it with no
// marker so the next pass re-derives.
type unmatcher interface {
	SetLocal(ctx context.Context, albumID string, ts []repo.Track, local bool) error
}

// derivedAlbum reads one album's enrich_cache `album` blob — the derived layer.
// Returns nil when the album was never enriched or the blob is the literal null.
func derivedAlbum(ctx context.Context, d *Deps, albumID string) map[string]any {
	raw, found, err := d.EnrichCache.Get(ctx, "album", albumID)
	if err != nil || !found {
		return nil
	}
	var m map[string]any
	if json.Unmarshal(raw, &m) != nil {
		return nil
	}
	return m
}

// matchSource describes where an album's derived corrections came from, for the
// editor's provenance line. ONE object per entity, not per field: every
// corrected field on an album came from the same release, so per-field
// provenance would be a dozen copies of one sentence.
//
// nil unless the derived layer is actually being applied — the album blob must
// carry the very release MBID the decision names. A `review` decision, an album
// the user pushed to `local`, and an unenriched album therefore all report no
// source, which is right: in each case nothing derived is showing.
//
// recordingMbid is the track-level addition; "" omits it.
func matchSource(ctx context.Context, d *Deps, albumID, recordingMbid string) map[string]any {
	mbid, _ := derivedAlbum(ctx, d, albumID)["mbid"].(string)
	if mbid == "" {
		return nil
	}
	dec, ok, err := d.Matches.Get(ctx, albumID)
	if err != nil || !ok || dec.ReleaseMbid == nil || *dec.ReleaseMbid != mbid {
		return nil
	}
	// The release title is only in the stored candidate set — a pinned decision
	// has none, and then the client falls back to showing the MBID.
	title := ""
	var cands []struct {
		Mbid  string `json:"mbid"`
		Title string `json:"title"`
	}
	json.Unmarshal(dec.Candidates, &cands)
	for _, c := range cands {
		if c.Mbid == mbid {
			title = c.Title
			break
		}
	}
	src := map[string]any{
		"kind": "musicbrainz", "releaseMbid": mbid, "releaseTitle": title,
		"distance": dec.Distance, "separation": dec.Separation,
		"decidedAt": dec.DecidedAt, "pinned": dec.Pinned,
	}
	if recordingMbid != "" {
		src["recordingMbid"] = recordingMbid
	}
	return src
}

// nullish reports a nil-or-"null" cache/reidentify blob.
func nullish(raw json.RawMessage) bool {
	return raw == nil || bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

// DB overrides: beat file tags + enrichment; null clears one field.
var editFields = map[string][]string{
	"track": {"title", "artist", "album", "albumArtist", "genre", "year", "trackNo", "discNo",
		"composer", "work", "movement", "conductor", "orchestra"},
	"album": {"album", "albumArtist", "genre", "year", "releaseType", "label", "date", "country", "catno", "blurb", "artSource",
		"state", "disambiguation", "locked"},
	"artist": {"type", "area", "born", "died", "image", "bio"},
}

var (
	intEdits     = []string{"year", "trackNo", "discNo"}
	boolEdits    = []string{"locked"}
	longEdits    = []string{"bio", "blurb"}
	releaseTypes = []string{"Album", "EP", "Single", "Live", "Compilation"}
	// "local" means: user metadata is authoritative, no MusicBrainz entity.
	// Phase 4 routes albums here automatically too, but a state set HERE is the
	// user's and outranks the matcher's — repo.Matches.PendingAlbums excludes
	// any album whose edits carry state=local or locked, so a user `local` is
	// permanent while a machine one retries on backoff. "review" is settable so
	// a user can push a wrong-looking match back into the queue.
	albumStates = []string{"matched", "review", "local"}

	mbidRE = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

// cleanEdits ports legacy validation: any unknown field or bad value rejects
// the whole patch (nil). null values pass through as nil (field clear).
func cleanEdits(body map[string]json.RawMessage, kind string) map[string]any {
	if len(body) == 0 {
		return nil
	}
	out := map[string]any{}
	for k, v := range body {
		if !slices.Contains(editFields[kind], k) {
			return nil
		}
		if bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
			out[k] = nil
			continue
		}
		switch {
		case slices.Contains(intEdits, k):
			var f float64
			if json.Unmarshal(v, &f) != nil || f != math.Trunc(f) || f < 0 || f > 3000 {
				return nil
			}
			out[k] = int(f)
		case slices.Contains(boolEdits, k):
			var b bool
			if json.Unmarshal(v, &b) != nil {
				return nil
			}
			out[k] = b
		case k == "releaseType":
			var s string
			if json.Unmarshal(v, &s) != nil || !slices.Contains(releaseTypes, s) {
				return nil
			}
			out[k] = s
		case k == "state":
			var s string
			if json.Unmarshal(v, &s) != nil || !slices.Contains(albumStates, s) {
				return nil
			}
			out[k] = s
		default:
			max := 300
			if slices.Contains(longEdits, k) {
				max = 4000
			}
			var s string
			if json.Unmarshal(v, &s) != nil || strings.TrimSpace(s) == "" || utf8.RuneCountInString(s) > max {
				return nil
			}
			out[k] = strings.TrimSpace(s)
		}
	}
	return out
}

// patchEdits merges patch over the stored override map, drops nulled fields,
// persists (or deletes the row when empty) and returns the survivors — the
// legacy PATCH response is the override map, never the entity.
func patchEdits(ctx context.Context, d *Deps, kind, key string, patch map[string]any) (map[string]any, error) {
	cur := map[string]any{}
	raw, err := d.Edits.Get(ctx, kind, key)
	if err != nil {
		return nil, err
	}
	if raw != nil {
		if err := json.Unmarshal(raw, &cur); err != nil {
			return nil, err
		}
	}
	for k, v := range patch {
		cur[k] = v
	}
	for k, v := range cur {
		if v == nil {
			delete(cur, k)
		}
	}
	if len(cur) == 0 {
		return cur, d.Edits.Delete(ctx, kind, key)
	}
	doc, err := json.Marshal(cur)
	if err != nil {
		return nil, err
	}
	return cur, d.Edits.Put(ctx, kind, key, doc)
}

// prepareArtSource validates and effects an album artSource patch in place:
// rejects unknown values, forbids "file" without embedded art, fetches+writes
// the .api.jpg slot when picking "api" (if absent), and injects the bumped
// artVersion (backend-owned, never client-set). Returns (0,"") on success or an
// HTTP status+message. A nil value (clear override) only bumps the version.
func prepareArtSource(ctx context.Context, d *Deps, id string, ts []repo.Track, patch map[string]any) (int, string) {
	if v := patch["artSource"]; v != nil {
		s, ok := v.(string)
		if !ok || !slices.Contains([]string{"file", "api", "custom"}, s) {
			return http.StatusBadRequest, "invalid artSource"
		}
		switch s {
		case "file":
			if !embeddedArtPresent(d.Cfg.DataDir, id) {
				return http.StatusBadRequest, "no embedded art"
			}
		case "api":
			p := artSlotPath(d.Cfg.DataDir, id, "api")
			if _, err := os.Stat(p); errors.Is(err, os.ErrNotExist) {
				ap, ok := d.Enricher.(artPreviewer)
				if !ok {
					return http.StatusBadGateway, "art fetch failed"
				}
				img := ap.AlbumArt(ctx, ts[0].AlbumArtist, ts[0].Album, mbidOf(ts))
				if img == nil {
					return http.StatusBadGateway, "art fetch failed"
				}
				if err := os.WriteFile(p, img, 0o644); err != nil {
					return http.StatusInternalServerError, "art write failed"
				}
			}
		}
	}
	_, ver := albumArtMeta(ctx, d, id)
	patch["artVersion"] = ver + 1
	return 0, ""
}

// editsBody reads and validates a PATCH body; nil means a 400 was written.
func editsBody(w http.ResponseWriter, r *http.Request, kind string) map[string]any {
	var body map[string]json.RawMessage
	if err := readJSON(w, r, &body); err != nil {
		httpError(w, http.StatusBadRequest, "invalid edits")
		return nil
	}
	patch := cleanEdits(body, kind)
	if patch == nil {
		httpError(w, http.StatusBadRequest, "invalid edits")
		return nil
	}
	return patch
}

func init() { register(registerEdits) }

func registerEdits(mux *http.ServeMux, d *Deps) {
	applyPatch := func(w http.ResponseWriter, r *http.Request, kind, key string, patch map[string]any) {
		cur, err := patchEdits(r.Context(), d, kind, key, patch)
		if err != nil {
			fail(w, err)
			return
		}
		d.InvalidateTracks() // track/album edits feed the merged /api/tracks view
		writeJSON(w, http.StatusOK, cur)
	}

	mux.HandleFunc("PATCH /api/tracks/{id}", func(w http.ResponseWriter, r *http.Request) {
		t, err := d.Tracks.ByID(r.Context(), r.PathValue("id"))
		if err != nil {
			fail(w, err)
			return
		}
		if t == nil {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		if patch := editsBody(w, r, "track"); patch != nil {
			applyPatch(w, r, "track", t.ID, patch)
		}
	})

	mux.HandleFunc("PATCH /api/albums/{albumId}", func(w http.ResponseWriter, r *http.Request) {
		ts, err := d.Tracks.ByAlbum(r.Context(), r.PathValue("albumId"))
		if err != nil {
			fail(w, err)
			return
		}
		if len(ts) == 0 {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		if patch := editsBody(w, r, "album"); patch != nil {
			if _, ok := patch["artSource"]; ok {
				if code, msg := prepareArtSource(r.Context(), d, r.PathValue("albumId"), ts, patch); code != 0 {
					httpError(w, code, msg)
					return
				}
			}
			// A state change is a verdict about identity, so it takes effect now
			// rather than at the next enrichment pass — the user who just said
			// "this isn't in MusicBrainz" expects the wrong title to be gone when
			// the dialog closes, not tomorrow. "local" drops the derived layer and
			// marks the album settled; clearing it (or any other value) drops the
			// derived layer with no marker, re-arming re-derivation. Both reuse
			// ReidentifyAlbum's existing clear-and-re-derive primitive.
			if st, ok := patch["state"]; ok {
				if um, ok := d.Enricher.(unmatcher); ok {
					if err := um.SetLocal(r.Context(), r.PathValue("albumId"), ts, st == "local"); err != nil {
						fail(w, err)
						return
					}
				}
			}
			applyPatch(w, r, "album", r.PathValue("albumId"), patch)
		}
	})

	// any name is a door — person edits aren't limited to library artists
	mux.HandleFunc("PATCH /api/artists/{name}", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if utf8.RuneCountInString(name) > 200 {
			httpError(w, http.StatusBadRequest, "invalid name")
			return
		}
		if patch := editsBody(w, r, "artist"); patch != nil {
			// stored under the raw name: the reader (GET /api/artist) resolves
			// there too, and a second row under the Latin spelling would diverge
			applyPatch(w, r, "artist", rawName(r.Context(), d, name), patch)
		}
	})

	// editor support: pre-override values + current overrides, per object.
	// originals come from file tags + enrichment only — never from edits.
	mux.HandleFunc("GET /api/edits/{kind}/{key}", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		kind, key := r.PathValue("kind"), r.PathValue("key")
		if kind == "artist" {
			key = rawName(ctx, d, key) // both the edit row and the cache row are raw-keyed
		}
		overrides := map[string]any{}
		if raw, err := d.Edits.Get(ctx, kind, key); err != nil {
			fail(w, err)
			return
		} else if raw != nil {
			json.Unmarshal(raw, &overrides)
		}

		switch kind {
		case "track":
			t, err := d.Tracks.ByID(ctx, key)
			if err != nil {
				fail(w, err)
				return
			}
			if t == nil {
				http.Error(w, "Not Found", http.StatusNotFound)
				return
			}
			orig := map[string]any{
				"title": t.Title, "artist": t.Artist, "album": t.Album, "albumArtist": t.AlbumArtist,
				"genre": t.Genre, "year": t.Year, "trackNo": t.TrackNo, "discNo": t.DiscNo,
				"composer": t.Composer, "work": t.Work, "movement": t.Movement,
				"conductor": t.Conductor, "orchestra": nil,
			}
			// The derived overlay beats file tags in "original" — that is what
			// makes the editor's ↺ reset to the corrected value rather than to
			// the wrong tag the correction replaced.
			recMbid := ""
			if t.MBRecordingID != nil {
				recMbid = *t.MBRecordingID
			}
			if raw, found, err := d.EnrichCache.Get(ctx, "track", key); err != nil {
				fail(w, err)
				return
			} else if found {
				var m map[string]any
				json.Unmarshal(raw, &m)
				for _, k := range []string{"composer", "conductor", "orchestra", "title", "trackNo", "discNo"} {
					if v, ok := m[k]; ok {
						orig[k] = v
					}
				}
				if s, ok := m["mbRecordingId"].(string); ok && s != "" {
					recMbid = s
				}
			}
			// derived album fields fan onto the track exactly as they do in the
			// merged view, so the editor's per-field original matches /api/tracks
			da := derivedAlbum(ctx, d, t.AlbumID)
			for _, k := range []string{"album", "albumArtist", "year"} {
				if v, ok := da[k]; ok {
					orig[k] = v
				}
			}
			writeJSON(w, http.StatusOK, map[string]any{"original": orig, "overrides": overrides,
				"source": matchSource(ctx, d, t.AlbumID, recMbid)})

		case "album":
			ts, err := d.Tracks.ByAlbum(ctx, key)
			if err != nil {
				fail(w, err)
				return
			}
			if len(ts) == 0 {
				http.Error(w, "Not Found", http.StatusNotFound)
				return
			}
			info := map[string]any{}
			infoRaw, found, err := d.EnrichCache.Get(ctx, "albumInfo", key)
			if err != nil {
				fail(w, err)
				return
			}
			if found {
				json.Unmarshal(infoRaw, &info) // literal null (negative cache) leaves {}
			}
			get := func(k string) any {
				if v, ok := info[k]; ok {
					return v
				}
				return nil
			}
			// releaseType lives in library.go; it wants tracksResponse-shaped maps
			albumTracks := make([]map[string]any, len(ts))
			for i, t := range ts {
				m := map[string]any{"albumArtist": t.AlbumArtist, "album": t.Album}
				if t.Duration != nil {
					m["duration"] = *t.Duration
				}
				albumTracks[i] = m
			}
			orig := map[string]any{
				"album": ts[0].Album, "albumArtist": ts[0].AlbumArtist,
				"genre": ts[0].Genre, "year": ts[0].Year,
				"releaseType": releaseType(albumTracks, infoRaw),
				"label":       get("label"), "date": get("date"), "country": get("country"), "blurb": get("blurb"),
				// The matcher's own conclusion is the `original` these fields
				// override. locked has no derived side — it is a user field
				// only — so it stays null here.
				"state": nil, "disambiguation": nil, "locked": nil,
			}
			// Corrections from a confirmed release are `original`, not
			// `overrides` — same convention label/date/country already follow.
			// Storing them as overrides would make ↺ revert to the wrong file tag
			// and show the user overrides they never typed.
			da := derivedAlbum(ctx, d, key)
			for _, k := range []string{"album", "albumArtist", "year"} {
				if v, ok := da[k]; ok {
					orig[k] = v
				}
			}
			if dec, ok, err := d.Matches.Get(r.Context(), key); err != nil {
				fail(w, err)
				return
			} else if ok {
				orig["state"] = dec.State
				if dec.Disambiguation != "" {
					orig["disambiguation"] = dec.Disambiguation
				}
			}
			writeJSON(w, http.StatusOK, map[string]any{"original": orig, "overrides": overrides,
				"source": matchSource(ctx, d, key, "")})

		case "artist": // sync cache only — never blocks on network
			orig := map[string]any{"type": nil, "area": nil, "born": nil, "died": nil, "image": nil, "bio": nil}
			if raw, found, err := d.EnrichCache.Get(ctx, "artist", key); err != nil {
				fail(w, err)
				return
			} else if found {
				var m map[string]any
				json.Unmarshal(raw, &m)
				for k := range orig {
					if v, ok := m[k]; ok {
						orig[k] = v
					}
				}
			}
			writeJSON(w, http.StatusOK, map[string]any{"original": orig, "overrides": overrides})

		default:
			http.Error(w, "Not Found", http.StatusNotFound)
		}
	})

	// ---- re-identify (MB candidate search + forced re-enrichment) ----------

	mux.HandleFunc("GET /api/identify/artist/{name}", func(w http.ResponseWriter, r *http.Request) {
		ident, ok := d.Enricher.(identifier)
		if !ok {
			httpError(w, http.StatusBadGateway, "musicbrainz unavailable")
			return
		}
		res, err := ident.IdentifyArtist(r.Context(), r.PathValue("name"))
		if err != nil {
			httpError(w, http.StatusBadGateway, "musicbrainz unavailable")
			return
		}
		if res == nil {
			res = []enrich.ArtistCandidate{}
		}
		writeJSON(w, http.StatusOK, res)
	})

	mux.HandleFunc("POST /api/artist/{name}/reidentify", func(w http.ResponseWriter, r *http.Request) {
		mbid, ok := mbidBody(w, r)
		if !ok {
			return
		}
		ident, ok := d.Enricher.(identifier)
		if !ok {
			httpError(w, http.StatusBadGateway, "reidentify failed")
			return
		}
		res, err := ident.ReidentifyArtist(r.Context(), r.PathValue("name"), mbid)
		if err != nil {
			httpError(w, http.StatusBadGateway, "reidentify failed")
			return
		}
		if nullish(res) {
			writeJSON(w, http.StatusOK, map[string]any{})
			return
		}
		writeRawJSON(w, http.StatusOK, res)
	})

	mux.HandleFunc("GET /api/identify/album/{albumId}", func(w http.ResponseWriter, r *http.Request) {
		ts, err := d.Tracks.ByAlbum(r.Context(), r.PathValue("albumId"))
		if err != nil {
			fail(w, err)
			return
		}
		if len(ts) == 0 {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		ident, ok := d.Enricher.(identifier)
		if !ok {
			httpError(w, http.StatusBadGateway, "musicbrainz unavailable")
			return
		}
		res, err := ident.IdentifyAlbum(r.Context(), ts)
		if err != nil {
			httpError(w, http.StatusBadGateway, "musicbrainz unavailable")
			return
		}
		if res == nil {
			res = []enrich.AlbumCandidate{}
		}
		writeJSON(w, http.StatusOK, res)
	})

	mux.HandleFunc("POST /api/album/{albumId}/reidentify", func(w http.ResponseWriter, r *http.Request) {
		albumID := r.PathValue("albumId")
		ts, err := d.Tracks.ByAlbum(r.Context(), albumID)
		if err != nil {
			fail(w, err)
			return
		}
		if len(ts) == 0 {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		mbid, ok := mbidBody(w, r)
		if !ok {
			return
		}
		ident, ok := d.Enricher.(identifier)
		if !ok {
			httpError(w, http.StatusBadGateway, "reidentify failed")
			return
		}
		res, err := ident.ReidentifyAlbum(r.Context(), albumID, ts, mbid)
		if err != nil {
			httpError(w, http.StatusBadGateway, "reidentify failed")
			return
		}
		d.InvalidateTracks() // credits/albumInfo were rewritten
		if nullish(res) {
			writeJSON(w, http.StatusOK, map[string]any{})
			return
		}
		writeRawJSON(w, http.StatusOK, res)
	})
}

// mbidBody extracts the optional mbid pin ("" = none); ok=false means a 400
// was written. Legacy: null/absent pass, anything else must match MBID_RE.
func mbidBody(w http.ResponseWriter, r *http.Request) (string, bool) {
	var b struct {
		Mbid json.RawMessage `json:"mbid"`
	}
	if err := readJSON(w, r, &b); err != nil {
		httpError(w, http.StatusBadRequest, "invalid mbid")
		return "", false
	}
	if b.Mbid == nil || bytes.Equal(bytes.TrimSpace(b.Mbid), []byte("null")) {
		return "", true
	}
	s, ok := asStr(b.Mbid)
	if !ok || !mbidRE.MatchString(s) {
		httpError(w, http.StatusBadRequest, "invalid mbid")
		return "", false
	}
	return s, true
}
