package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"math"
	"net/http"
	"regexp"
	"sort"
	"strings"
	"time"

	"aria/internal/repo"
)

var (
	editionRE  = regexp.MustCompile(`(?i)\s*[(\[][^)\]]*(remaster|deluxe|edition|version|anniversary|expanded|bonus|live|mono|stereo|\b\d{4}\b)[^)\]]*[)\]]`)
	nonAlnumRE = regexp.MustCompile(`[^a-z0-9]+`)
)

// normTitle ports the legacy edition-tolerant normalization (R5 dedupe).
// Deviation: no NFD accent folding (stdlib has none) — accented letters become
// separators on both sides of the comparison, so dedupe still lines up.
func normTitle(s string) string {
	s = editionRE.ReplaceAllString(strings.ToLower(s), "")
	return strings.TrimSpace(nonAlnumRE.ReplaceAllString(s, " "))
}

type playRef struct {
	ID string `json:"id"`
	At string `json:"at"`
}

func init() { register(registerPlays) }

func registerPlays(mux *http.ServeMux, d *Deps) {
	mux.HandleFunc("POST /api/plays", func(w http.ResponseWriter, r *http.Request) {
		var b struct {
			TrackID   json.RawMessage `json:"trackId"`
			ProfileID json.RawMessage `json:"profileId"`
		}
		if err := readJSON(w, r, &b); err != nil {
			httpError(w, http.StatusBadRequest, "invalid json")
			return
		}
		trackID, _ := asStr(b.TrackID)
		profileID, _ := asStr(b.ProfileID)
		if trackID == "" || profileID == "" {
			httpError(w, http.StatusBadRequest, "trackId and profileId required")
			return
		}
		if p, err := d.Profiles.ByID(r.Context(), profileID); err != nil {
			fail(w, err)
			return
		} else if p == nil {
			httpError(w, http.StatusBadRequest, "unknown profile")
			return
		}
		t, err := d.Tracks.ByID(r.Context(), trackID)
		if err != nil {
			fail(w, err)
			return
		}
		if t == nil {
			httpError(w, http.StatusBadRequest, "unknown track")
			return
		}
		if err := d.Plays.Add(r.Context(), repo.Play{TrackID: trackID, ProfileID: profileID, At: isoNow()}); err != nil {
			fail(w, err)
			return
		}
		if err := d.Plays.Trim(r.Context(), 20000); err != nil {
			log.Printf("plays trim: %v", err)
		}
		go scrobble(d, t)
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})

	mux.HandleFunc("GET /api/stats", func(w http.ResponseWriter, r *http.Request) { stats(w, r, d) })

	mux.HandleFunc("GET /api/newreleases", func(w http.ResponseWriter, r *http.Request) { newReleases(w, r, d) })
}

// scrobble fires a ListenBrainz submit with edits overlaid so fixed titles
// scrobble right. Fire-and-forget: no retry queue, a missed scrobble is not
// data loss.
func scrobble(d *Deps, t *repo.Track) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	token, err := d.Settings.Get(ctx, "listenbrainzToken")
	if err != nil || token == "" {
		return
	}
	title, artist, album := t.Title, t.Artist, t.Album
	if raw, err := d.Edits.Get(ctx, "album", t.AlbumID); err == nil && raw != nil {
		var m map[string]any
		if json.Unmarshal(raw, &m) == nil {
			if s, ok := m["album"].(string); ok { // only the fan-out field scrobbling uses
				album = s
			}
		}
	}
	if raw, err := d.Edits.Get(ctx, "track", t.ID); err == nil && raw != nil {
		var m map[string]any
		if json.Unmarshal(raw, &m) == nil {
			for k, dst := range map[string]*string{"title": &title, "artist": &artist, "album": &album} {
				if s, ok := m[k].(string); ok {
					*dst = s
				}
			}
		}
	}
	if artist == "" {
		artist = "Unknown"
	}
	if title == "" {
		title = "Unknown"
	}
	info := map[string]any{"media_player": "aria", "submission_client": "aria"}
	if t.Duration != nil && *t.Duration > 0 {
		info["duration_ms"] = int(math.Round(*t.Duration * 1000))
	}
	meta := map[string]any{"artist_name": artist, "track_name": title, "additional_info": info}
	if album != "" {
		meta["release_name"] = album
	}
	body, _ := json.Marshal(map[string]any{
		"listen_type": "single",
		"payload":     []any{map[string]any{"listened_at": time.Now().Unix(), "track_metadata": meta}},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://api.listenbrainz.org/1/submit-listens", bytes.NewReader(body))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Token "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("listenbrainz: %v", err)
		return
	}
	res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode > 299 {
		log.Printf("listenbrainz: HTTP %d", res.StatusCode)
	}
}

func stats(w http.ResponseWriter, r *http.Request, d *Deps) {
	ctx := r.Context()
	pid := r.URL.Query().Get("profileId")
	if pid != "" {
		p, err := d.Profiles.ByID(ctx, pid)
		if err != nil {
			fail(w, err)
			return
		}
		if p == nil {
			http.Error(w, "Not Found", http.StatusNotFound)
			return
		}
	}
	plays, err := d.Plays.List(ctx, pid)
	if err != nil {
		fail(w, err)
		return
	}

	type tinfo struct {
		dur             float64
		albumID, artist string
	}
	rows, err := d.DB.QueryContext(ctx, `SELECT id, duration, albumId, artist FROM tracks`)
	if err != nil {
		fail(w, err)
		return
	}
	byID := map[string]tinfo{}
	for rows.Next() {
		var id string
		var dur sql.NullFloat64
		var ti tinfo
		if err := rows.Scan(&id, &dur, &ti.albumID, &ti.artist); err != nil {
			rows.Close()
			fail(w, err)
			return
		}
		ti.dur = dur.Float64
		byID[id] = ti
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		fail(w, err)
		return
	}

	// stale trackIds (files gone from disk) count in totalPlays only
	known := make([]repo.Play, 0, len(plays))
	for _, p := range plays {
		if _, ok := byID[p.TrackID]; ok {
			known = append(known, p)
		}
	}

	type agg struct {
		count  int
		lastAt string
	}
	var totalSeconds float64
	trackAgg := map[string]*agg{}
	albumAgg := map[string]int{}
	artistAgg := map[string]int{}
	var trackOrder, albumOrder, artistOrder []string // first-seen order = legacy Map insertion order
	for _, p := range known {
		t := byID[p.TrackID]
		totalSeconds += t.dur
		ta := trackAgg[p.TrackID]
		if ta == nil {
			ta = &agg{}
			trackAgg[p.TrackID] = ta
			trackOrder = append(trackOrder, p.TrackID)
		}
		ta.count++
		if p.At > ta.lastAt { // ISO strings compare lexicographically
			ta.lastAt = p.At
		}
		if _, ok := albumAgg[t.albumID]; !ok {
			albumOrder = append(albumOrder, t.albumID)
		}
		albumAgg[t.albumID]++
		if t.artist != "" {
			if _, ok := artistAgg[t.artist]; !ok {
				artistOrder = append(artistOrder, t.artist)
			}
			artistAgg[t.artist]++
		}
	}

	recent := []playRef{}
	seen := map[string]bool{}
	for i := len(known) - 1; i >= 0 && len(recent) < 50; i-- {
		p := known[i]
		if !seen[p.TrackID] {
			seen[p.TrackID] = true
			recent = append(recent, playRef{ID: p.TrackID, At: p.At})
		}
	}

	// R4: rolling windows (play counts over all scoped plays; seconds/topArtist
	// need known tracks). Unparseable timestamps fall out, like NaN did.
	now := time.Now()
	weekCut, monthCut := now.Add(-7*24*time.Hour), now.Add(-30*24*time.Hour)
	atOf := func(p repo.Play) (time.Time, bool) {
		t, err := time.Parse(time.RFC3339, p.At)
		return t, err == nil
	}
	type window struct {
		Plays   int `json:"plays"`
		Seconds int `json:"seconds"`
	}
	type artistStat struct {
		Name  string `json:"name"`
		Count int    `json:"count"`
	}
	var week window
	month := struct {
		window
		TopArtist *artistStat `json:"topArtist"`
	}{}
	var weekSec, monthSec float64
	monthArtists := map[string]int{}
	var monthArtistOrder []string
	for _, p := range plays {
		if at, ok := atOf(p); ok {
			if !at.Before(weekCut) {
				week.Plays++
			}
			if !at.Before(monthCut) {
				month.Plays++
			}
		}
	}
	for _, p := range known {
		at, ok := atOf(p)
		if !ok || at.Before(monthCut) {
			continue
		}
		t := byID[p.TrackID]
		monthSec += t.dur
		if !at.Before(weekCut) {
			weekSec += t.dur
		}
		if t.artist != "" {
			if _, ok := monthArtists[t.artist]; !ok {
				monthArtistOrder = append(monthArtistOrder, t.artist)
			}
			monthArtists[t.artist]++
		}
	}
	week.Seconds = int(math.Round(weekSec))
	month.Seconds = int(math.Round(monthSec))
	sort.SliceStable(monthArtistOrder, func(i, j int) bool {
		return monthArtists[monthArtistOrder[i]] > monthArtists[monthArtistOrder[j]]
	})
	if len(monthArtistOrder) > 0 {
		n := monthArtistOrder[0]
		month.TopArtist = &artistStat{Name: n, Count: monthArtists[n]}
	}

	// raw 30-day history of known tracks — the client buckets in its own timezone
	history := []playRef{}
	for _, p := range known {
		if at, ok := atOf(p); ok && !at.Before(monthCut) {
			history = append(history, playRef{ID: p.TrackID, At: p.At})
		}
	}

	type trackStat struct {
		ID     string `json:"id"`
		Count  int    `json:"count"`
		LastAt string `json:"lastAt"`
	}
	sort.SliceStable(trackOrder, func(i, j int) bool {
		return trackAgg[trackOrder[i]].count > trackAgg[trackOrder[j]].count
	})
	topTracks := []trackStat{}
	for _, id := range trackOrder[:min(50, len(trackOrder))] {
		topTracks = append(topTracks, trackStat{ID: id, Count: trackAgg[id].count, LastAt: trackAgg[id].lastAt})
	}
	sort.SliceStable(albumOrder, func(i, j int) bool { return albumAgg[albumOrder[i]] > albumAgg[albumOrder[j]] })
	type albumStat struct {
		AlbumID string `json:"albumId"`
		Count   int    `json:"count"`
	}
	topAlbums := []albumStat{}
	for _, id := range albumOrder[:min(50, len(albumOrder))] {
		topAlbums = append(topAlbums, albumStat{AlbumID: id, Count: albumAgg[id]})
	}
	sort.SliceStable(artistOrder, func(i, j int) bool { return artistAgg[artistOrder[i]] > artistAgg[artistOrder[j]] })
	topArtists := []artistStat{}
	for _, n := range artistOrder[:min(50, len(artistOrder))] {
		topArtists = append(topArtists, artistStat{Name: n, Count: artistAgg[n]})
	}

	resp := map[string]any{
		"profileId":    nil,
		"history":      history,
		"totalPlays":   len(plays),
		"totalSeconds": int(math.Round(totalSeconds)),
		"week":         week,
		"month":        month,
		"uniqueTracks": len(trackAgg),
		"topTracks":    topTracks,
		"topAlbums":    topAlbums,
		"topArtists":   topArtists,
		"recent":       recent,
	}
	if pid != "" {
		resp["profileId"] = pid
	}
	// R7: full per-track counts for the played/never-played filter, opt-in only
	if r.URL.Query().Get("counts") == "1" {
		pc := map[string]int{}
		for _, p := range plays {
			pc[p.TrackID]++
		}
		resp["playCounts"] = pc
	}
	writeJSON(w, http.StatusOK, resp)
}

// newReleases: recently released, not-in-library items from the cached Deezer
// discographies (enrich_cache kind "artist", field "discography"). Cache only —
// no network; cold cache or empty library just yields [].
func newReleases(w http.ResponseWriter, r *http.Request, d *Deps) {
	ctx := r.Context()
	rows, err := d.DB.QueryContext(ctx, `SELECT DISTINCT albumArtist, album FROM tracks WHERE albumArtist <> ''`)
	if err != nil {
		fail(w, err)
		return
	}
	libTitles := map[string]map[string]bool{} // albumArtist -> set of normTitle(owned albums)
	for rows.Next() {
		var aa, al string
		if err := rows.Scan(&aa, &al); err != nil {
			rows.Close()
			fail(w, err)
			return
		}
		if libTitles[aa] == nil {
			libTitles[aa] = map[string]bool{}
		}
		libTitles[aa][normTitle(al)] = true
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		fail(w, err)
		return
	}

	entries, err := d.EnrichCache.ListKind(ctx, "artist")
	if err != nil {
		fail(w, err)
		return
	}
	artists := make([]string, 0, len(entries))
	for name := range entries {
		if libTitles[name] != nil { // only library albumArtists
			artists = append(artists, name)
		}
	}
	sort.Strings(artists) // map order is random; fix it for deterministic ties

	type release struct {
		Artist string  `json:"artist"`
		Title  string  `json:"title"`
		Cover  *string `json:"cover"`
		Date   string  `json:"date"`
		Type   string  `json:"type"`
		n      string
	}
	dateRE := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	now := time.Now()
	cutoff := now.Add(-180 * 24 * time.Hour)
	var out []release
	for _, name := range artists {
		var e struct {
			Discography []struct {
				Title string  `json:"title"`
				Cover *string `json:"cover"`
				Date  *string `json:"date"`
				Type  *string `json:"type"`
			} `json:"discography"`
		}
		if json.Unmarshal(entries[name], &e) != nil {
			continue
		}
		owned := libTitles[name]
		for _, x := range e.Discography {
			if x.Date == nil || !dateRE.MatchString(*x.Date) {
				continue
			}
			ts, err := time.Parse("2006-01-02", *x.Date)
			// future-dated = distributor placeholder junk
			if err != nil || ts.Before(cutoff) || ts.After(now) {
				continue
			}
			n := normTitle(x.Title)
			if owned[n] {
				continue
			}
			typ := "album"
			if x.Type != nil && *x.Type != "" {
				typ = *x.Type
			}
			cover := x.Cover
			if cover != nil && *cover == "" { // legacy `x.cover || null`
				cover = nil
			}
			out = append(out, release{Artist: name, Title: x.Title, Cover: cover, Date: *x.Date, Type: typ, n: n})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Date > out[j].Date })
	// classical compilations show up under every composer at once: dedupe titles
	// globally, and cap per artist so prolific catalogs don't flood the shelf
	seen := map[string]bool{}
	perArtist := map[string]int{}
	picked := []release{}
	for _, x := range out {
		if seen[x.n] || perArtist[x.Artist] >= 3 {
			continue
		}
		seen[x.n] = true
		perArtist[x.Artist]++
		picked = append(picked, x)
		if len(picked) == 60 {
			break
		}
	}
	writeJSON(w, http.StatusOK, picked)
}
