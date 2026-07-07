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
		// no trim: play history is kept forever (the legacy 20k cap silently
		// turned all-time stats into a rolling window); stats aggregate in SQL
		go scrobble(d, t)
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})

	mux.HandleFunc("GET /api/stats", func(w http.ResponseWriter, r *http.Request) { stats(w, r, d) })

	// memoized: recompute scans 100k tracks + every artist discography blob
	var nrMemo memo[[]release]
	mux.HandleFunc("GET /api/newreleases", func(w http.ResponseWriter, r *http.Request) {
		out, err := nrMemo.get(time.Minute, func() ([]release, error) { return newReleases(r.Context(), d) })
		if err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, http.StatusOK, out)
	})
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

// stats aggregates entirely in SQL: the plays table is unbounded (no trim),
// so per-request work must scale with the result size, not history size.
// Legacy semantics preserved: stale trackIds (files gone) count in
// totalPlays/week/month plays only; ISO timestamps compare lexicographically;
// ties rank by first-ever play (MIN(p.id) = legacy Map insertion order).
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

	// every query filters (?1='' OR p.profileId=?1); cutoffs bind as ?2/?3
	now := time.Now().UTC()
	weekCut := now.Add(-7 * 24 * time.Hour).Format("2006-01-02T15:04:05.000Z")
	monthCut := now.Add(-30 * 24 * time.Hour).Format("2006-01-02T15:04:05.000Z")
	const scope = `(?1 = '' OR p.profileId = ?1)`
	const known = `plays p JOIN tracks t ON t.id = p.trackId` // stale plays excluded

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

	var totalPlays, uniqueTracks int
	var totalSec, weekSec, monthSec float64
	err := d.DB.QueryRowContext(ctx, `
		SELECT COUNT(*), COALESCE(SUM(p.at >= ?2), 0), COALESCE(SUM(p.at >= ?3), 0)
		FROM plays p WHERE `+scope, pid, weekCut, monthCut).Scan(&totalPlays, &week.Plays, &month.Plays)
	if err != nil {
		fail(w, err)
		return
	}
	err = d.DB.QueryRowContext(ctx, `
		SELECT COUNT(DISTINCT p.trackId), COALESCE(SUM(t.duration), 0),
		       COALESCE(SUM(CASE WHEN p.at >= ?2 THEN t.duration END), 0),
		       COALESCE(SUM(CASE WHEN p.at >= ?3 THEN t.duration END), 0)
		FROM `+known+` WHERE `+scope, pid, weekCut, monthCut).Scan(&uniqueTracks, &totalSec, &weekSec, &monthSec)
	if err != nil {
		fail(w, err)
		return
	}
	week.Seconds, month.Seconds = int(math.Round(weekSec)), int(math.Round(monthSec))

	collect := func(dst func(*sql.Rows) error, q string, args ...any) bool {
		rows, err := d.DB.QueryContext(ctx, q, args...)
		if err != nil {
			fail(w, err)
			return false
		}
		defer rows.Close()
		for rows.Next() {
			if err := dst(rows); err != nil {
				fail(w, err)
				return false
			}
		}
		if err := rows.Err(); err != nil {
			fail(w, err)
			return false
		}
		return true
	}

	type trackStat struct {
		ID     string `json:"id"`
		Count  int    `json:"count"`
		LastAt string `json:"lastAt"`
	}
	topTracks := []trackStat{}
	if !collect(func(rows *sql.Rows) error {
		var t trackStat
		if err := rows.Scan(&t.ID, &t.Count, &t.LastAt); err != nil {
			return err
		}
		topTracks = append(topTracks, t)
		return nil
	}, `SELECT p.trackId, COUNT(*) AS c, MAX(p.at) FROM `+known+` WHERE `+scope+`
	    GROUP BY p.trackId ORDER BY c DESC, MIN(p.id) LIMIT 50`, pid) {
		return
	}

	type albumStat struct {
		AlbumID string `json:"albumId"`
		Count   int    `json:"count"`
	}
	topAlbums := []albumStat{}
	if !collect(func(rows *sql.Rows) error {
		var a albumStat
		if err := rows.Scan(&a.AlbumID, &a.Count); err != nil {
			return err
		}
		topAlbums = append(topAlbums, a)
		return nil
	}, `SELECT t.albumId, COUNT(*) AS c FROM `+known+` WHERE `+scope+`
	    GROUP BY t.albumId ORDER BY c DESC, MIN(p.id) LIMIT 50`, pid) {
		return
	}

	topArtists := []artistStat{}
	if !collect(func(rows *sql.Rows) error {
		var a artistStat
		if err := rows.Scan(&a.Name, &a.Count); err != nil {
			return err
		}
		topArtists = append(topArtists, a)
		return nil
	}, `SELECT t.artist, COUNT(*) AS c FROM `+known+` WHERE `+scope+` AND t.artist <> ''
	    GROUP BY t.artist ORDER BY c DESC, MIN(p.id) LIMIT 50`, pid) {
		return
	}

	if !collect(func(rows *sql.Rows) error {
		var a artistStat
		if err := rows.Scan(&a.Name, &a.Count); err != nil {
			return err
		}
		month.TopArtist = &a
		return nil
	}, `SELECT t.artist, COUNT(*) AS c FROM `+known+` WHERE `+scope+` AND p.at >= ?2 AND t.artist <> ''
	    GROUP BY t.artist ORDER BY c DESC, MIN(p.id) LIMIT 1`, pid, monthCut) {
		return
	}

	// newest distinct known tracks; p.at rides along from the MAX(p.id) row
	// (SQLite bare-column-with-MAX guarantee)
	recent := []playRef{}
	if !collect(func(rows *sql.Rows) error {
		var p playRef
		var mid int64
		if err := rows.Scan(&p.ID, &p.At, &mid); err != nil {
			return err
		}
		recent = append(recent, p)
		return nil
	}, `SELECT p.trackId, p.at, MAX(p.id) AS mid FROM `+known+` WHERE `+scope+`
	    GROUP BY p.trackId ORDER BY mid DESC LIMIT 50`, pid) {
		return
	}

	// raw 30-day history of known tracks — the client buckets in its own timezone
	history := []playRef{}
	if !collect(func(rows *sql.Rows) error {
		var p playRef
		if err := rows.Scan(&p.ID, &p.At); err != nil {
			return err
		}
		history = append(history, p)
		return nil
	}, `SELECT p.trackId, p.at FROM `+known+` WHERE `+scope+` AND p.at >= ?2 ORDER BY p.id`, pid, monthCut) {
		return
	}

	resp := map[string]any{
		"profileId":    nil,
		"history":      history,
		"totalPlays":   totalPlays,
		"totalSeconds": int(math.Round(totalSec)),
		"week":         week,
		"month":        month,
		"uniqueTracks": uniqueTracks,
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
		if !collect(func(rows *sql.Rows) error {
			var id string
			var n int
			if err := rows.Scan(&id, &n); err != nil {
				return err
			}
			pc[id] = n
			return nil
		}, `SELECT p.trackId, COUNT(*) FROM plays p WHERE `+scope+` GROUP BY p.trackId`, pid) {
			return
		}
		resp["playCounts"] = pc
	}
	writeJSON(w, http.StatusOK, resp)
}

type release struct {
	Artist string  `json:"artist"`
	Title  string  `json:"title"`
	Cover  *string `json:"cover"`
	Date   string  `json:"date"`
	Type   string  `json:"type"`
	n      string
}

// newReleases: recently released, not-in-library items from the cached Deezer
// discographies (enrich_cache kind "artist", field "discography"). Cache only —
// no network; cold cache or empty library just yields [].
func newReleases(ctx context.Context, d *Deps) ([]release, error) {
	rows, err := d.DB.QueryContext(ctx, `SELECT DISTINCT albumArtist, album FROM tracks WHERE albumArtist <> ''`)
	if err != nil {
		return nil, err
	}
	libTitles := map[string]map[string]bool{} // albumArtist -> set of normTitle(owned albums)
	for rows.Next() {
		var aa, al string
		if err := rows.Scan(&aa, &al); err != nil {
			rows.Close()
			return nil, err
		}
		if libTitles[aa] == nil {
			libTitles[aa] = map[string]bool{}
		}
		libTitles[aa][normTitle(al)] = true
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	entries, err := d.EnrichCache.ListKind(ctx, "artist")
	if err != nil {
		return nil, err
	}
	artists := make([]string, 0, len(entries))
	for name := range entries {
		if libTitles[name] != nil { // only library albumArtists
			artists = append(artists, name)
		}
	}
	sort.Strings(artists) // map order is random; fix it for deterministic ties

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
	return picked, nil
}
