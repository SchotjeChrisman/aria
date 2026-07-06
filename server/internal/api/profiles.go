package api

import (
	"encoding/json"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"

	"aria/internal/repo"
)

var colorRE = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)

// isoNow matches JS new Date().toISOString() (millisecond precision, Z).
func isoNow() string { return time.Now().UTC().Format("2006-01-02T15:04:05.000Z") }

// asStr unmarshals a JSON string; ok=false for absent, null, or non-string —
// the port of legacy `typeof x === 'string'` checks (RawMessage keeps the
// null-vs-undefined distinction PATCH handlers need).
func asStr(raw json.RawMessage) (string, bool) {
	var s string
	if raw == nil || json.Unmarshal(raw, &s) != nil {
		return "", false
	}
	return s, true
}

// nameOK ports legacy validName: non-blank after trim, rune length <= max.
func nameOK(s string, max int) bool {
	return strings.TrimSpace(s) != "" && utf8.RuneCountInString(s) <= max
}

// fail logs a repo/db error and writes the JSON 500 (legacy had no 500 path
// on these routes — its stores were in-memory).
func fail(w http.ResponseWriter, err error) {
	log.Printf("api: %v", err)
	httpError(w, http.StatusInternalServerError, "internal error")
}

func init() { register(registerProfiles) }

func registerProfiles(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/profiles", func(w http.ResponseWriter, r *http.Request) {
		ps, err := d.Profiles.List(r.Context())
		if err != nil {
			fail(w, err)
			return
		}
		if ps == nil {
			ps = []repo.Profile{}
		}
		writeJSON(w, http.StatusOK, ps)
	})

	mux.HandleFunc("POST /api/profiles", func(w http.ResponseWriter, r *http.Request) {
		var b struct{ Name, Color json.RawMessage }
		if err := readJSON(w, r, &b); err != nil {
			httpError(w, http.StatusBadRequest, "invalid json")
			return
		}
		name, ok := asStr(b.Name)
		if !ok || !nameOK(name, 60) {
			httpError(w, http.StatusBadRequest, "invalid name")
			return
		}
		color, ok := asStr(b.Color)
		if !ok || !colorRE.MatchString(color) {
			httpError(w, http.StatusBadRequest, "invalid color")
			return
		}
		p := repo.Profile{ID: uuid.NewString(), Name: name, Color: color, CreatedAt: isoNow()}
		if err := d.Profiles.Create(r.Context(), p); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, p)
	})

	mux.HandleFunc("PATCH /api/profiles/{id}", func(w http.ResponseWriter, r *http.Request) {
		p, err := d.Profiles.ByID(r.Context(), r.PathValue("id"))
		if err != nil {
			fail(w, err)
			return
		}
		if p == nil {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		var b struct{ Name, Color json.RawMessage }
		if err := readJSON(w, r, &b); err != nil {
			httpError(w, http.StatusBadRequest, "invalid json")
			return
		}
		if b.Name != nil {
			name, ok := asStr(b.Name)
			if !ok || !nameOK(name, 60) {
				httpError(w, http.StatusBadRequest, "invalid name")
				return
			}
			p.Name = name
		}
		if b.Color != nil {
			color, ok := asStr(b.Color)
			if !ok || !colorRE.MatchString(color) {
				httpError(w, http.StatusBadRequest, "invalid color")
				return
			}
			p.Color = color
		}
		if err := d.Profiles.Update(r.Context(), *p); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, p)
	})

	mux.HandleFunc("DELETE /api/profiles/{id}", func(w http.ResponseWriter, r *http.Request) {
		p, err := d.Profiles.ByID(r.Context(), r.PathValue("id"))
		if err != nil {
			fail(w, err)
			return
		}
		if p == nil {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
		n, err := d.Profiles.Count(r.Context())
		if err != nil {
			fail(w, err)
			return
		}
		if n == 1 {
			httpError(w, http.StatusBadRequest, "cannot delete last profile")
			return
		}
		// playlists + plays go with it via FK cascade.
		if err := d.Profiles.Delete(r.Context(), p.ID); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
}
