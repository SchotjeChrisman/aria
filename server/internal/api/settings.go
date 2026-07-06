package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"unicode/utf8"
)

func init() { register(registerSettings) }

func registerSettings(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/settings", func(w http.ResponseWriter, r *http.Request) {
		tok, err := d.Settings.Get(r.Context(), "listenbrainzToken")
		if err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"listenbrainzToken": tok})
	})

	mux.HandleFunc("POST /api/settings", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			ListenbrainzToken json.RawMessage `json:"listenbrainzToken"`
		}
		if err := readJSON(w, r, &b); err != nil {
			httpError(w, http.StatusBadRequest, "invalid json")
			return
		}
		if b.ListenbrainzToken != nil {
			s, ok := asStr(b.ListenbrainzToken)
			if !ok || utf8.RuneCountInString(s) > 200 {
				httpError(w, http.StatusBadRequest, "invalid token")
				return
			}
			var err error
			// trimmed-empty deletes the stored token (legacy semantics)
			if v := strings.TrimSpace(s); v != "" {
				err = d.Settings.Set(r.Context(), "listenbrainzToken", v)
			} else {
				err = d.Settings.Delete(r.Context(), "listenbrainzToken")
			}
			if err != nil {
				fail(w, err)
				return
			}
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
}
