package repo

import (
	"context"
	"testing"
)

func TestAudioPendingIsTheIncrementalRule(t *testing.T) {
	d := testDB(t)
	tr, au := NewTracks(d), NewAudio(d)
	ctx := context.Background()

	t1 := track("id1", "a/one.flac", "One", "A", "Alb")
	t1.Mtime, t1.Size = 100, 1000
	t2 := track("id2", "a/two.flac", "Two", "A", "Alb")
	t2.Mtime, t2.Size = 200, 2000
	if err := tr.UpsertAll(ctx, []Track{t1, t2}); err != nil {
		t.Fatal(err)
	}

	pendingIDs := func() []string {
		t.Helper()
		ps, err := au.ListPending(ctx)
		if err != nil {
			t.Fatal(err)
		}
		out := make([]string, len(ps))
		for i, p := range ps {
			out[i] = p.ID
		}
		return out
	}

	if got := pendingIDs(); len(got) != 2 {
		t.Fatalf("unanalysed library: pending = %v, want both", got)
	}
	if err := au.Put(ctx, TrackAudio{TrackID: "id1", Codec: "flac", Lossless: true},
		100, 1000, "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if got := pendingIDs(); len(got) != 1 || got[0] != "id2" {
		t.Errorf("after analysing id1: pending = %v, want [id2]", got)
	}

	// Bytes moved -> pending again. This is the only freshness rule there is:
	// no content hash, no analysedAt comparison.
	t1.Mtime = 101
	if err := tr.UpsertAll(ctx, []Track{t1}); err != nil {
		t.Fatal(err)
	}
	if got := pendingIDs(); len(got) != 2 {
		t.Errorf("after mtime bump: pending = %v, want both", got)
	}
	t1.Mtime, t1.Size = 100, 1001
	if err := tr.UpsertAll(ctx, []Track{t1}); err != nil {
		t.Fatal(err)
	}
	if got := pendingIDs(); len(got) != 2 {
		t.Errorf("after size change: pending = %v, want both", got)
	}
}

func TestAudioCascadesWithTheTrack(t *testing.T) {
	// The whole point of the FK: DeleteNotIn must not leak track_audio rows.
	// Also the only check in the suite that PRAGMA foreign_keys is still on.
	d := testDB(t)
	tr, au := NewTracks(d), NewAudio(d)
	ctx := context.Background()
	if err := tr.UpsertAll(ctx, []Track{track("id1", "a/one.flac", "One", "A", "Alb")}); err != nil {
		t.Fatal(err)
	}
	if err := au.Put(ctx, TrackAudio{TrackID: "id1"}, 0, 0, "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	// counted here rather than through a repo method: nothing in production
	// needs the count yet, and a method existing only for its own test is
	// exactly the dead surface this row is about
	rows := func() int {
		t.Helper()
		var n int
		if err := d.QueryRowContext(ctx, `SELECT COUNT(*) FROM track_audio`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := rows(); n != 1 {
		t.Fatalf("count = %d, want 1", n)
	}
	if _, err := tr.DeleteNotIn(ctx, []string{"other"}); err != nil {
		t.Fatal(err)
	}
	if n := rows(); n != 0 {
		t.Errorf("count = %d after the track went away — foreign_keys is off", n)
	}
}

func TestAudioPutIsAnUpsert(t *testing.T) {
	d := testDB(t)
	tr, au := NewTracks(d), NewAudio(d)
	ctx := context.Background()
	if err := tr.UpsertAll(ctx, []Track{track("id1", "a/one.flac", "One", "A", "Alb")}); err != nil {
		t.Fatal(err)
	}
	lufs := -21.3
	for _, row := range []TrackAudio{
		{TrackID: "id1", Codec: "aac", Lossless: false, Suspect: true},
		{TrackID: "id1", Codec: "flac", Lossless: true, IntegratedLUFS: &lufs, SampleRate: intp(44100)},
	} {
		if err := au.Put(ctx, row, 1, 2, "2026-01-01T00:00:00Z"); err != nil {
			t.Fatal(err)
		}
	}
	all, err := au.ListAll(ctx)
	if err != nil {
		t.Fatal(err)
	}
	got := all["id1"]
	if len(all) != 1 || got.Codec != "flac" || !got.Lossless || got.Suspect ||
		got.IntegratedLUFS == nil || *got.IntegratedLUFS != -21.3 || *got.SampleRate != 44100 {
		t.Errorf("re-analysis did not replace the row: %+v", got)
	}
	// nullable columns really do round-trip as NULL, not as 0
	if got.LRA != nil || got.TruePeakDBFS != nil || got.BitsPerSample != nil || got.Channels != nil {
		t.Errorf("unmeasured columns came back non-nil: %+v", got)
	}
}
