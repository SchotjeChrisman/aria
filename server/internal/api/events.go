package api

import (
	"net/http"
	"time"
)

func init() { register(registerEvents) }

// GET /api/events — SSE stream of named `scan` and `enrich` progress events
// published on the hub by the scanner and enricher (v2 addition).
func registerEvents(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/events", func(w http.ResponseWriter, r *http.Request) {
		fl, ok := w.(http.Flusher)
		if !ok {
			httpError(w, http.StatusInternalServerError, "streaming unsupported")
			return
		}
		h := w.Header()
		h.Set("Content-Type", "text/event-stream")
		h.Set("Cache-Control", "no-cache")
		h.Set("Connection", "keep-alive")
		h.Set("X-Accel-Buffering", "no") // reverse proxies must not buffer
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(": connected\n\n"))
		fl.Flush()

		ch, cancel := d.Events.Subscribe()
		defer cancel()
		keepalive := time.NewTicker(25 * time.Second)
		defer keepalive.Stop()
		for {
			select {
			case <-r.Context().Done():
				return
			case frame, ok := <-ch:
				if !ok {
					return
				}
				if _, err := w.Write(frame); err != nil {
					return
				}
				fl.Flush()
			case <-keepalive.C:
				if _, err := w.Write([]byte(": ping\n\n")); err != nil {
					return
				}
				fl.Flush()
			}
		}
	})
}
