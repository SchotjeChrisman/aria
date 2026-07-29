package api

import (
	"context"
	"log"
	"net/http"
)

func init() { register(registerFingerprint) }

// registerFingerprint mounts the fingerprint job, shaped exactly like the
// analyze pair: fire-and-forget kick plus a status read. 501 rather than 500
// when d.Fingerprinter is nil — this is a capability the deployment lacks (no
// working fpcalc), not a server fault.
//
// A missing ACOUSTID_KEY is deliberately NOT a 501: fingerprints are still
// computed and stored, only the lookup half stays dark.
func registerFingerprint(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/fingerprint/status", func(w http.ResponseWriter, r *http.Request) {
		if d.Fingerprinter == nil {
			httpError(w, http.StatusNotImplemented, "fingerprinting unavailable")
			return
		}
		writeJSON(w, http.StatusOK, d.Fingerprinter.Status())
	})

	mux.HandleFunc("POST /api/fingerprint", func(w http.ResponseWriter, r *http.Request) {
		if d.Fingerprinter == nil {
			httpError(w, http.StatusNotImplemented, "fingerprinting unavailable")
			return
		}
		d.GoBg(func(ctx context.Context) {
			if err := d.Fingerprinter.Run(ctx); err != nil {
				log.Printf("fingerprint: %v", err)
			}
			// No InvalidateTracks: nothing fingerprinting produces reaches the
			// merged /api/tracks view. The consumers are the matcher (which
			// scores against the release groups AcoustID voted for) and the
			// duplicate list, neither of which is part of that view.
		})
		writeJSON(w, http.StatusOK, d.Fingerprinter.Status())
	})
}
