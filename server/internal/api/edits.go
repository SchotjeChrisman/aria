package api

import (
	"bytes"
	"context"
	"encoding/json"
	"math"
	"net/http"
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

// nullish reports a nil-or-"null" cache/reidentify blob.
func nullish(raw json.RawMessage) bool {
	return raw == nil || bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}

// DB overrides: beat file tags + enrichment; null clears one field.
var editFields = map[string][]string{
	"track": {"title", "artist", "album", "albumArtist", "genre", "year", "trackNo", "discNo",
		"composer", "work", "movement", "conductor", "orchestra"},
	"album":  {"album", "albumArtist", "genre", "year", "releaseType", "label", "date", "country", "blurb"},
	"artist": {"type", "area", "born", "died", "image", "bio"},
}

var (
	intEdits     = []string{"year", "trackNo", "discNo"}
	longEdits    = []string{"bio", "blurb"}
	releaseTypes = []string{"Album", "EP", "Single", "Live", "Compilation"}

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
		case k == "releaseType":
			var s string
			if json.Unmarshal(v, &s) != nil || !slices.Contains(releaseTypes, s) {
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
			applyPatch(w, r, "artist", name, patch)
		}
	})

	// editor support: pre-override values + current overrides, per object.
	// originals come from file tags + enrichment only — never from edits.
	mux.HandleFunc("GET /api/edits/{kind}/{key}", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		kind, key := r.PathValue("kind"), r.PathValue("key")
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
			// enrichment credit overlay beats file tags in "original"
			if raw, found, err := d.EnrichCache.Get(ctx, "track", key); err != nil {
				fail(w, err)
				return
			} else if found {
				var m map[string]any
				json.Unmarshal(raw, &m)
				for _, k := range []string{"composer", "conductor", "orchestra"} {
					if v, ok := m[k]; ok {
						orig[k] = v
					}
				}
			}
			writeJSON(w, http.StatusOK, map[string]any{"original": orig, "overrides": overrides})

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
			}
			writeJSON(w, http.StatusOK, map[string]any{"original": orig, "overrides": overrides})

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
