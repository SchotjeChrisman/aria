package main

import (
	"context"
	"errors"
	"log"
	"time"

	"aria/internal/api"
	"aria/internal/scanner"
)

// periodicScan is one tick of the background rescan: walk the library, then
// decide whether the fingerprint/enrich/analyse chain has anything to do.
//
// `full` is the whole difference between the two cadences. Both walk — that is
// the only way a new album is ever discovered, and it is cheap because the
// scanner re-parses nothing whose mtime and size are unchanged. What the daily
// pass adds is running the chain on a library where NOTHING changed, which is
// the only way already-enriched albums pick up new metadata: the enricher's
// TTLs (discography 7d, popular 30d) can only expire on a pass that reaches
// them. Doing that hourly would mean 24x the requests to MusicBrainz, Discogs
// and Deezer to discover the same nothing.
func periodicScan(ctx context.Context, deps *api.Deps, full bool) {
	if deps.Scanner == nil {
		return
	}
	if _, err := deps.Scanner.Scan(ctx); err != nil {
		// ErrScanRunning is not a fault: a manual Rescan, or the previous tick
		// on a library slower to walk than the interval, already holds the lock.
		// Skipping this turn is right — but the chain must be skipped with it,
		// because LastParsed then belongs to the OTHER scan, not to this one.
		if !errors.Is(err, context.Canceled) && !errors.Is(err, scanner.ErrScanRunning) {
			log.Printf("periodic scan: %v", err)
		}
		return
	}
	deps.InvalidateTracks()
	// LastParsed is read straight after Scan returned, while this goroutine is
	// the only caller — the select loop that drives both cadences is what
	// guarantees no other tick is in flight to overwrite it.
	if parsed := deps.Scanner.LastParsed(); parsed > 0 {
		log.Printf("periodic scan: %d file(s) new or changed", parsed)
	} else if !full {
		return // quiet library, nothing for the passes to chew on
	}
	deps.RunPasses(ctx)
}

// orNever renders a disabled cadence for the startup log, so "SCAN_INTERVAL=0"
// reads as off rather than as "every 0s".
func orNever(d time.Duration) string {
	if d <= 0 {
		return "never"
	}
	return d.String()
}
