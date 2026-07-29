package api

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"unicode/utf8"

	"aria/internal/enrich"
)

func init() { register(registerSettings) }

func registerSettings(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/settings", func(w http.ResponseWriter, r *http.Request) {
		tok, err := d.Settings.Get(r.Context(), "listenbrainzToken")
		if err != nil {
			fail(w, err)
			return
		}
		cda, err := d.Settings.Get(r.Context(), "classicalDisplayArtist")
		if err != nil {
			fail(w, err)
			return
		}
		// Read through the matcher's own reader, not a second copy of it, so
		// GET /api/settings can never advertise a value the matcher would not
		// use — including the fallback when a stored value is unparseable or
		// out of range.
		maxDist, minSep := enrich.Thresholds(r.Context(), d.Settings)
		writeJSON(w, http.StatusOK, map[string]any{
			"listenbrainzToken": tok, "classicalDisplayArtist": cda != "0", // unset = on
			"matchMaxDistance":   maxDist,
			"matchMinSeparation": minSep,
		})
	})

	mux.HandleFunc("POST /api/settings", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			ListenbrainzToken      json.RawMessage `json:"listenbrainzToken"`
			ClassicalDisplayArtist *bool           `json:"classicalDisplayArtist"`
			MatchMaxDistance       *float64        `json:"matchMaxDistance"`
			MatchMinSeparation     *float64        `json:"matchMinSeparation"`
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
		if b.ClassicalDisplayArtist != nil {
			v := "1"
			if !*b.ClassicalDisplayArtist {
				v = "0"
			}
			if err := d.Settings.Set(r.Context(), "classicalDisplayArtist", v); err != nil {
				fail(w, err)
				return
			}
			d.InvalidateTracks() // the merged view bakes the policy in
		}
		// The two matching thresholds. Both are (0,1] because they live on a
		// 0-1 distance scale; 0 would mean "only a byte-perfect match counts"
		// and is far likelier to be a client bug than an intention. Deliberately
		// no re-match kick on change: POST /api/match {"force":true} is the verb
		// for that, and silently spending two hours of MusicBrainz requests
		// because a slider moved would be rude.
		for _, s := range []struct {
			key string
			v   *float64
		}{{"matchMaxDistance", b.MatchMaxDistance}, {"matchMinSeparation", b.MatchMinSeparation}} {
			if s.v == nil {
				continue
			}
			if *s.v <= 0 || *s.v > 1 {
				httpError(w, http.StatusBadRequest, "invalid "+s.key)
				return
			}
			if err := d.Settings.Set(r.Context(), s.key, strconv.FormatFloat(*s.v, 'f', -1, 64)); err != nil {
				fail(w, err)
				return
			}
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
}
