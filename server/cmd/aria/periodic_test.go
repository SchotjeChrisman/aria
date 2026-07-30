package main

import (
	"context"
	"errors"
	"testing"

	"aria/internal/api"
	"aria/internal/scanner"
)

// fakeScanner records how often Scan ran and reports whatever LastParsed the
// test set, which is the one input periodicScan branches on.
type fakeScanner struct {
	scans      int
	lastParsed int
	err        error
}

func (f *fakeScanner) Scan(context.Context) (int, error) {
	f.scans++
	return 0, f.err
}
func (f *fakeScanner) LastParsed() int { return f.lastParsed }
func (f *fakeScanner) Status() any     { return nil }

// fakeEnricher stands in for the whole chain: RunPasses drives the enricher
// second, so counting its runs counts the chain's runs.
type fakeEnricher struct{ runs int }

func (f *fakeEnricher) Run(context.Context) error { f.runs++; return nil }
func (f *fakeEnricher) Status() any               { return nil }

func newDeps(sc api.Scanner, en api.Enricher) *api.Deps {
	d := &api.Deps{Bg: context.Background()}
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
		name       string
		full       bool
		lastParsed int
		wantChain  int
	}{
		{name: "quiet hour skips the chain", full: false, lastParsed: 0, wantChain: 0},
		{name: "new files earn the chain", full: false, lastParsed: 3, wantChain: 1},
		{name: "daily runs it on a quiet library", full: true, lastParsed: 0, wantChain: 1},
		{name: "daily runs it after changes too", full: true, lastParsed: 3, wantChain: 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sc := &fakeScanner{lastParsed: tc.lastParsed}
			en := &fakeEnricher{}
			d := newDeps(sc, en)

			periodicScan(context.Background(), d, tc.full)

			if sc.scans != 1 {
				t.Errorf("scans = %d, want 1 — every cadence walks the library", sc.scans)
			}
			if en.runs != tc.wantChain {
				t.Errorf("chain ran %d times, want %d", en.runs, tc.wantChain)
			}
		})
	}
}

// A failed scan must not be followed by the passes: the walk is what tells the
// rest of the chain what exists, and running them on a half-read library (a
// dropped NFS mount is the real case) acts on tracks that were never confirmed.
func TestPeriodicScanSkipsChainWhenScanFails(t *testing.T) {
	for _, err := range []error{errors.New("mount gone"), scanner.ErrScanRunning, context.Canceled} {
		sc := &fakeScanner{lastParsed: 9, err: err}
		en := &fakeEnricher{}

		periodicScan(context.Background(), newDeps(sc, en), true)

		if en.runs != 0 {
			t.Errorf("scan failed with %v but the chain still ran", err)
		}
	}
}
