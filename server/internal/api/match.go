package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"

	"aria/internal/repo"
)

func init() { register(registerMatch) }

// matcher is the enricher surface the interactive re-match needs beyond
// api.Enricher (matched structurally by *enrich.Enricher, so no import cycle
// and no second wiring in main). nil decision means "that album has no tracks".
type matcher interface {
	MatchAlbum(ctx context.Context, albumID string, ts []repo.Track) (*repo.Decision, error)
}

// registerMatch mounts the album-matching surface: two reads that never touch
// the network, one synchronous re-decide, and one whole-library kick shaped
// exactly like POST /api/analyze.
//
// There is no /api/match/status: matching is a phase of the enrichment pass,
// so GET /api/enrich/status and the `enrich` SSE event already report it
// (phase == "matching"). A second status endpoint would report the same struct.
func registerMatch(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/match/review", func(w http.ResponseWriter, r *http.Request) {
		ds, err := d.Matches.NonMatched(r.Context())
		if err != nil {
			fail(w, err)
			return
		}
		if ds == nil {
			ds = []repo.Decision{}
		}
		writeJSON(w, http.StatusOK, ds)
	})

	mux.HandleFunc("GET /api/albums/{albumId}/match", func(w http.ResponseWriter, r *http.Request) {
		dec, ok, err := d.Matches.Get(r.Context(), r.PathValue("albumId"))
		if err != nil {
			fail(w, err)
			return
		}
		if !ok {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		writeJSON(w, http.StatusOK, dec)
	})

	// Synchronous, unlike the library-wide kick: the caller is a user staring at
	// a dialog waiting for the candidate list, and the 12-fetch cap bounds it at
	// ~13 s. Same code path as the batch pass, so an interactive score can never
	// differ from a background one.
	mux.HandleFunc("POST /api/albums/{albumId}/match", func(w http.ResponseWriter, r *http.Request) {
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
		m, ok := d.Enricher.(matcher)
		if !ok {
			httpError(w, http.StatusBadGateway, "matching unavailable")
			return
		}
		dec, err := m.MatchAlbum(r.Context(), albumID, ts)
		if err != nil || dec == nil {
			httpError(w, http.StatusBadGateway, "matching failed")
			return
		}
		writeJSON(w, http.StatusOK, dec)
	})

	// The batch apply. `force` is also the batch REDO: Reset drops every unpinned
	// decision, and enrich.persist deletes the derived enrich_cache row of any
	// album whose decision moved, so the corrections are recomputed from scratch
	// across the library. Manual edits are untouched by all of it — they live in
	// a different table and are applied after the derived layer.
	//
	// ponytail: there is no per-RUN undo endpoint ("that pass got 40 albums
	// wrong, put those back"). Undo exists per field (type it), per album
	// (PATCH state, or reidentify) and per library (force), and none of it needs
	// a journal because nothing is destroyed — the file tags and the manual edits
	// are both still in the DB underneath the derived layer. The ceiling is that
	// exact per-run case; the upgrade is a batchId column on match_decisions and
	// a delete by it, not a journal table.
	mux.HandleFunc("POST /api/match", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			Force bool `json:"force"`
		}
		// An absent/empty body is the common case (plain "run matching"), so a
		// decode failure is not an error here — only an explicit force matters.
		json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes)).Decode(&b)
		if b.Force {
			// Drops every unpinned decision, so PendingAlbums sees the whole
			// library again. Pins — the user's own choices — survive.
			if err := d.Matches.Reset(r.Context()); err != nil {
				fail(w, err)
				return
			}
		}
		d.GoBg(func(ctx context.Context) {
			if err := d.Enricher.Run(ctx); err != nil {
				log.Printf("match: %v", err)
			}
			d.InvalidateTracks() // a new release MBID moves credits and art
		})
		writeJSON(w, http.StatusOK, d.Enricher.Status())
	})
}
