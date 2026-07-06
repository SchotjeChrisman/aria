package api

import (
	"crypto/rand"
	"fmt"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"aria/internal/repo"
)

func init() { register(registerTags) }

// notFound mirrors Express res.sendStatus(404): text/plain "Not Found", no JSON.
func notFound(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusNotFound)
	w.Write([]byte("Not Found"))
}

// nowISO matches new Date().toISOString() — millisecond precision, Z suffix.
func nowISO() string { return time.Now().UTC().Format("2006-01-02T15:04:05.000Z") }

func newID() string {
	var b [16]byte
	rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40 // UUID v4, like legacy randomUUID()
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// validName ports legacy validName: string, non-blank after trim, length cap on
// the untrimmed input.
func validName(v any, max int) bool {
	s, ok := v.(string)
	return ok && strings.TrimSpace(s) != "" && utf8.RuneCountInString(s) <= max
}

// bodyMap decodes the request body as a JSON object (req.body ?? {} semantics:
// empty body yields an empty map). Presence checks on keys mirror the legacy
// `x !== undefined` tests.
func bodyMap(w http.ResponseWriter, r *http.Request) (map[string]any, bool) {
	var m map[string]any
	if err := readJSON(w, r, &m); err != nil {
		httpError(w, http.StatusBadRequest, "invalid body")
		return nil, false
	}
	if m == nil {
		m = map[string]any{}
	}
	return m, true
}

func tagIn(tags []repo.Tag, id string) *repo.Tag {
	for i := range tags {
		if tags[i].ID == id {
			return &tags[i]
		}
	}
	return nil
}

func dupTag(tags []repo.Tag, name, skipID string) bool {
	for _, t := range tags {
		if t.ID != skipID && strings.EqualFold(t.Name, name) {
			return true
		}
	}
	return false
}

// tagParentOk: walking up from parentID must never reach the tag itself (also
// rejects unknown ids, broken chains, and pre-existing cycles — the seen map
// keeps a racily/verbatim-imported parent cycle from spinning forever).
func tagParentOk(tags []repo.Tag, selfID, parentID string) bool {
	seen := map[string]bool{}
	for p := tagIn(tags, parentID); p != nil && !seen[p.ID]; {
		if p.ID == selfID {
			return false
		}
		seen[p.ID] = true
		if p.Parent == nil {
			return true
		}
		p = tagIn(tags, *p.Parent)
	}
	return false
}

func registerTags(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("GET /api/tags", func(w http.ResponseWriter, r *http.Request) {
		tags, err := d.Tags.List(r.Context())
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if tags == nil {
			tags = []repo.Tag{}
		}
		writeJSON(w, http.StatusOK, tags)
	})

	mux.HandleFunc("POST /api/tags", func(w http.ResponseWriter, r *http.Request) {
		body, ok := bodyMap(w, r)
		if !ok {
			return
		}
		if !validName(body["name"], 60) {
			httpError(w, http.StatusBadRequest, "invalid name")
			return
		}
		name := strings.TrimSpace(body["name"].(string))
		tags, err := d.Tags.List(r.Context())
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if dupTag(tags, name, "") {
			httpError(w, http.StatusBadRequest, "tag exists")
			return
		}
		var parent *string
		if pv, present := body["parent"]; present && pv != nil {
			s, isStr := pv.(string)
			if !isStr || tagIn(tags, s) == nil {
				httpError(w, http.StatusBadRequest, "unknown parent")
				return
			}
			parent = &s
		}
		tag := repo.Tag{ID: newID(), Name: name, Parent: parent, Items: []repo.TagItem{}, CreatedAt: nowISO()}
		if err := d.Tags.Create(r.Context(), tag); err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, tag)
	})

	mux.HandleFunc("PATCH /api/tags/{id}", func(w http.ResponseWriter, r *http.Request) {
		tags, err := d.Tags.List(r.Context())
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		tag := tagIn(tags, r.PathValue("id"))
		if tag == nil {
			notFound(w)
			return
		}
		body, ok := bodyMap(w, r)
		if !ok {
			return
		}
		nameV, hasName := body["name"]
		parentV, hasParent := body["parent"]
		if !hasName && !hasParent {
			httpError(w, http.StatusBadRequest, "nothing to change")
			return
		}
		name := tag.Name
		if hasName {
			if !validName(nameV, 60) {
				httpError(w, http.StatusBadRequest, "invalid name")
				return
			}
			name = strings.TrimSpace(nameV.(string))
			if dupTag(tags, name, tag.ID) {
				httpError(w, http.StatusBadRequest, "tag exists")
				return
			}
		}
		parent := tag.Parent
		if hasParent {
			if parentV == nil {
				parent = nil
			} else {
				s, isStr := parentV.(string)
				if !isStr || !tagParentOk(tags, tag.ID, s) {
					httpError(w, http.StatusBadRequest, "invalid parent") // unknown, self, or a cycle
					return
				}
				parent = &s
			}
		}
		if err := d.Tags.Update(r.Context(), tag.ID, name, parent); err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		tag.Name, tag.Parent = name, parent
		writeJSON(w, http.StatusOK, tag)
	})

	mux.HandleFunc("DELETE /api/tags/{id}", func(w http.ResponseWriter, r *http.Request) {
		tag, err := d.Tags.ByID(r.Context(), r.PathValue("id"))
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if tag == nil {
			notFound(w)
			return
		}
		if err := d.Tags.Delete(r.Context(), tag.ID); err != nil { // promotes children
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})

	// artist keys are free-form names on purpose — every name is a door, in library or not
	mux.HandleFunc("PUT /api/tags/{id}/items", func(w http.ResponseWriter, r *http.Request) {
		tag, err := d.Tags.ByID(r.Context(), r.PathValue("id"))
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if tag == nil {
			notFound(w)
			return
		}
		body, ok := bodyMap(w, r)
		if !ok {
			return
		}
		kind, _ := body["kind"].(string)
		key, keyOk := body["key"].(string)
		if (kind != "track" && kind != "album" && kind != "artist") ||
			!keyOk || key == "" || utf8.RuneCountInString(key) > 300 {
			httpError(w, http.StatusBadRequest, "invalid item")
			return
		}
		if kind == "track" {
			t, err := d.Tracks.ByID(r.Context(), key)
			if err != nil {
				httpError(w, http.StatusInternalServerError, "internal error")
				return
			}
			if t == nil {
				httpError(w, http.StatusBadRequest, "unknown track")
				return
			}
		}
		if kind == "album" {
			ts, err := d.Tracks.ByAlbum(r.Context(), key)
			if err != nil {
				httpError(w, http.StatusInternalServerError, "internal error")
				return
			}
			if len(ts) == 0 {
				httpError(w, http.StatusBadRequest, "unknown album")
				return
			}
		}
		if err := d.Tags.AddItem(r.Context(), tag.ID, kind, key); err != nil { // dedupes
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		fresh, err := d.Tags.ByID(r.Context(), tag.ID)
		if err != nil || fresh == nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, fresh)
	})

	// legacy oddity: DELETE with a JSON body {kind, key}; no validation, absent
	// or mistyped fields simply match nothing.
	mux.HandleFunc("DELETE /api/tags/{id}/items", func(w http.ResponseWriter, r *http.Request) {
		tag, err := d.Tags.ByID(r.Context(), r.PathValue("id"))
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if tag == nil {
			notFound(w)
			return
		}
		body, ok := bodyMap(w, r)
		if !ok {
			return
		}
		kind, _ := body["kind"].(string)
		key, _ := body["key"].(string)
		if err := d.Tags.RemoveItem(r.Context(), tag.ID, kind, key); err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		fresh, err := d.Tags.ByID(r.Context(), tag.ID)
		if err != nil || fresh == nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, fresh)
	})
}
