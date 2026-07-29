package enrich

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"aria/internal/repo"
)

const testAlbumID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

// mbTracksJSON renders n tracks of `base+i*30 s` as one medium.
func mbTracksJSON(n int) string {
	var ts []string
	for i := 0; i < n; i++ {
		ts = append(ts, fmt.Sprintf(`{"position":%d,"number":"%d","title":"Song %02d","length":%d}`,
			i+1, i+1, i+1, 180_000+i*30_000))
	}
	return `[{"position":1,"format":"CD","track-count":` + fmt.Sprint(n) + `,"tracks":[` + strings.Join(ts, ",") + `]}]`
}

func mbReleaseJSON(mbid, rg, title string, n int) string {
	return fmt.Sprintf(`{"id":%q,"title":%q,"date":"2019-01-01","country":"GB","track-count":%d,
		"artist-credit":[{"name":"The Beatles","joinphrase":"","artist":{"id":"a","name":"The Beatles"}}],
		"release-group":{"id":%q},"media":%s}`, mbid, title, n, rg, mbTracksJSON(n))
}

// seedAlbum writes n local tracks lining up exactly with mbReleaseJSON's.
func seedAlbum(t *testing.T, e *Enricher, ctx context.Context, n int) {
	t.Helper()
	var ts []repo.Track
	for i := 0; i < n; i++ {
		dur := float64(180+i*30) + 1 // 1 s drift, well inside the grace window
		no := i + 1
		ts = append(ts, repo.Track{
			ID: fmt.Sprint("t", i), Path: fmt.Sprintf("a/%02d.flac", i), AddedAt: "now",
			Title: fmt.Sprintf("Song %02d", i+1), Artist: "The Beatles", AlbumArtist: "The Beatles",
			Album: "Abbey Road", AlbumID: testAlbumID, TrackNo: &no, Duration: &dur, Size: 100,
		})
	}
	if err := e.tracks.UpsertAll(ctx, ts); err != nil {
		t.Fatal(err)
	}
}

// countingStub serves a MusicBrainz search plus per-release fetches and counts
// every outbound request, so "did the prefilter avoid a fetch" is assertable.
func countingStub(e *Enricher, n *int32, search string, releases map[string]string) {
	stubMB(e, func(r *http.Request) (*http.Response, error) {
		atomic.AddInt32(n, 1)
		if !strings.Contains(r.URL.Host, "musicbrainz") {
			return resp(404, ""), nil
		}
		if strings.Contains(r.URL.RawQuery, "query=") {
			return resp(200, search), nil
		}
		for mbid, body := range releases {
			if strings.Contains(r.URL.Path, mbid) {
				return resp(200, body), nil
			}
		}
		return resp(404, ""), nil
	})
}

func mustPending(t *testing.T, e *Enricher, ctx context.Context) []repo.PendingAlbum {
	t.Helper()
	p, err := e.matches.PendingAlbums(ctx, nowISO())
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// The prefilter must drop a wrong-track-count candidate BEFORE spending a
// verification fetch on it — that is the whole reason search hits and
// inc=media browses are asked for the count.
func TestPrefilterAvoidsVerificationFetch(t *testing.T) {
	e, ctx := newTestEnricher(t)
	seedAlbum(t, e, ctx, 12)

	search := `{"releases":[` +
		mbReleaseJSON("mb-right", "rg-1", "Abbey Road", 12) + `,` +
		mbReleaseJSON("mb-wrong", "rg-2", "Abbey Road Box Set", 40) + `]}`
	var n int32
	countingStub(e, &n, search, map[string]string{
		"mb-right": mbReleaseJSON("mb-right", "rg-1", "Abbey Road", 12),
		"mb-wrong": mbReleaseJSON("mb-wrong", "rg-2", "Abbey Road Box Set", 40),
	})

	if err := e.runMatching(ctx); err != nil {
		t.Fatal(err)
	}
	// 1 search + 1 verification fetch. A second fetch means the 40-track box
	// set was verified anyway.
	if got := atomic.LoadInt32(&n); got != 2 {
		t.Errorf("requests = %d, want 2 (search + one verification)", got)
	}
	d, ok, err := e.matches.Get(ctx, testAlbumID)
	if err != nil || !ok {
		t.Fatalf("no decision stored (ok=%v err=%v)", ok, err)
	}
	if d.State != "matched" || d.ReleaseMbid == nil || *d.ReleaseMbid != "mb-right" {
		t.Errorf("decision = %s/%v, want matched/mb-right", d.State, d.ReleaseMbid)
	}
}

// A settled album must cost ZERO requests on every later pass — that is what
// makes the boot-time Run on a stable library one query and an idle frame.
func TestDecidedAlbumCostsNothingOnTheNextPass(t *testing.T) {
	e, ctx := newTestEnricher(t)
	seedAlbum(t, e, ctx, 12)
	body := mbReleaseJSON("mb-right", "rg-1", "Abbey Road", 12)
	var n int32
	countingStub(e, &n, `{"releases":[`+body+`]}`, map[string]string{"mb-right": body})

	if err := e.runMatching(ctx); err != nil {
		t.Fatal(err)
	}
	first := atomic.LoadInt32(&n)
	if first == 0 {
		t.Fatal("first pass made no requests at all")
	}
	if err := e.runMatching(ctx); err != nil {
		t.Fatal(err)
	}
	if got := atomic.LoadInt32(&n) - first; got != 0 {
		t.Errorf("second pass made %d requests, want 0", got)
	}
}

// review/local carry a retryAfter, and that timestamp is the whole retry
// discipline: pending while in the future is a bug, and the wait doubles.
func TestRetryAfterBlocksAndDoubles(t *testing.T) {
	e, ctx := newTestEnricher(t)
	seedAlbum(t, e, ctx, 12)
	// Two same-scoring candidates in different release groups: the veto fires,
	// so the album lands in review with a retryAfter.
	a := mbReleaseJSON("mb-a", "rg-a", "Abbey Road", 12)
	b := mbReleaseJSON("mb-b", "rg-b", "Abbey Road", 12)
	var n int32
	countingStub(e, &n, `{"releases":[`+a+`,`+b+`]}`, map[string]string{"mb-a": a, "mb-b": b})

	if err := e.runMatching(ctx); err != nil {
		t.Fatal(err)
	}
	d, ok, _ := e.matches.Get(ctx, testAlbumID)
	if !ok || d.State == "matched" {
		t.Fatalf("decision = %v; two indistinguishable groups must not produce a match", d)
	}
	if d.RetryAfter == "" {
		t.Fatal("retryAfter empty; an undecided album must come back")
	}
	first, err := time.Parse(time.RFC3339, d.RetryAfter)
	if err != nil {
		t.Fatal(err)
	}
	if len(mustPending(t, e, ctx)) != 0 {
		t.Error("album is pending while its retry window is still open")
	}

	// Wind the clock forward by hand (the ladder is keyed off attempts, and
	// the stored instant is what PendingAlbums compares against).
	if p, _ := e.matches.PendingAlbums(ctx, first.Add(time.Second).UTC().Format(time.RFC3339)); len(p) != 1 {
		t.Fatalf("pending after the window elapsed = %d, want 1", len(p))
	} else if _, err := e.matchOne(ctx, p[0], mustTracks(t, e, ctx), 0.10, 0.25); err != nil {
		t.Fatal(err)
	}
	d2, _, _ := e.matches.Get(ctx, testAlbumID)
	if d2.Attempts != 2 {
		t.Errorf("attempts = %d, want 2", d2.Attempts)
	}
	second, err := time.Parse(time.RFC3339, d2.RetryAfter)
	if err != nil {
		t.Fatal(err)
	}
	// 24h then 48h, both measured from roughly now, so the second window must
	// be the best part of a day further out.
	if second.Sub(first) < 20*time.Hour {
		t.Errorf("second retryAfter %v is not meaningfully later than the first %v", second, first)
	}
}

// A pin is the user's decision and outranks the matcher permanently.
func TestPinnedDecisionIsNeverReconsidered(t *testing.T) {
	e, ctx := newTestEnricher(t)
	seedAlbum(t, e, ctx, 12)
	if err := e.PinAlbumMatch(ctx, testAlbumID, "11111111-1111-1111-1111-111111111111"); err != nil {
		t.Fatal(err)
	}
	if p := mustPending(t, e, ctx); len(p) != 0 {
		t.Fatalf("pinned album is pending (%d)", len(p))
	}
	var n int32
	countingStub(e, &n, `{"releases":[]}`, nil)
	if err := e.runMatching(ctx); err != nil {
		t.Fatal(err)
	}
	if got := atomic.LoadInt32(&n); got != 0 {
		t.Errorf("pinned album cost %d requests, want 0", got)
	}
	d, _, _ := e.matches.Get(ctx, testAlbumID)
	if !d.Pinned || d.Reason != "pinned" || *d.ReleaseMbid != "11111111-1111-1111-1111-111111111111" {
		t.Errorf("pin was overwritten: %+v", d)
	}
}

// Regression guard for the constraint that outranks everything else here: a
// match may NEVER change an albumId. Re-keying orphans tag_items, enrich_cache,
// edits and DATA_DIR/art/* (see 007_album_identity.sql).
func TestMatchingNeverChangesAlbumID(t *testing.T) {
	e, ctx := newTestEnricher(t)
	seedAlbum(t, e, ctx, 12)
	before, err := e.tracks.ListAll(ctx)
	if err != nil {
		t.Fatal(err)
	}
	body := mbReleaseJSON("mb-right", "rg-1", "A Completely Different Title", 12)
	var n int32
	countingStub(e, &n, `{"releases":[`+body+`]}`, map[string]string{"mb-right": body})
	if err := e.runMatching(ctx); err != nil {
		t.Fatal(err)
	}
	after, err := e.tracks.ListAll(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for i := range before {
		if before[i].AlbumID != after[i].AlbumID || after[i].AlbumID != testAlbumID {
			t.Fatalf("albumId moved: %q -> %q", before[i].AlbumID, after[i].AlbumID)
		}
	}
}

// The fetch cap bounds one album's worst case, which is also the interactive
// route's latency ceiling.
func TestVerificationFetchCap(t *testing.T) {
	e, ctx := newTestEnricher(t)
	seedAlbum(t, e, ctx, 12)

	var hits []string
	releases := map[string]string{}
	for i := 0; i < 30; i++ {
		mbid := fmt.Sprint("mb-", i)
		body := mbReleaseJSON(mbid, fmt.Sprint("rg-", i), "Abbey Road", 12)
		hits = append(hits, body)
		releases[mbid] = body
	}
	var n int32
	countingStub(e, &n, `{"releases":[`+strings.Join(hits, ",")+`]}`, releases)

	if err := e.runMatching(ctx); err != nil {
		t.Fatal(err)
	}
	if got := atomic.LoadInt32(&n); got != 1+maxVerify {
		t.Errorf("requests = %d, want %d (1 search + %d verifications)", got, 1+maxVerify, maxVerify)
	}
	d, _, _ := e.matches.Get(ctx, testAlbumID)
	var cands []map[string]any
	if err := json.Unmarshal(d.Candidates, &cands); err != nil {
		t.Fatal(err)
	}
	if len(cands) != maxVerify {
		t.Errorf("stored %d candidates, want %d", len(cands), maxVerify)
	}
}

// enrichAlbum must take its MBID from the decision and nothing else — no
// unverified top hit, and `local` means it does not look the album up at all.
func TestEnrichAlbumHonoursTheDecision(t *testing.T) {
	e, ctx := newTestEnricher(t)
	seedAlbum(t, e, ctx, 2)
	ts := mustTracks(t, e, ctx)

	var n int32
	stubMB(e, func(r *http.Request) (*http.Response, error) { atomic.AddInt32(&n, 1); return resp(404, ""), nil })

	// Undecided: no request, and no V marker, so the album stays in the todo set.
	if err := e.enrichAlbum(ctx, testAlbumID, ts); err != nil {
		t.Fatal(err)
	}
	if got := atomic.LoadInt32(&n); got != 0 {
		t.Errorf("undecided album made %d requests, want 0 (the unverified search is gone)", got)
	}
	if _, ok, _ := e.cache.Get(ctx, KindAlbum, testAlbumID); ok {
		t.Error("undecided album was cached; it must stay pending")
	}

	// local: skipped entirely, still no request.
	if err := e.matches.Put(ctx, repo.Decision{AlbumID: testAlbumID, State: "local",
		Reason: "indistinguishable-siblings", DecidedAt: nowISO()}); err != nil {
		t.Fatal(err)
	}
	if err := e.enrichAlbum(ctx, testAlbumID, ts); err != nil {
		t.Fatal(err)
	}
	if got := atomic.LoadInt32(&n); got != 0 {
		t.Errorf("local album made %d requests, want 0", got)
	}
	var a albumCache
	if !e.cacheGet(ctx, KindAlbum, testAlbumID, &a) || a.Mbid != nil {
		t.Errorf("local album cache = %+v, want V-marked with no mbid", a)
	}
}

func mustTracks(t *testing.T, e *Enricher, ctx context.Context) []repo.Track {
	t.Helper()
	ts, err := e.tracks.ByAlbum(ctx, testAlbumID)
	if err != nil {
		t.Fatal(err)
	}
	return ts
}
