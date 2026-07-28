package api

import (
	"context"
	"encoding/json"
	"net/http"

	"aria/internal/repo"
)

func init() { register(registerListenLater) }

// ownedReleaseMBIDs is the set of MusicBrainz release ids the library is
// tagged with. An entry whose release group contains any of them has arrived.
//
// ponytail: reads the tag id only, not a re-identify pin in enrich_cache. A
// pinned album still clears through the artist+title fallback below.
func ownedReleaseMBIDs(ctx context.Context, d *Deps) (map[string]bool, error) {
	rows, err := d.DB.QueryContext(ctx, `SELECT DISTINCT mbAlbumId FROM tracks WHERE mbAlbumId IS NOT NULL AND mbAlbumId <> ''`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out[id] = true
	}
	return out, rows.Err()
}

// owned reports whether a saved album is now in the library.
//
// Two rules, and both are needed. The release-group set is the accurate one:
// it clears the entry whichever edition was actually bought. But it only works
// for rips whose tags carry a MusicBrainz album id, and plenty don't — so
// artist + normalized title stays as the fallback. Without it, an untagged rip
// would leave its entry on the list forever.
func owned(e repo.ListenLater, relIDs map[string]bool, titles map[string]map[string]bool) bool {
	if len(e.Releases) > 0 {
		var ids []string
		if json.Unmarshal(e.Releases, &ids) == nil {
			for _, id := range ids {
				if relIDs[id] {
					return true
				}
			}
		}
	}
	// An empty title key matches nothing. normTitle maps symbol-only and
	// non-Latin titles to "", and this rule deletes rows — treating "" as a
	// match would drop an unrelated album off the list for good.
	if e.TitleKey == "" || e.Artist == "" {
		return false
	}
	return titles[e.Artist][e.TitleKey]
}

func registerListenLater(mux *http.ServeMux, d *Deps) {
	// The list, minus anything that has since arrived in the library — and the
	// arrivals are deleted in the same request, so the cleanup needs no scan
	// hook and no background job.
	mux.HandleFunc("GET /api/listenlater", func(w http.ResponseWriter, r *http.Request) {
		pid := r.URL.Query().Get("profileId")
		entries, err := d.ListenLater.List(r.Context(), pid)
		if err != nil {
			fail(w, err)
			return
		}
		titles, err := ownedTitles(r.Context(), d)
		if err != nil {
			fail(w, err)
			return
		}
		relIDs, err := ownedReleaseMBIDs(r.Context(), d)
		if err != nil {
			fail(w, err)
			return
		}
		out := []repo.ListenLater{}
		var arrived []string
		for _, e := range entries {
			if owned(e, relIDs, titles) {
				arrived = append(arrived, e.ID)
				continue
			}
			out = append(out, e)
		}
		if err := d.ListenLater.DeleteMany(r.Context(), pid, arrived); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, out)
	})

	// Save an album by name. The client sends what a shelf card holds; the
	// server resolves it to the universal id, so identity is decided in one
	// place and the app never has to know about barcodes or MBIDs.
	mux.HandleFunc("POST /api/listenlater", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			ProfileID string `json:"profileId"`
			Artist    string `json:"artist"`
			Title     string `json:"title"`
			DeezerID  int64  `json:"deezerId"`
		}
		if err := readJSON(w, r, &body); err != nil {
			return
		}
		if body.Artist == "" || body.Title == "" {
			httpError(w, http.StatusBadRequest, "artist and title required")
			return
		}
		// profileId is a FK, so a missing or unknown one fails the insert. Check
		// it before the upstream lookup rather than after: the client omits the
		// field while profiles are still loading, and that request would
		// otherwise spend a Deezer + MusicBrainz round trip to reach a 500.
		p, err := d.Profiles.ByID(r.Context(), body.ProfileID)
		if err != nil {
			fail(w, err)
			return
		}
		if p == nil {
			httpError(w, http.StatusBadRequest, "unknown profile")
			return
		}
		a, err := resolveExtAlbum(r.Context(), d, body.Artist, body.Title, body.DeezerID)
		if err != nil {
			httpError(w, http.StatusBadGateway, "lookup failed: "+err.Error())
			return
		}
		if a == nil {
			notFound(w)
			return
		}
		// Store the artist as the caller spelled it — that name came from the
		// library's own albumArtist tag, and the ownership fallback compares
		// against exactly that. Deezer's spelling can differ ("Beyoncé" vs
		// "Beyonce"), which would strand the entry on the list forever.
		artist := body.Artist
		if artist == "" {
			artist = a.Artist
		}
		e := repo.ListenLater{
			ID:        a.ID,
			ProfileID: body.ProfileID,
			Artist:    artist,
			Title:     a.Title,
			TitleKey:  normTitle(a.Title),
			Type:      a.Type,
			Cover:     a.Cover,
			AddedAt:   isoNow(),
		}
		if a.UPC != "" {
			e.UPC = &a.UPC
		}
		if a.DeezerID != 0 {
			e.DeezerID = &a.DeezerID
		}
		if a.Date != "" {
			e.Date = &a.Date
		}
		if len(a.Releases) > 0 {
			if raw, err := json.Marshal(a.Releases); err == nil {
				e.Releases = raw
			}
		}
		if err := d.ListenLater.Add(r.Context(), e); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, e)
	})

	mux.HandleFunc("DELETE /api/listenlater/{id}", func(w http.ResponseWriter, r *http.Request) {
		if err := d.ListenLater.Delete(r.Context(), r.URL.Query().Get("profileId"), r.PathValue("id")); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})
}
