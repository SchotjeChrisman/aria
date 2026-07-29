package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"aria/internal/db"
)

func matchesFixture(t *testing.T) (*Matches, *Tracks, *Edits, context.Context) {
	t.Helper()
	sqlDB, err := db.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { sqlDB.Close() })
	return NewMatches(sqlDB), NewTracks(sqlDB), NewEdits(sqlDB), context.Background()
}

// seed writes one track per album id so each id is a one-track album.
func seed(t *testing.T, r *Tracks, ctx context.Context, ids ...string) {
	t.Helper()
	var ts []Track
	for i, id := range ids {
		ts = append(ts, Track{ID: fmt.Sprint("t", i), Path: fmt.Sprint(id, "/1.flac"), AddedAt: "now",
			Album: "A" + id, AlbumArtist: "Artist", AlbumID: id, Size: 100})
	}
	if err := r.UpsertAll(ctx, ts); err != nil {
		t.Fatal(err)
	}
}

func pendingIDs(t *testing.T, m *Matches, ctx context.Context, now string) []string {
	t.Helper()
	ps, err := m.PendingAlbums(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, p := range ps {
		out = append(out, p.AlbumID)
	}
	return out
}

func has(ids []string, want string) bool {
	for _, id := range ids {
		if id == want {
			return true
		}
	}
	return false
}

// PendingAlbums IS the skip discipline; every exclusion and every re-inclusion
// rule lives in that one statement, so this is where they get asserted.
func TestPendingAlbumsSkipRules(t *testing.T) {
	m, tr, ed, ctx := matchesFixture(t)
	now := time.Now().UTC().Format(time.RFC3339)
	past := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	future := time.Now().Add(48 * time.Hour).UTC().Format(time.RFC3339)

	seed(t, tr, ctx, "fresh", "pinned", "locked", "userlocal", "moved", "waiting", "due", "settled")

	put := func(id, state, sig, retry string, pinned bool) {
		t.Helper()
		if err := m.Put(ctx, Decision{AlbumID: id, State: state, TrackSig: sig,
			RetryAfter: retry, Pinned: pinned, DecidedAt: now}); err != nil {
			t.Fatal(err)
		}
	}
	sig, err := m.TrackSig(ctx, "settled")
	if err != nil {
		t.Fatal(err)
	}

	put("pinned", "matched", sig, "", true)
	put("moved", "matched", "999:999", "", false) // files changed under it
	put("waiting", "review", sig, future, false)
	put("due", "review", sig, past, false)
	put("settled", "matched", sig, "", false)
	put("locked", "matched", sig, "", false)
	put("userlocal", "matched", sig, "", false)

	if err := ed.Put(ctx, "album", "locked", json.RawMessage(`{"locked":true}`)); err != nil {
		t.Fatal(err)
	}
	if err := ed.Put(ctx, "album", "userlocal", json.RawMessage(`{"state":"local"}`)); err != nil {
		t.Fatal(err)
	}

	got := pendingIDs(t, m, ctx, now)
	for _, want := range []string{"fresh", "moved", "due"} {
		if !has(got, want) {
			t.Errorf("%s is not pending, want pending (%v)", want, got)
		}
	}
	for _, no := range []string{"pinned", "locked", "userlocal", "waiting", "settled"} {
		if has(got, no) {
			t.Errorf("%s is pending, want skipped (%v)", no, got)
		}
	}
}

// Reset is "re-match everything": it must clear machine decisions and leave the
// user's pins alone.
func TestResetKeepsPins(t *testing.T) {
	m, tr, _, ctx := matchesFixture(t)
	now := time.Now().UTC().Format(time.RFC3339)
	seed(t, tr, ctx, "pinned", "auto")
	for _, d := range []Decision{
		{AlbumID: "pinned", State: "matched", Pinned: true, DecidedAt: now},
		{AlbumID: "auto", State: "matched", DecidedAt: now},
	} {
		if err := m.Put(ctx, d); err != nil {
			t.Fatal(err)
		}
	}
	if err := m.Reset(ctx); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := m.Get(ctx, "pinned"); !ok {
		t.Error("Reset dropped a pinned decision")
	}
	if _, ok, _ := m.Get(ctx, "auto"); ok {
		t.Error("Reset kept an unpinned decision")
	}
	if got := pendingIDs(t, m, ctx, now); !has(got, "auto") || has(got, "pinned") {
		t.Errorf("pending after Reset = %v, want [auto]", got)
	}
}

// The review queue carries the album's own title so the client needs no second
// request, and never contains a settled album.
func TestNonMatchedJoinsTitles(t *testing.T) {
	m, tr, _, ctx := matchesFixture(t)
	now := time.Now().UTC().Format(time.RFC3339)
	seed(t, tr, ctx, "ok", "queued")
	d1 := 0.3
	for _, d := range []Decision{
		{AlbumID: "ok", State: "matched", DecidedAt: now},
		{AlbumID: "queued", State: "review", Reason: "low-separation", Distance: &d1, DecidedAt: now,
			Candidates: json.RawMessage(`[{"mbid":"x"}]`)},
	} {
		if err := m.Put(ctx, d); err != nil {
			t.Fatal(err)
		}
	}
	got, err := m.NonMatched(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].AlbumID != "queued" {
		t.Fatalf("NonMatched = %+v, want just `queued`", got)
	}
	if got[0].Album != "Aqueued" || got[0].AlbumArtist != "Artist" {
		t.Errorf("title/artist = %q/%q, want Aqueued/Artist", got[0].Album, got[0].AlbumArtist)
	}
	if string(got[0].Candidates) != `[{"mbid":"x"}]` {
		t.Errorf("candidates round-tripped as %s", got[0].Candidates)
	}
}

// track_fp may not exist at all (no fingerprinting on this deployment). The
// matcher must degrade to text search, not fail the pass.
func TestReleaseGroupVotes(t *testing.T) {
	m, tr, _, ctx := matchesFixture(t)
	seed(t, tr, ctx, "al")
	if got := m.ReleaseGroupVotes(ctx, "al"); len(got) != 0 {
		t.Errorf("votes with no fingerprints = %v, want empty", got)
	}
	if _, err := m.db.ExecContext(ctx, `
		INSERT INTO track_fp (trackId, calculatedAt, fingerprint, duration, recordings)
		VALUES ('t0','now','fp',200,?)`,
		`[{"id":"ac","score":0.9,"recordings":[{"id":"r1","releasegroups":[{"id":"rg-a"},{"id":"rg-b"}]}]}]`,
	); err != nil {
		t.Fatal(err)
	}
	got := m.ReleaseGroupVotes(ctx, "al")
	if got["rg-a"] != 1 || got["rg-b"] != 1 {
		t.Errorf("votes = %v, want one each for rg-a and rg-b", got)
	}
}
