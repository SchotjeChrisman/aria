package repo

import (
	"context"
	"database/sql"
	"testing"
)

func TestFPPendingIsTheIncrementalRule(t *testing.T) {
	d := testDB(t)
	tr, fp := NewTracks(d), NewFP(d)
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
		ps, err := fp.ListPendingFP(ctx)
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
		t.Fatalf("unfingerprinted library: pending = %v, want both", got)
	}
	if err := fp.PutFP(ctx, "id1", "AQADtE", 300, 100, 1000, "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if got := pendingIDs(); len(got) != 1 || got[0] != "id2" {
		t.Errorf("after fingerprinting id1: pending = %v, want [id2]", got)
	}

	// Bytes moved -> pending again. A fingerprint is a pure function of the
	// bytes, so this is the only freshness rule there is.
	for _, tc := range []struct {
		name        string
		mtime, size int64
	}{
		{"mtime bump", 101, 1000},
		{"size change", 100, 1001},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t1.Mtime, t1.Size = tc.mtime, tc.size
			if err := tr.UpsertAll(ctx, []Track{t1}); err != nil {
				t.Fatal(err)
			}
			if got := pendingIDs(); len(got) != 2 {
				t.Errorf("pending = %v, want both", got)
			}
		})
	}
}

// A re-fingerprint must drop the old AcoustID answer: the bytes moved, so the
// stored match describes a file that no longer exists.
func TestPutFPClearsStaleLookup(t *testing.T) {
	d := testDB(t)
	tr, fp := NewTracks(d), NewFP(d)
	ctx := context.Background()
	t1 := track("id1", "a/one.flac", "One", "A", "Alb")
	t1.Mtime, t1.Size = 100, 1000
	if err := tr.UpsertAll(ctx, []Track{t1}); err != nil {
		t.Fatal(err)
	}
	if err := fp.PutFP(ctx, "id1", "AQADtE", 300, 100, 1000, "2026-01-01T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	id, score, recs := "acoust-uuid", 0.98, `[{"id":"x"}]`
	if err := fp.PutLookup(ctx, "id1", &id, &score, &recs, "2026-01-02T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if id, _, _ := lookupOf(t, d, "id1"); id == nil {
		t.Fatal("lookup not stored")
	}
	if err := fp.PutFP(ctx, "id1", "AQADdifferent", 305, 101, 1000, "2026-01-03T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if id, score, recs := lookupOf(t, d, "id1"); id != nil || score != nil || recs != nil {
		t.Errorf("stale lookup survived a re-fingerprint: %v %v %v", id, score, recs)
	}
	pend, _ := fp.ListPendingLookup(ctx, 10)
	if len(pend) != 1 {
		t.Errorf("re-fingerprinted track not queued for lookup again: %v", pend)
	}
}

func TestLookupPendingAndErrors(t *testing.T) {
	d := testDB(t)
	tr, fp := NewTracks(d), NewFP(d)
	ctx := context.Background()
	t1, t2 := track("id1", "a/one.flac", "One", "A", "Alb"), track("id2", "a/two.flac", "Two", "A", "Alb")
	if err := tr.UpsertAll(ctx, []Track{t1, t2}); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"id1", "id2"} {
		if err := fp.PutFP(ctx, id, "AQAD"+id, 300, 0, 0, "2026-01-01T00:00:00Z"); err != nil {
			t.Fatal(err)
		}
	}
	if n, err := fp.CountPendingLookup(ctx); err != nil || n != 2 {
		t.Fatalf("count = %d (%v), want 2", n, err)
	}
	if got, _ := fp.ListPendingLookup(ctx, 1); len(got) != 1 {
		t.Errorf("limit ignored: %v", got)
	}

	// A no-match is a successful lookup: nothing stored, but not asked again.
	if err := fp.PutLookup(ctx, "id1", nil, nil, nil, "2026-01-02T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if n, _ := fp.CountPendingLookup(ctx); n != 1 {
		t.Errorf("a no-match must still count as looked up, pending = %d", n)
	}

	// An error must stay retryable: lookedUpAt is deliberately left NULL, so an
	// invalid key cannot permanently mark the library as "no match".
	if err := fp.PutLookupError(ctx, "id2", "invalid API key"); err != nil {
		t.Fatal(err)
	}
	if n, _ := fp.CountPendingLookup(ctx); n != 1 {
		t.Errorf("a failed lookup must stay pending, pending = %d", n)
	}
}

// lookupOf reads the three AcoustID columns straight out of the row. There is
// no repo accessor for them: nothing in production reads a whole track_fp row —
// the matcher unwraps `recordings` in SQL with json_each (Matches.
// ReleaseGroupVotes) rather than dragging ~2.6 KB of JSON per track into Go.
func lookupOf(t *testing.T, db *sql.DB, trackID string) (id *string, score *float64, recs *string) {
	t.Helper()
	err := db.QueryRow(`SELECT acoustId, score, recordings FROM track_fp WHERE trackId = ?`,
		trackID).Scan(&id, &score, &recs)
	if err != nil {
		t.Fatal(err)
	}
	return
}
