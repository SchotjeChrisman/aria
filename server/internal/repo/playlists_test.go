package repo

import (
	"context"
	"testing"
)

func TestPlaylistOrderingDuplicatesAndCascade(t *testing.T) {
	d := testDB(t)
	profiles := NewProfiles(d)
	pls := NewPlaylists(d)
	plays := NewPlays(d)
	ctx := context.Background()

	if err := profiles.Create(ctx, Profile{ID: "p1", Name: "L", Color: "#000000", CreatedAt: "t"}); err != nil {
		t.Fatalf("profile: %v", err)
	}
	pl := Playlist{ID: "pl1", ProfileID: "p1", Name: "Mix", Type: "manual", CreatedAt: "t", UpdatedAt: "t"}
	if err := pls.Create(ctx, pl); err != nil {
		t.Fatalf("playlist: %v", err)
	}

	// duplicates allowed, order preserved
	for _, id := range []string{"a", "b", "a", "c"} {
		if err := pls.AddTrack(ctx, "pl1", id); err != nil {
			t.Fatalf("add %s: %v", id, err)
		}
	}
	ids, err := pls.TrackIDs(ctx, "pl1")
	if err != nil {
		t.Fatalf("trackIDs: %v", err)
	}
	want := []string{"a", "b", "a", "c"}
	if len(ids) != len(want) {
		t.Fatalf("ids = %v, want %v", ids, want)
	}
	for i := range want {
		if ids[i] != want[i] {
			t.Fatalf("ids = %v, want %v", ids, want)
		}
	}

	// remove deletes all occurrences; later adds still append after the gap
	if err := pls.RemoveTrack(ctx, "pl1", "a"); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if err := pls.AddTrack(ctx, "pl1", "d"); err != nil {
		t.Fatalf("add d: %v", err)
	}
	ids, _ = pls.TrackIDs(ctx, "pl1")
	want = []string{"b", "c", "d"}
	for i := range want {
		if ids[i] != want[i] {
			t.Fatalf("after remove ids = %v, want %v", ids, want)
		}
	}

	// profile delete cascades to playlists, playlist_tracks and plays
	if err := plays.Add(ctx, Play{TrackID: "b", ProfileID: "p1", At: "t"}); err != nil {
		t.Fatalf("play: %v", err)
	}
	if err := profiles.Delete(ctx, "p1"); err != nil {
		t.Fatalf("delete profile: %v", err)
	}
	if got, err := pls.ByID(ctx, "pl1"); err != nil || got != nil {
		t.Errorf("playlist survived cascade: %v, %v", got, err)
	}
	if ids, _ := pls.TrackIDs(ctx, "pl1"); len(ids) != 0 {
		t.Errorf("playlist_tracks survived cascade: %v", ids)
	}
	if ps, _ := plays.List(ctx, ""); len(ps) != 0 {
		t.Errorf("plays survived cascade: %v", ps)
	}
}

func TestPlaysTrimAndCounts(t *testing.T) {
	d := testDB(t)
	profiles := NewProfiles(d)
	plays := NewPlays(d)
	ctx := context.Background()

	if err := profiles.EnsureDefault(ctx); err != nil {
		t.Fatalf("default: %v", err)
	}
	for i := 0; i < 5; i++ {
		if err := plays.Add(ctx, Play{TrackID: "t1", ProfileID: "default", At: "t"}); err != nil {
			t.Fatalf("add: %v", err)
		}
	}
	if err := plays.Add(ctx, Play{TrackID: "t2", ProfileID: "default", At: "t"}); err != nil {
		t.Fatalf("add: %v", err)
	}
	counts, err := plays.CountsFor(ctx, "default")
	if err != nil || counts["t1"] != 5 || counts["t2"] != 1 {
		t.Errorf("counts = %v, %v; want t1:5 t2:1", counts, err)
	}
	if err := plays.Trim(ctx, 3); err != nil {
		t.Fatalf("trim: %v", err)
	}
	ps, _ := plays.List(ctx, "")
	if len(ps) != 3 {
		t.Fatalf("after trim len = %d, want 3", len(ps))
	}
	if ps[len(ps)-1].TrackID != "t2" { // newest kept
		t.Errorf("trim dropped newest rows: %v", ps)
	}
}
