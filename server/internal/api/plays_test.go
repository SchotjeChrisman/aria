package api

import (
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/repo"
)

// POST /api/plays: the optional client timestamp `at` backdates the play
// (offline replay); omitted = server clock; junk = 400.
func TestRecordPlayAt(t *testing.T) {
	d, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	deps := NewDeps(d, config.Config{}, "test")
	ctx := context.Background()

	if err := deps.Profiles.EnsureDefault(ctx); err != nil {
		t.Fatal(err)
	}
	profiles, err := deps.Profiles.List(ctx)
	if err != nil || len(profiles) == 0 {
		t.Fatalf("profiles: %v", err)
	}
	pid := profiles[0].ID
	if err := deps.Tracks.UpsertAll(ctx, []repo.Track{{
		ID: "t1", Path: "t1", Title: "One", AlbumID: "al1",
		AddedAt: "2026-01-01T00:00:00.000Z",
	}}); err != nil {
		t.Fatal(err)
	}

	post := func(body string) int {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("POST", "/api/plays", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		New(deps).ServeHTTP(rec, req)
		return rec.Code
	}

	before := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	if code := post(`{"trackId":"t1","profileId":"` + pid + `"}`); code != 200 {
		t.Fatalf("no at = %d, want 200", code)
	}
	if code := post(`{"trackId":"t1","profileId":"` + pid + `","at":"2026-07-01T10:00:00.000Z"}`); code != 200 {
		t.Fatalf("with at = %d, want 200", code)
	}
	if code := post(`{"trackId":"t1","profileId":"` + pid + `","at":"yesterday"}`); code != 400 {
		t.Fatalf("junk at = %d, want 400", code)
	}
	if code := post(`{"trackId":"t1","profileId":"` + pid + `","at":"9999-12-31T23:59:59.999Z"}`); code != 400 {
		t.Fatalf("future at = %d, want 400", code)
	}
	if code := post(`{"trackId":"t1","profileId":"` + pid + `","at":"2026-07-01T10:00:00Z"}`); code != 400 {
		t.Fatalf("wrong-layout at = %d, want 400", code)
	}

	plays, err := deps.Plays.List(ctx, pid)
	if err != nil {
		t.Fatal(err)
	}
	if len(plays) != 2 {
		t.Fatalf("plays = %d, want 2", len(plays))
	}
	if plays[0].At < before {
		t.Errorf("server-clock at = %q, want >= %q", plays[0].At, before)
	}
	if _, err := time.Parse("2006-01-02T15:04:05.000Z", plays[0].At); err != nil {
		t.Errorf("server-clock at layout: %v", err)
	}
	if plays[1].At != "2026-07-01T10:00:00.000Z" {
		t.Errorf("client at = %q, want 2026-07-01T10:00:00.000Z", plays[1].At)
	}
}

// A pending-plays replay after a timed-out-but-committed request retries the
// identical (trackId, profileId, at) triple — it must not double-count.
func TestRecordPlayIdempotent(t *testing.T) {
	d, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	deps := NewDeps(d, config.Config{}, "test")
	ctx := context.Background()

	if err := deps.Profiles.EnsureDefault(ctx); err != nil {
		t.Fatal(err)
	}
	profiles, err := deps.Profiles.List(ctx)
	if err != nil || len(profiles) == 0 {
		t.Fatalf("profiles: %v", err)
	}
	pid := profiles[0].ID
	if err := deps.Tracks.UpsertAll(ctx, []repo.Track{{
		ID: "t1", Path: "t1", Title: "One", AlbumID: "al1",
		AddedAt: "2026-01-01T00:00:00.000Z",
	}}); err != nil {
		t.Fatal(err)
	}

	body := `{"trackId":"t1","profileId":"` + pid + `","at":"2026-07-01T10:00:00.000Z"}`
	for i := 0; i < 2; i++ {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("POST", "/api/plays", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		New(deps).ServeHTTP(rec, req)
		if rec.Code != 200 {
			t.Fatalf("post %d = %d, want 200", i, rec.Code)
		}
	}

	plays, err := deps.Plays.List(ctx, pid)
	if err != nil {
		t.Fatal(err)
	}
	if len(plays) != 1 {
		t.Fatalf("plays = %d, want 1 (duplicate replay must dedupe)", len(plays))
	}
}

// Smoke test for the SQL-aggregated /api/stats: totals, tops, windows,
// stale-track handling, and profile scoping.
func TestStats(t *testing.T) {
	d, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	deps := NewDeps(d, config.Config{}, "test")
	ctx := context.Background()

	if err := deps.Profiles.EnsureDefault(ctx); err != nil {
		t.Fatal(err)
	}
	profiles, err := deps.Profiles.List(ctx)
	if err != nil || len(profiles) == 0 {
		t.Fatalf("profiles: %v", err)
	}
	pid := profiles[0].ID

	dur := 200.0
	mk := func(id, title, artist, albumID string) repo.Track {
		return repo.Track{ID: id, Path: id, Title: title, Artist: artist, AlbumArtist: artist,
			Album: "A", AlbumID: albumID, AddedAt: "2026-01-01T00:00:00.000Z", Format: "FLAC", Duration: &dur}
	}
	if err := deps.Tracks.UpsertAll(ctx, []repo.Track{
		mk("t1", "One", "X", "al1"), mk("t2", "Two", "Y", "al2"),
	}); err != nil {
		t.Fatal(err)
	}

	iso := func(ago time.Duration) string {
		return time.Now().UTC().Add(-ago).Format("2006-01-02T15:04:05.000Z")
	}
	for _, p := range []repo.Play{
		{TrackID: "t1", ProfileID: pid, At: iso(400 * 24 * time.Hour)}, // old
		{TrackID: "t1", ProfileID: pid, At: iso(2 * 24 * time.Hour)},   // this week
		{TrackID: "t2", ProfileID: pid, At: iso(10 * 24 * time.Hour)},  // this month
		{TrackID: "gone", ProfileID: pid, At: iso(time.Hour)},          // stale track
	} {
		if err := deps.Plays.Add(ctx, p); err != nil {
			t.Fatal(err)
		}
	}

	get := func(url string) map[string]any {
		rec := httptest.NewRecorder()
		New(deps).ServeHTTP(rec, httptest.NewRequest("GET", url, nil))
		if rec.Code != 200 {
			t.Fatalf("GET %s = %d: %s", url, rec.Code, rec.Body.String())
		}
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("GET %s: %v", url, err)
		}
		return out
	}

	s := get("/api/stats?counts=1")
	if got := s["totalPlays"].(float64); got != 4 { // stale play counts
		t.Errorf("totalPlays = %v, want 4", got)
	}
	if got := s["totalSeconds"].(float64); got != 600 { // 3 known plays x 200s
		t.Errorf("totalSeconds = %v, want 600", got)
	}
	if got := s["uniqueTracks"].(float64); got != 2 {
		t.Errorf("uniqueTracks = %v, want 2", got)
	}
	week := s["week"].(map[string]any)
	if week["plays"].(float64) != 2 || week["seconds"].(float64) != 200 { // t1 recent + stale
		t.Errorf("week = %v, want plays 2 / seconds 200", week)
	}
	month := s["month"].(map[string]any)
	if month["plays"].(float64) != 3 || month["seconds"].(float64) != 400 {
		t.Errorf("month = %v, want plays 3 / seconds 400", month)
	}
	if ta := month["topArtist"].(map[string]any); ta["name"] != "X" {
		t.Errorf("month topArtist = %v, want X", ta)
	}
	top := s["topTracks"].([]any)
	if len(top) != 2 || top[0].(map[string]any)["id"] != "t1" || top[0].(map[string]any)["count"].(float64) != 2 {
		t.Errorf("topTracks = %v, want t1 count 2 first", top)
	}
	recent := s["recent"].([]any)
	// legacy recency = insertion order (play id), not timestamp: t2 was recorded last
	if len(recent) != 2 || recent[0].(map[string]any)["id"] != "t2" {
		t.Errorf("recent = %v, want t2 first", recent)
	}
	if hist := s["history"].([]any); len(hist) != 2 {
		t.Errorf("history len = %d, want 2", len(hist))
	}
	pc := s["playCounts"].(map[string]any)
	if pc["t1"].(float64) != 2 || pc["gone"].(float64) != 1 {
		t.Errorf("playCounts = %v", pc)
	}

	// profile scoping: unknown profile 404s, real profile matches
	rec := httptest.NewRecorder()
	New(deps).ServeHTTP(rec, httptest.NewRequest("GET", "/api/stats?profileId=nope", nil))
	if rec.Code != 404 {
		t.Errorf("unknown profile = %d, want 404", rec.Code)
	}
	sp := get("/api/stats?profileId=" + pid)
	if sp["totalPlays"].(float64) != 4 || sp["profileId"] != pid {
		t.Errorf("scoped stats = totalPlays %v profileId %v", sp["totalPlays"], sp["profileId"])
	}

	// /api/tracks pre-gzipped cache path: valid gzip JSON, stable across
	// requests, refreshed after invalidation
	tracksGz := func() []any {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("GET", "/api/tracks", nil)
		req.Header.Set("Accept-Encoding", "gzip")
		New(deps).ServeHTTP(rec, req)
		if rec.Code != 200 || rec.Header().Get("Content-Encoding") != "gzip" {
			t.Fatalf("tracks = %d, encoding %q", rec.Code, rec.Header().Get("Content-Encoding"))
		}
		gr, err := gzip.NewReader(rec.Body)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := io.ReadAll(gr)
		if err != nil {
			t.Fatal(err)
		}
		var out []any
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	if got := tracksGz(); len(got) != 2 {
		t.Fatalf("gzip tracks len = %d, want 2", len(got))
	}
	if got := tracksGz(); len(got) != 2 { // cached second hit
		t.Fatalf("cached gzip tracks len = %d, want 2", len(got))
	}
	if err := deps.Tracks.UpsertAll(ctx, []repo.Track{mk("t3", "Three", "Z", "al3")}); err != nil {
		t.Fatal(err)
	}
	deps.InvalidateTracks()
	if got := tracksGz(); len(got) != 3 {
		t.Fatalf("post-invalidate gzip tracks len = %d, want 3", len(got))
	}
}
