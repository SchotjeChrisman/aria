package api

import (
	"context"
	"log"
	"net/http"
)

func init() { register(registerAnalyze) }

// registerAnalyze mounts the loudness-analysis job, shaped exactly like the
// enrich pair: fire-and-forget kick plus a status read. 501 rather than 500
// when d.Analyzer is nil — this is a capability the deployment lacks (no
// ffmpeg), not a server fault, same as the transcode tiers.
func registerAnalyze(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/analyze/status", func(w http.ResponseWriter, r *http.Request) {
		if d.Analyzer == nil {
			httpError(w, http.StatusNotImplemented, "audio analysis unavailable")
			return
		}
		writeJSON(w, http.StatusOK, d.Analyzer.Status())
	})

	mux.HandleFunc("POST /api/analyze", func(w http.ResponseWriter, r *http.Request) {
		if d.Analyzer == nil {
			httpError(w, http.StatusNotImplemented, "audio analysis unavailable")
			return
		}
		d.GoBg(func(ctx context.Context) {
			if err := d.Analyzer.Run(ctx); err != nil {
				log.Printf("analyze: %v", err)
			}
			d.InvalidateTracks() // loudness feeds trackGainDb/albumGainDb into the merge
		})
		writeJSON(w, http.StatusOK, d.Analyzer.Status())
	})
}
