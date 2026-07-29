package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"aria/internal/repo"
)

// fakeMatcher is the Enricher surface plus MatchAlbum — no network, no MB.
type fakeMatcher struct {
	fakeAnalyzer
	calls int
}

func (f *fakeMatcher) MatchAlbum(ctx context.Context, albumID string, ts []repo.Track) (*repo.Decision, error) {
	f.calls++
	mbid := "11111111-1111-1111-1111-111111111111"
	return &repo.Decision{AlbumID: albumID, State: "matched", Reason: "ok",
		ReleaseMbid: &mbid, Candidates: json.RawMessage(`[]`)}, nil
}

func matchDeps(t *testing.T) *Deps {
	t.Helper()
	d := analyzeDeps(t)
	if err := d.Tracks.UpsertAll(context.Background(), []repo.Track{
		{ID: "t1", Path: "a/1.flac", AddedAt: "now", Album: "Abbey Road", AlbumArtist: "The Beatles", AlbumID: "al1"},
	}); err != nil {
		t.Fatal(err)
	}
	return d
}

func TestReviewQueueShape(t *testing.T) {
	d := matchDeps(t)
	ctx := context.Background()
	dist, sep := 0.16, 0.01
	if err := d.Matches.Put(ctx, repo.Decision{
		AlbumID: "al1", State: "local", Reason: "indistinguishable-siblings",
		Distance: &dist, Separation: &sep, Attempts: 1, DecidedAt: "now", RetryAfter: "later",
		Candidates: json.RawMessage(`[{"mbid":"mb-1","rgMbid":"rg-1","why":{"trackLength":0.51}}]`),
	}); err != nil {
		t.Fatal(err)
	}
	rec := record(New(d), httptest.NewRequest("GET", "/api/match/review", nil))
	if rec.Code != 200 {
		t.Fatalf("code = %d", rec.Code)
	}
	var got []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("review queue = %v, want one entry", got)
	}
	// The `why` breakdown is the point: "thirteen candidates all match on
	// titles and fail on durations" is not sayable from a bare number.
	for _, k := range []string{"albumId", "album", "albumArtist", "state", "reason",
		"distance", "separation", "attempts", "retryAfter", "candidates"} {
		if _, ok := got[0][k]; !ok {
			t.Errorf("review entry missing %q (%v)", k, got[0])
		}
	}
	if got[0]["album"] != "Abbey Road" {
		t.Errorf("album = %v, want the joined title", got[0]["album"])
	}
}

func TestGetAlbumMatch404WhenUndecided(t *testing.T) {
	d := matchDeps(t)
	if rec := record(New(d), httptest.NewRequest("GET", "/api/albums/al1/match", nil)); rec.Code != 404 {
		t.Errorf("undecided album = %d, want 404", rec.Code)
	}
}

func TestPostAlbumMatch(t *testing.T) {
	d := matchDeps(t)
	fm := &fakeMatcher{}
	d.Enricher = fm
	h := New(d)

	if rec := record(h, httptest.NewRequest("POST", "/api/albums/nope/match", nil)); rec.Code != 404 {
		t.Errorf("unknown album = %d, want 404", rec.Code)
	}
	rec := record(h, httptest.NewRequest("POST", "/api/albums/al1/match", nil))
	if rec.Code != 200 || fm.calls != 1 {
		t.Fatalf("code = %d, calls = %d", rec.Code, fm.calls)
	}
	var got map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got["state"] != "matched" {
		t.Errorf("state = %v, want matched", got["state"])
	}
}

// POST /api/match {"force":true} clears machine decisions and kicks the pass;
// pins survive, because they are the user's.
func TestPostMatchForceResets(t *testing.T) {
	d := matchDeps(t)
	ctx := context.Background()
	for _, dec := range []repo.Decision{
		{AlbumID: "al1", State: "matched", DecidedAt: "now"},
		{AlbumID: "pin", State: "matched", Pinned: true, DecidedAt: "now"},
	} {
		if err := d.Matches.Put(ctx, dec); err != nil {
			t.Fatal(err)
		}
	}
	fm := &fakeMatcher{}
	d.Enricher = fm
	rec := record(New(d), httptest.NewRequest("POST", "/api/match", strings.NewReader(`{"force":true}`)))
	if rec.Code != 200 {
		t.Fatalf("code = %d", rec.Code)
	}
	d.WaitBg()
	if fm.runs != 1 {
		t.Errorf("Run calls = %d, want 1", fm.runs)
	}
	if _, ok, _ := d.Matches.Get(ctx, "al1"); ok {
		t.Error("force did not clear the unpinned decision")
	}
	if _, ok, _ := d.Matches.Get(ctx, "pin"); !ok {
		t.Error("force cleared a pinned decision")
	}
}

// The album editor's `original` block is where the matcher's conclusion
// surfaces; the socket was pre-placed for exactly this.
func TestAlbumEditsOriginalCarriesMatchState(t *testing.T) {
	d := matchDeps(t)
	ctx := context.Background()
	if err := d.Matches.Put(ctx, repo.Decision{AlbumID: "al1", State: "review",
		Reason: "low-separation", Disambiguation: "2019-05, Amsterdam", DecidedAt: "now"}); err != nil {
		t.Fatal(err)
	}
	rec := record(New(d), httptest.NewRequest("GET", "/api/edits/album/al1", nil))
	if rec.Code != 200 {
		t.Fatalf("code = %d: %s", rec.Code, rec.Body)
	}
	var got struct {
		Original map[string]any `json:"original"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Original["state"] != "review" {
		t.Errorf("original.state = %v, want review", got.Original["state"])
	}
	if got.Original["disambiguation"] != "2019-05, Amsterdam" {
		t.Errorf("original.disambiguation = %v", got.Original["disambiguation"])
	}
	// locked has no derived side — it is a user field only.
	if got.Original["locked"] != nil {
		t.Errorf("original.locked = %v, want null", got.Original["locked"])
	}
}

func TestSettingsMatchThresholds(t *testing.T) {
	d := matchDeps(t)
	h := New(d)

	var got map[string]any
	rec := record(h, httptest.NewRequest("GET", "/api/settings", nil))
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got["matchMaxDistance"] != 0.10 || got["matchMinSeparation"] != 0.25 {
		t.Errorf("defaults = %v / %v, want 0.10 / 0.25", got["matchMaxDistance"], got["matchMinSeparation"])
	}

	for _, body := range []string{`{"matchMaxDistance":0}`, `{"matchMaxDistance":1.5}`, `{"matchMinSeparation":-1}`} {
		if rec := record(h, httptest.NewRequest("POST", "/api/settings", strings.NewReader(body))); rec.Code != 400 {
			t.Errorf("POST %s = %d, want 400", body, rec.Code)
		}
	}
	if rec := record(h, httptest.NewRequest("POST", "/api/settings",
		strings.NewReader(`{"matchMaxDistance":0.04,"matchMinSeparation":0.3}`))); rec.Code != 200 {
		t.Fatalf("valid POST = %d", rec.Code)
	}
	rec = record(h, httptest.NewRequest("GET", "/api/settings", nil))
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got["matchMaxDistance"] != 0.04 || got["matchMinSeparation"] != 0.3 {
		t.Errorf("stored = %v / %v, want 0.04 / 0.3", got["matchMaxDistance"], got["matchMinSeparation"])
	}
}
