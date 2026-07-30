package main

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"aria/internal/analyze"
	"aria/internal/api"
	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/enrich"
	"aria/internal/fingerprint"
	"aria/internal/scanner"
)

const version = "3.0.0"

// clearUnpinnedDecisions drops every non-pinned match decision so the next
// enrichment pass re-decides the album from scratch, and reports how many went.
// Raw SQL rather than repo.Matches.Reset only for that count — a boot-time
// one-shot that silently empties a table is the one thing the log should say.
func clearUnpinnedDecisions(ctx context.Context, db *sql.DB) (int64, error) {
	res, err := db.ExecContext(ctx, `DELETE FROM match_decisions WHERE COALESCE(pinned, 0) = 0`)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func main() {
	healthcheck := flag.Bool("healthcheck", false, "probe /healthz on localhost and exit 0/1 (container healthcheck)")
	flag.Parse()
	cfg := config.FromEnv()
	if *healthcheck {
		// distroless has no shell/curl; the binary is its own probe.
		c := &http.Client{Timeout: 2 * time.Second}
		resp, err := c.Get("http://127.0.0.1:" + cfg.Port + "/healthz")
		if err != nil || resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}
	sqlDB, err := db.Open(cfg.DataDir)
	if err != nil {
		log.Fatalf("db: %v", err)
	}
	defer sqlDB.Close()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	deps := api.NewDeps(sqlDB, cfg, version)
	deps.Bg = ctx // background scan/enrich stop on SIGTERM, drained via WaitBg
	if _, err := exec.LookPath(cfg.FFmpegPath); err == nil {
		deps.CanTranscode = true
		log.Printf("transcoding enabled: %s", cfg.FFmpegPath)
	}
	// Reap orphaned transcode temp files left by a crash/OOM mid-encode; boot
	// is the safe point (no active encode can be mid-write) and sweepCache
	// neither counts nor deletes .part files.
	if parts, _ := filepath.Glob(filepath.Join(cfg.DataDir, "tc", "*.part")); parts != nil {
		for _, m := range parts {
			os.Remove(m)
		}
	}
	sc := scanner.New(cfg.MusicDir, cfg.DataDir, deps.Tracks, deps.Albums, func(done, total int) {
		deps.Events.Publish("scan", map[string]int{"done": done, "total": total})
	})
	deps.Scanner = sc
	enr := enrich.New(ctx, deps.Tracks, deps.EnrichCache, deps.Matches, deps.Settings, cfg.DataDir, cfg.DiscogsToken)
	enr.Notify = func(status any) { deps.Events.Publish("enrich", status) }
	deps.Enricher = enr

	// Must come after deps.Scanner: the analyzer takes sc.Busy so it can stay
	// off the disk while a scan walks it, and wiring this up in the LookPath
	// block above would silently hand it a nil Busy with nothing to notice.
	if deps.CanTranscode {
		an := analyze.New(cfg.FFmpegPath, cfg.MusicDir, deps.Audio)
		an.Notify = func(status any) { deps.Events.Publish("analyze", status) }
		an.Busy = sc.Busy
		deps.Analyzer = an
	}
	// fpcalc is probed by RUNNING it, not with exec.LookPath: the arm64 fpcalc
	// release binary is dynamically linked, so on a base image without glibc
	// LookPath succeeds and then every one of 25,000 execs fails with "no such
	// file or directory" — a working feature gate that reads like a corrupt
	// library. One -version run catches absence and mis-linking with the same
	// check, and logs the Chromaprint build the fingerprints actually come from.
	// A nil deps.Fingerprinter IS the gate; no second boolean.
	vctx, vcancel := context.WithTimeout(ctx, 5*time.Second)
	if out, err := exec.CommandContext(vctx, cfg.FPCalcPath, "-version").Output(); err == nil {
		fp := fingerprint.New(cfg.FPCalcPath, cfg.MusicDir, deps.FP, cfg.AcoustIDKey)
		fp.Notify = func(status any) { deps.Events.Publish("fingerprint", status) }
		fp.Busy = sc.Busy
		deps.Fingerprinter = fp
		log.Printf("fingerprinting enabled: %s (%s)", cfg.FPCalcPath, strings.TrimSpace(string(out)))
		// Deliberately nothing logged when ACOUSTID_KEY is empty: that is the
		// normal state (no key ships), and a line on every boot would be noise
		// about a feature the user never asked for.
	}
	vcancel()

	if err := deps.Profiles.EnsureDefault(ctx); err != nil {
		log.Fatalf("profiles: %v", err)
	}

	// migration 007 moved album identity from tag strings to disk layout.
	// Recompute the ids from the columns they derive from and carry tags, edits,
	// enrichment, matches and art over to them — pure DB work, no library
	// re-parse, so this does not hold /healthz down while an NFS mount is walked.
	//
	// The sentinel is bumped whenever the GROUPING RULE changes, not only by a
	// schema migration: the ids are a pure function of stored columns, so
	// re-running this is how a rule change reaches a library that will otherwise
	// never re-parse the unchanged files it applies to. "012" is discSegRE
	// learning the MusicBrainz medium formats ("Digital Media 01"), which folds
	// multi-disc sets that had been one album per disc.
	if v, _ := deps.Settings.Get(ctx, "albumIdRemap"); v != "012" {
		if err := upgradeAlbumIDs(ctx, sqlDB, deps.Albums); err != nil {
			log.Printf("album identity upgrade: %v", err)
		} else if err := remapAlbumIDs(ctx, sqlDB, cfg.DataDir); err != nil {
			log.Printf("album id remap: %v", err)
		} else if err := deps.Settings.Set(ctx, "albumIdRemap", "012"); err != nil {
			log.Printf("album id remap flag: %v", err)
		}
	}

	// One-shot re-match. Neither release lookup asked MusicBrainz for
	// artist-credits, so rel.ArtistCredit was always empty and the matcher's
	// artist distance scored a constant maximum on every candidate of every
	// album. Both the stored distances and the verdicts drawn from them were
	// therefore decided without the artist signal entirely; nothing short of
	// re-deciding picks it up, because a decision is only revisited when the
	// album's trackSig moves and no file has changed.
	//
	// Pinned rows are the user's explicit choice of release and survive. `edits`
	// is untouched too: "use my own tags" is a user `local` living there, not in
	// match_decisions, so those albums keep their override while still
	// re-deciding underneath it.
	if v, _ := deps.Settings.Get(ctx, "artistCreditRematch"); v != "1" {
		if n, err := clearUnpinnedDecisions(ctx, sqlDB); err != nil {
			log.Printf("artist-credit re-match: %v", err)
		} else if err := deps.Settings.Set(ctx, "artistCreditRematch", "1"); err != nil {
			log.Printf("artist-credit re-match flag: %v", err)
		} else {
			log.Printf("artist-credit re-match: %d decisions cleared", n)
		}
	}

	if n, err := deps.Tracks.Count(ctx); err != nil {
		log.Fatalf("tracks: %v", err)
	} else if n == 0 && deps.Scanner != nil {
		log.Printf("empty library, scanning %s ...", cfg.MusicDir)
		if n, err := deps.Scanner.Scan(ctx); err != nil {
			log.Printf("initial scan: %v", err)
		} else {
			log.Printf("scanned %d tracks", n)
		}
	}

	// legacy kickEnrich() at boot: resume/refresh enrichment on every start,
	// not only after POST /api/scan. Signal ctx stops it between items. Kicked at
	// boot because the alternative is that a server upgraded in place never
	// analyses anything — nothing else calls it unless the user happens to
	// rescan. "Hours of decoding on every restart" is not the cost: with nothing
	// pending each pass is one query and an idle frame.
	deps.GoBg(deps.RunPasses)

	// Periodic rescan. Nothing else discovers a new album: the boot scan above
	// only fires on an EMPTY library, so before this a server that was never
	// manually rescanned would show a library frozen at first-run forever, and
	// files changed on disk kept analysis results measured from their old bytes.
	//
	// Two cadences, one goroutine, one select — which is also what serialises
	// them: a tick that arrives while the other cadence is mid-scan waits its
	// turn instead of colliding. (Scanner.Scan would refuse the overlap anyway,
	// but refusing it means silently skipping that cadence's turn.)
	//
	// ponytail: tickers, not a cron expression — "every day at 04:00" needs a
	// parser, a timezone and a UI to set it in, and this is a home-server rescan
	// whose exact minute nobody cares about. Ceiling: the daily pass lands at
	// boot-time + 24h, so a server restarted at 19:00 enriches at 19:00. If that
	// ever needs to be an off-peak hour, the upgrade is one time.Until to the
	// next 04:00 before the loop, not a cron dependency.
	if cfg.ScanInterval > 0 || cfg.FullScanInterval > 0 {
		log.Printf("periodic scan: every %s, with enrichment every %s",
			orNever(cfg.ScanInterval), orNever(cfg.FullScanInterval))
		deps.GoBg(func(ctx context.Context) {
			// A nil channel blocks forever in a select, which is how a zero
			// interval disables one cadence without branching the loop.
			var quick, full <-chan time.Time
			if cfg.ScanInterval > 0 {
				t := time.NewTicker(cfg.ScanInterval)
				defer t.Stop()
				quick = t.C
			}
			if cfg.FullScanInterval > 0 {
				t := time.NewTicker(cfg.FullScanInterval)
				defer t.Stop()
				full = t.C
			}
			for {
				select {
				case <-ctx.Done():
					return
				case <-quick:
					periodicScan(ctx, deps, false)
				case <-full:
					periodicScan(ctx, deps, true)
				}
			}
		})
	}

	srv := &http.Server{
		Addr: ":" + cfg.Port, Handler: api.New(deps),
		// no ReadTimeout/WriteTimeout: /api/events is a long-lived SSE stream
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	srv.RegisterOnShutdown(deps.Events.Close) // SSE streams must not block Shutdown
	go func() {
		log.Printf("aria-server on :%s, music=%s", cfg.Port, cfg.MusicDir)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("serve: %v", err)
		}
	}()

	<-ctx.Done()
	shutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
	deps.WaitBg() // background scan/enrich must finish before sqlDB.Close
}
