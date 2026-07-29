package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"slices"
	"testing"
	"time"

	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/repo"
)

// GET /api/mixes: the daily/weekly artist mix floats recordings ListenBrainz
// says the world listens to above the live sets and alternate takes that share
// their artist — without disturbing the seeded shuffle that makes the mix
// rotate day to day.
func TestMixesPopularityTiering(t *testing.T) {
	sqldb, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer sqldb.Close()
	deps := NewDeps(sqldb, config.Config{}, "test")
	ctx := context.Background()
	if err := deps.Profiles.EnsureDefault(ctx); err != nil {
		t.Fatal(err)
	}
	profiles, _ := deps.Profiles.List(ctx)
	pid := profiles[0].ID

	// 60 tracks by one artist so the cap actually bites; only the last 3 carry
	// a recording MBID ListenBrainz knows, so an untiered shuffle would leave
	// them out of the 50 far more often than not.
	var tracks []repo.Track
	for i := 0; i < 60; i++ {
		id := fmt.Sprintf("t%02d", i)
		rec := ""
		if i >= 57 {
			rec = "rec-" + id
		}
		tracks = append(tracks, repo.Track{
			ID: id, Path: id, Title: id, AlbumID: "al1", Artist: "Mudhoney", AlbumArtist: "Mudhoney",
			MBRecordingID: &rec, AddedAt: "2026-01-01T00:00:00.000Z",
		})
	}
	if err := deps.Tracks.UpsertAll(ctx, tracks); err != nil {
		t.Fatal(err)
	}
	if err := deps.Plays.Add(ctx, repo.Play{
		TrackID: "t00", ProfileID: pid, At: time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
	}); err != nil {
		t.Fatal(err)
	}

	get := func() map[string][]string {
		t.Helper()
		rec := httptest.NewRecorder()
		New(deps).ServeHTTP(rec, httptest.NewRequest("GET", "/api/mixes?profileId="+pid, nil))
		if rec.Code != 200 {
			t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
		}
		var out map[string][]string
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}

	before := get()["daily"]
	if len(before) != 50 {
		t.Fatalf("daily = %d tracks, want the documented cap of 50", len(before))
	}

	// seed the cache exactly as the enricher's popularity phase does
	doc := json.RawMessage(`{"v":1,"top":["rec-t59","rec-t58","rec-t57","rec-not-in-library"]}`)
	if err := deps.EnrichCache.Put(ctx, "popular", "artist-mbid", doc, "2026-07-01T00:00:00.000Z"); err != nil {
		t.Fatal(err)
	}

	after := get()["daily"]
	if len(after) != 50 {
		t.Fatalf("daily = %d tracks after tiering, want 50", len(after))
	}
	for _, want := range []string{"t57", "t58", "t59"} {
		if !slices.Contains(after[:3], want) {
			t.Errorf("%s not in the leading tier: %v", want, after[:3])
		}
	}
	// the shuffle is the feature: everything below the promoted tier must keep
	// the order it had before popularity existed.
	rest := slices.DeleteFunc(slices.Clone(before), func(id string) bool {
		return id == "t57" || id == "t58" || id == "t59"
	})
	if got := after[3:]; !slices.Equal(got, rest[:len(got)]) {
		t.Errorf("seeded order below the tier changed:\n got %v\nwant %v", got, rest[:len(got)])
	}
}
