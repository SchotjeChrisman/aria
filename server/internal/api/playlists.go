package api

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"aria/internal/genres"
	"aria/internal/repo"
)

func init() { register(registerPlaylists) }

// ---- smart-playlist rules (ported from server.js) --------------------------

var stringOps = []string{"is", "isNot", "contains", "anyOf", "allOf"} // anyOf/allOf take an array of values

var ruleFields = map[string][]string{
	"title": stringOps, "artist": stringOps, "albumArtist": stringOps, "album": stringOps,
	"genre": stringOps, "composer": stringOps, "format": stringOps, "credited": stringOps,
	"year":        {"is", "gt", "lt"},
	"lossless":    {"is"},
	"releaseType": {"is", "isNot"},
	"playCount":   {"is", "gt", "lt"},
	"addedDays":   {"within"},
	"tag":         {"is", "isNot", "anyOf", "allOf"},
}

func validRules(v any) bool {
	m, ok := v.(map[string]any)
	if !ok {
		return false
	}
	if m["match"] != "all" && m["match"] != "any" {
		return false
	}
	rules, ok := m["rules"].([]any)
	if !ok || len(rules) > 16 { // form emits up to 13
		return false
	}
	for _, rv := range rules {
		r, ok := rv.(map[string]any)
		if !ok {
			return false
		}
		field, _ := r["field"].(string)
		op, _ := r["op"].(string)
		if !slices.Contains(ruleFields[field], op) {
			return false
		}
		if op == "anyOf" || op == "allOf" {
			arr, ok := r["value"].([]any)
			if !ok || len(arr) == 0 || len(arr) > 30 {
				return false
			}
			for _, e := range arr {
				s, ok := e.(string)
				if !ok || s == "" {
					return false
				}
			}
		} else if _, present := r["value"]; !present {
			return false
		}
	}
	return true
}

// deref collapses the pointer-typed nullables a track view may carry.
func deref(v any) any {
	switch x := v.(type) {
	case *int:
		if x == nil {
			return nil
		}
		return *x
	case *float64:
		if x == nil {
			return nil
		}
		return *x
	case *string:
		if x == nil {
			return nil
		}
		return *x
	}
	return v
}

// jsStr mimics JS String() for JSON-carried values.
func jsStr(v any) string {
	switch x := deref(v).(type) {
	case nil:
		return "null"
	case string:
		return x
	case bool:
		return strconv.FormatBool(x)
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case int:
		return strconv.Itoa(x)
	case int64:
		return strconv.FormatInt(x, 10)
	default:
		return ""
	}
}

// toNum mimics JS Number(); ok=false stands in for NaN (all comparisons fail).
func toNum(v any) (float64, bool) {
	switch x := deref(v).(type) {
	case nil:
		return 0, true // Number(null) === 0
	case float64:
		return x, true
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	case bool:
		if x {
			return 1, true
		}
		return 0, true
	case string:
		s := strings.TrimSpace(x)
		if s == "" {
			return 0, true // Number('') === 0
		}
		f, err := strconv.ParseFloat(s, 64)
		return f, err == nil
	}
	return 0, false
}

func numOr0(v any) float64 {
	f, ok := toNum(v)
	if !ok {
		return 0
	}
	return f
}

func lowerAll(ss []string) []string {
	out := make([]string, len(ss))
	for i, s := range ss {
		out[i] = strings.ToLower(s)
	}
	return out
}

func strList(v any) []string {
	switch x := v.(type) {
	case []string:
		return x
	case []any:
		out := make([]string, 0, len(x))
		for _, e := range x {
			if s, ok := e.(string); ok {
				out = append(out, s)
			}
		}
		return out
	}
	return nil
}

func performerNames(v any) []string {
	var out []string
	add := func(m map[string]any) {
		if s, ok := m["name"].(string); ok {
			out = append(out, s)
		}
	}
	switch x := v.(type) {
	case []map[string]any:
		for _, m := range x {
			add(m)
		}
	case []any:
		for _, e := range x {
			if m, ok := e.(map[string]any); ok {
				add(m)
			}
		}
	}
	return out
}

func anyVal(v any, f func(any) bool) bool {
	arr, _ := v.([]any)
	return slices.ContainsFunc(arr, f)
}

func allVal(v any, f func(any) bool) bool {
	arr, _ := v.([]any)
	for _, e := range arr {
		if !f(e) {
			return false
		}
	}
	return true
}

// evalRule ports server.js evalRule. t is an /api/tracks-shaped view (edits
// merged, releaseType/tags/genres annotated); counts is per-profile play counts.
func evalRule(t, r map[string]any, counts map[string]int) bool {
	field, _ := r["field"].(string)
	op, _ := r["op"].(string)
	value := r["value"]
	switch field {
	case "year":
		yv := deref(t["year"])
		if yv == nil { // null year fails everything
			return false
		}
		y, yok := toNum(yv)
		v, vok := toNum(value)
		if !yok || !vok {
			return false
		}
		switch op {
		case "is":
			return y == v
		case "gt":
			return y > v
		default:
			return y < v
		}
	case "lossless":
		want := value == true || value == "true"
		b, ok := deref(t["lossless"]).(bool)
		return ok && b == want
	case "releaseType":
		eq := strings.EqualFold(jsStr(t["releaseType"]), jsStr(value))
		if op == "is" {
			return eq
		}
		return !eq
	case "playCount":
		id, _ := t["id"].(string)
		c := float64(counts[id])
		v, ok := toNum(value)
		if !ok {
			return false
		}
		switch op {
		case "is":
			return c == v
		case "gt":
			return c > v
		default:
			return c < v
		}
	case "addedDays":
		s, _ := deref(t["addedAt"]).(string)
		if s == "" {
			return false
		}
		ts, err := time.Parse(time.RFC3339, s)
		if err != nil {
			return false
		}
		n, ok := toNum(value)
		if !ok {
			return false
		}
		return !ts.Before(time.Now().Add(-time.Duration(n * float64(24*time.Hour))))
	case "tag": // user tags, annotated onto track views; exact match
		tl := lowerAll(strList(t["tags"]))
		one := func(q any) bool { return slices.Contains(tl, strings.ToLower(jsStr(q))) }
		switch op {
		case "anyOf":
			return anyVal(value, one)
		case "allOf":
			return allVal(value, one)
		case "is":
			return one(value)
		default:
			return !one(value)
		}
	case "credited": // anyone credited on the track: artist, conductor, orchestra, performers
		var names []string
		for _, k := range []string{"artist", "conductor", "orchestra"} {
			if s, ok := deref(t[k]).(string); ok && s != "" {
				names = append(names, strings.ToLower(s))
			}
		}
		for _, n := range performerNames(t["performers"]) {
			if n != "" {
				names = append(names, strings.ToLower(n))
			}
		}
		one := func(q any) bool {
			ql := strings.ToLower(jsStr(q))
			for _, n := range names {
				if strings.Contains(n, ql) {
					return true
				}
			}
			return false
		}
		switch op {
		case "anyOf":
			return anyVal(value, one)
		case "allOf":
			return allVal(value, one)
		case "is":
			return slices.Contains(names, strings.ToLower(jsStr(value)))
		case "isNot":
			return !slices.Contains(names, strings.ToLower(jsStr(value)))
		default:
			return one(value) // contains
		}
	case "genre": // canonical + hierarchical, with raw-substring back-compat
		g, _ := deref(t["genre"]).(string)
		raw := strings.ToLower(g)
		one := func(q any) bool {
			return genres.Matches(g, jsStr(q)) || strings.Contains(raw, strings.ToLower(jsStr(q)))
		}
		switch op {
		case "anyOf":
			return anyVal(value, one)
		case "allOf":
			return allVal(value, one)
		}
		canon := lowerAll(genres.Split(g))
		q := strings.ToLower(jsStr(value))
		switch op {
		case "is":
			return slices.Contains(canon, q) || raw == q
		case "isNot":
			return !(slices.Contains(canon, q) || raw == q)
		default:
			return one(value) // contains
		}
	default: // string fields: title, artist, albumArtist, album, composer, format
		val := deref(t[field])
		if op == "anyOf" || op == "allOf" {
			if val == nil {
				return false
			}
			s := strings.ToLower(jsStr(val))
			one := func(q any) bool { return strings.Contains(s, strings.ToLower(jsStr(q))) }
			if op == "anyOf" {
				return anyVal(value, one)
			}
			return allVal(value, one)
		}
		if val == nil {
			return op == "isNot" // null: is/contains false, isNot true
		}
		s := strings.ToLower(jsStr(val))
		q := strings.ToLower(jsStr(value))
		switch op {
		case "is":
			return s == q
		case "isNot":
			return s != q
		default:
			return strings.Contains(s, q)
		}
	}
}

// ---- routes -----------------------------------------------------------------

// playlistView builds the legacy playlist shape: manual playlists carry
// trackIds (pre-loaded; nil means empty), smart ones carry rules.
func playlistView(p *repo.Playlist, trackIDs []string) map[string]any {
	out := map[string]any{
		"id": p.ID, "profileId": p.ProfileID, "type": p.Type, "name": p.Name,
		"createdAt": p.CreatedAt, "updatedAt": p.UpdatedAt,
	}
	if p.Type == "manual" {
		if trackIDs == nil {
			trackIDs = []string{}
		}
		out["trackIds"] = trackIDs
	} else {
		out["rules"] = json.RawMessage(p.Rules)
	}
	return out
}

// playlistJSON is the single-playlist variant: loads trackIds itself.
func playlistJSON(ctx context.Context, d *Deps, p *repo.Playlist) (map[string]any, error) {
	var ids []string
	if p.Type == "manual" {
		var err error
		if ids, err = d.Playlists.TrackIDs(ctx, p.ID); err != nil {
			return nil, err
		}
	}
	return playlistView(p, ids), nil
}

func registerPlaylists(mux *http.ServeMux, d *Deps) {
	writePlaylist := func(w http.ResponseWriter, r *http.Request, p *repo.Playlist) {
		m, err := playlistJSON(r.Context(), d, p)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, m)
	}
	// byID loads a playlist or writes the legacy plain-text 404.
	byID := func(w http.ResponseWriter, r *http.Request) *repo.Playlist {
		p, err := d.Playlists.ByID(r.Context(), r.PathValue("id"))
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return nil
		}
		if p == nil {
			notFound(w)
			return nil
		}
		return p
	}

	mux.HandleFunc("GET /api/playlists", func(w http.ResponseWriter, r *http.Request) {
		pls, err := d.Playlists.List(r.Context(), r.URL.Query().Get("profileId"))
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		var manualIDs []string
		for i := range pls {
			if pls[i].Type == "manual" {
				manualIDs = append(manualIDs, pls[i].ID)
			}
		}
		idsBy, err := d.Playlists.TrackIDsFor(r.Context(), manualIDs)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		out := []map[string]any{}
		for i := range pls {
			out = append(out, playlistView(&pls[i], idsBy[pls[i].ID]))
		}
		writeJSON(w, http.StatusOK, out)
	})

	mux.HandleFunc("POST /api/playlists", func(w http.ResponseWriter, r *http.Request) {
		body, ok := bodyMap(w, r)
		if !ok {
			return
		}
		if !validName(body["name"], 200) {
			httpError(w, http.StatusBadRequest, "invalid name")
			return
		}
		profileID, _ := body["profileId"].(string)
		prof, err := d.Profiles.ByID(r.Context(), profileID)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if prof == nil {
			httpError(w, http.StatusBadRequest, "unknown profile")
			return
		}
		typ := "manual"
		if tv, present := body["type"]; present {
			typ, _ = tv.(string) // non-string → "" → rejected below
		}
		if typ != "manual" && typ != "smart" {
			httpError(w, http.StatusBadRequest, "invalid type")
			return
		}
		var rules json.RawMessage
		if typ == "smart" {
			if !validRules(body["rules"]) {
				httpError(w, http.StatusBadRequest, "invalid rules")
				return
			}
			rules, _ = json.Marshal(body["rules"])
		}
		ts := nowISO()
		p := repo.Playlist{
			ID: newID(), ProfileID: profileID, Name: body["name"].(string), // legacy stores the name untrimmed
			Type: typ, Rules: rules, CreatedAt: ts, UpdatedAt: ts,
		}
		if err := d.Playlists.Create(r.Context(), p); err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writePlaylist(w, r, &p)
	})

	mux.HandleFunc("PATCH /api/playlists/{id}", func(w http.ResponseWriter, r *http.Request) {
		p := byID(w, r)
		if p == nil {
			return
		}
		body, ok := bodyMap(w, r)
		if !ok {
			return
		}
		nameV, hasName := body["name"]
		rulesV, hasRules := body["rules"]
		if hasName && !validName(nameV, 200) {
			httpError(w, http.StatusBadRequest, "invalid name")
			return
		}
		if hasRules {
			if p.Type != "smart" {
				httpError(w, http.StatusBadRequest, "rules only valid on smart playlists")
				return
			}
			if !validRules(rulesV) {
				httpError(w, http.StatusBadRequest, "invalid rules")
				return
			}
		}
		if hasName {
			p.Name = nameV.(string)
		}
		if hasRules {
			p.Rules, _ = json.Marshal(rulesV)
		}
		p.UpdatedAt = nowISO() // legacy bumps updatedAt even on an empty body
		if err := d.Playlists.Update(r.Context(), *p); err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writePlaylist(w, r, p)
	})

	mux.HandleFunc("DELETE /api/playlists/{id}", func(w http.ResponseWriter, r *http.Request) {
		p := byID(w, r)
		if p == nil {
			return
		}
		if err := d.Playlists.Delete(r.Context(), p.ID); err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})

	mux.HandleFunc("POST /api/playlists/{id}/tracks", func(w http.ResponseWriter, r *http.Request) {
		p := byID(w, r)
		if p == nil {
			return
		}
		if p.Type != "manual" {
			httpError(w, http.StatusBadRequest, "cannot add tracks to a smart playlist")
			return
		}
		body, ok := bodyMap(w, r)
		if !ok {
			return
		}
		trackID, _ := body["trackId"].(string)
		if trackID == "" {
			httpError(w, http.StatusBadRequest, "unknown track")
			return
		}
		t, err := d.Tracks.ByID(r.Context(), trackID)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if t == nil {
			httpError(w, http.StatusBadRequest, "unknown track")
			return
		}
		if err := d.Playlists.AddTrack(r.Context(), p.ID, trackID); err != nil { // duplicates allowed
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		p.UpdatedAt = nowISO()
		if err := d.Playlists.Update(r.Context(), *p); err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writePlaylist(w, r, p)
	})

	mux.HandleFunc("DELETE /api/playlists/{id}/tracks/{trackId}", func(w http.ResponseWriter, r *http.Request) {
		p := byID(w, r)
		if p == nil {
			return
		}
		if p.Type != "manual" {
			httpError(w, http.StatusBadRequest, "cannot remove tracks from a smart playlist")
			return
		}
		// removes all occurrences; unknown ids are a silent no-op
		if err := d.Playlists.RemoveTrack(r.Context(), p.ID, r.PathValue("trackId")); err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		p.UpdatedAt = nowISO()
		if err := d.Playlists.Update(r.Context(), *p); err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		writePlaylist(w, r, p)
	})

	mux.HandleFunc("GET /api/playlists/{id}/tracks", func(w http.ResponseWriter, r *http.Request) {
		p := byID(w, r)
		if p == nil {
			return
		}
		// mergedTracks (library.go) is the shared /api/tracks view builder:
		// edits merged, path stripped, releaseType/tags/genres annotated.
		all, err := mergedTracks(r.Context(), d)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		if p.Type == "manual" {
			ids, err := d.Playlists.TrackIDs(r.Context(), p.ID)
			if err != nil {
				httpError(w, http.StatusInternalServerError, "internal error")
				return
			}
			views := make(map[string]map[string]any, len(all))
			for _, t := range all {
				if id, ok := t["id"].(string); ok {
					views[id] = t
				}
			}
			out := []map[string]any{}
			for _, id := range ids {
				if t, ok := views[id]; ok { // missing ids silently skipped
					out = append(out, t)
				}
			}
			writeJSON(w, http.StatusOK, out)
			return
		}
		// smart: evaluated on demand against current library + plays
		var doc any
		json.Unmarshal(p.Rules, &doc)
		rm, _ := doc.(map[string]any)
		rules, _ := rm["rules"].([]any)
		if len(rules) == 0 {
			writeJSON(w, http.StatusOK, []any{})
			return
		}
		counts, err := d.Plays.CountsFor(r.Context(), p.ProfileID)
		if err != nil {
			httpError(w, http.StatusInternalServerError, "internal error")
			return
		}
		matchAll := rm["match"] == "all"
		hit := func(t map[string]any) bool {
			for _, rv := range rules {
				rmap, _ := rv.(map[string]any)
				ok := evalRule(t, rmap, counts)
				if matchAll && !ok {
					return false
				}
				if !matchAll && ok {
					return true
				}
			}
			return matchAll
		}
		out := []map[string]any{}
		for _, t := range all {
			if hit(t) {
				out = append(out, t)
			}
		}
		cmpLower := func(a, b any) int {
			as, _ := deref(a).(string)
			bs, _ := deref(b).(string)
			return strings.Compare(strings.ToLower(as), strings.ToLower(bs))
		}
		sort.SliceStable(out, func(i, j int) bool {
			a, b := out[i], out[j]
			if c := cmpLower(a["artist"], b["artist"]); c != 0 {
				return c < 0
			}
			if c := cmpLower(a["album"], b["album"]); c != 0 {
				return c < 0
			}
			if da, db := numOr0(a["discNo"]), numOr0(b["discNo"]); da != db {
				return da < db
			}
			return numOr0(a["trackNo"]) < numOr0(b["trackNo"])
		})
		if len(out) > 500 {
			out = out[:500]
		}
		writeJSON(w, http.StatusOK, out)
	})
}
