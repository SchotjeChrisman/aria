package api

import (
	"fmt"
	"net/http"
	"time"
)

func init() { register(registerEvents) }

// libraryFrame is the SSE frame carrying the merged-view generation, written
// both at connect and on every keepalive.
const libraryFrame = "event: library\ndata: {\"gen\":%d}\n\n"

// GET /api/events — SSE stream of named `scan` and `enrich` progress events
// published on the hub by the scanner and enricher (v2 addition), plus
// `library` generation frames from Deps.InvalidateTracks.
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
		// Open with the current library generation, and repeat it on every
		// keepalive below. A live `library` frame only reaches apps connected at
		// the moment it was published, and the hub DROPS frames for a subscriber
		// that is behind — which a client draining 4000 scan-progress frames
		// certainly is. Stating the generation on a timer instead of trusting one
		// delivery is what makes a missed announcement self-correct rather than
		// leave that app stale until it happens to reconnect.
		//
		// Subscribe FIRST, read the generation second: a change landing between
		// the two is then delivered twice (harmless — the client compares) rather
		// than falling into the gap between them, which is what the other order
		// would do.
		if _, err := fmt.Fprintf(w, libraryFrame, d.TracksGen()); err != nil {
			return
		}
		fl.Flush()
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
				// The generation IS the keepalive: same bytes on the wire as a
				// comment ping as far as holding the connection open goes, and a
				// client that missed an announcement catches up within 25s.
				if _, err := fmt.Fprintf(w, libraryFrame, d.TracksGen()); err != nil {
					return
				}
				fl.Flush()
			}
		}
	})
}
