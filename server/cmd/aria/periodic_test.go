package main

import (
	"context"
	"errors"
	"testing"

	"aria/internal/api"
	"aria/internal/scanner"
)

// fakeScanner records how often Scan ran and reports whatever LastParsed and
// LastChanged the test set — the two inputs periodicScan branches on, kept
// separate here because the real scanner separates them: a deleted file
// changes the library without re-reading anything.
type fakeScanner struct {
	scans       int
	lastParsed  int
	lastChanged bool
	err         error
}

func (f *fakeScanner) Scan(context.Context) (int, error) {
	f.scans++
	return 0, f.err
}
func (f *fakeScanner) LastParsed() int   { return f.lastParsed }
func (f *fakeScanner) LastChanged() bool { return f.lastChanged }
func (f *fakeScanner) Status() any       { return nil }

// fakeEnricher stands in for the whole chain: RunPasses drives the enricher
// second, so counting its runs counts the chain's runs.
type fakeEnricher struct{ runs int }

func (f *fakeEnricher) Run(context.Context) error { f.runs++; return nil }
func (f *fakeEnricher) Status() any               { return nil }

func newDeps(sc api.Scanner, en api.Enricher) *api.Deps {
	d := &api.Deps{Bg: context.Background(), Events: api.NewHub()}
	d.Scanner = sc
	d.Enricher = en
	return d
}

// The whole point of two cadences: the hourly one must not hit MusicBrainz,
// Discogs and Deezer every hour for a library nobody has touched. It earns the
// chain by finding something; the daily one runs it regardless, which is what
// lets the enricher's own TTLs expire and refresh EXISTING albums.
func TestPeriodicScanRunsChainOnlyWhenItNeedsTo(t *testing.T) {
	cases := []struct {
		name        string
		full        bool
		lastParsed  int
		lastChanged bool
		wantChain   int
		// Frames connected clients receive. The chain contributes one of its own
		// (RunPasses invalidates behind the enricher), so counting separates the
		// tick's OWN announcement from the chain's instead of conflating them.
		wantFrames int
	}{
		{name: "quiet hour tells nobody", full: false, lastParsed: 0, wantChain: 0, wantFrames: 0},
		{name: "new files earn the chain", full: false, lastParsed: 3, lastChanged: true, wantChain: 1, wantFrames: 2},
		{name: "daily runs it on a quiet library", full: true, lastParsed: 0, wantChain: 1, wantFrames: 1},
		{name: "daily runs it after changes too", full: true, lastParsed: 3, lastChanged: true, wantChain: 1, wantFrames: 2},
		// Deletions re-read nothing, so there is nothing for the passes to
		// enrich — but the library DID move and clients must be told, which is
		// the case LastParsed alone cannot see.
		{name: "deleted files announce without the chain", full: false, lastParsed: 0, lastChanged: true, wantChain: 0, wantFrames: 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := &fakeScanner{lastParsed: tc.lastParsed, lastChanged: tc.lastChanged}
			en := &fakeEnricher{}
			d := newDeps(sc, en)
			frames, cancel := d.Events.Subscribe()
			defer cancel()

			periodicScan(context.Background(), d, tc.full)

			if sc.scans != 1 {
				t.Errorf("scans = %d, want 1 — every cadence walks the library", sc.scans)
			}
			if en.runs != tc.wantChain {
				t.Errorf("chain ran %d times, want %d", en.runs, tc.wantChain)
			}
			var got int
			for drain := true; drain; {
				select {
				case <-frames:
					got++
				default:
					drain = false
				}
			}
			if got != tc.wantFrames {
				t.Errorf("clients got %d library frames, want %d", got, tc.wantFrames)
			}
		})
	}
}

// A failed scan must not be followed by the passes: the walk is what tells the
// rest of the chain what exists, and running them on a half-read library (a
// dropped NFS mount is the real case) acts on tracks that were never confirmed.
func TestPeriodicScanSkipsChainWhenScanFails(t *testing.T) {
	for _, err := range []error{errors.New("mount gone"), scanner.ErrScanRunning, context.Canceled} {
		sc := &fakeScanner{lastParsed: 9, lastChanged: true, err: err}
		en := &fakeEnricher{}

		periodicScan(context.Background(), newDeps(sc, en), true)

		if en.runs != 0 {
			t.Errorf("scan failed with %v but the chain still ran", err)
		}
	}
}
