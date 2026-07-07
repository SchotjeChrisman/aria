package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"time"
	"unicode/utf8"

	"aria/internal/enrich"
)

func init() { register(registerEnrich) }

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
	_ identifier       = (*enrich.Enricher)(nil)
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
		})
		writeJSON(w, http.StatusOK, d.Enricher.Status())
	})

	// memoized: recompute scans every artist+composer cache blob, but the
	// map only changes as enrichment/edits land — 60s staleness is invisible
	var peopleMemo memo[map[string]string]
	mux.HandleFunc("GET /api/people", func(w http.ResponseWriter, r *http.Request) {
		out, err := peopleMemo.get(time.Minute, func() (map[string]string, error) {
			out := map[string]string{}
			if we, ok := d.Enricher.(warmEnricher); ok {
				m, err := we.People(r.Context())
				if err != nil {
					return nil, err
				}
				out = m
			}
			// edited portraits win
			artists, err := d.Edits.ListKind(r.Context(), "artist")
			if err != nil {
				return nil, err
			}
			for n, raw := range artists {
				var e struct {
					Image string `json:"image"`
				}
				if json.Unmarshal(raw, &e) == nil && e.Image != "" {
					out[n] = e.Image
				}
			}
			return out, nil
		})
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, out)
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
