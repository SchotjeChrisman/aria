package main

import (
	"context"
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
	// enrichment and art over to them — pure DB work, no library re-parse, so
	// this does not hold /healthz down while an NFS mount is walked.
	if v, _ := deps.Settings.Get(ctx, "albumIdRemap"); v != "007" {
		if err := upgradeAlbumIDs(ctx, sqlDB, deps.Albums); err != nil {
			log.Printf("album identity upgrade: %v", err)
		} else if err := remapAlbumIDs(ctx, sqlDB, cfg.DataDir); err != nil {
			log.Printf("album id remap: %v", err)
		} else if err := deps.Settings.Set(ctx, "albumIdRemap", "007"); err != nil {
			log.Printf("album id remap flag: %v", err)
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
	// not only after POST /api/scan. Signal ctx stops it between items.
	//
	// The analysis pass is chained after it in the same GoBg, exactly as
	// POST /api/scan does: sequential is what keeps the analyzer off the disk
	// while the quick network-bound enrichment runs, and off itself. Kicked at
	// boot too, because the alternative is that a server upgraded in place
	// never analyses anything — nothing else calls it unless the user happens
	// to rescan. "Hours of decoding on every restart" is not the cost:
	// ListPending is empty once the library is analysed, so every later start
	// is one query and an idle frame.
	deps.GoBg(func(ctx context.Context) {
		// Fingerprinting leads, for the reason POST /api/scan does the same: the
		// enricher's matching phase scores candidates against the release groups
		// AcoustID voted for, and a `matched` decision is never re-decided. An
		// enricher that runs first on a fresh library locks in a text-search
		// answer permanently. Same resume-on-boot argument as the others — with
		// nothing pending it is one query and an idle frame.
		if deps.Fingerprinter != nil {
			if err := deps.Fingerprinter.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
				log.Printf("fingerprint: %v", err)
			}
		}
		if err := deps.Enricher.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("enrich: %v", err)
		}
		deps.InvalidateTracks() // enrichment feeds credits/hasArt into /api/tracks
		if deps.Analyzer != nil {
			if err := deps.Analyzer.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
				log.Printf("analyze: %v", err)
			}
			deps.InvalidateTracks() // loudness feeds trackGainDb/albumGainDb
		}
	})

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
