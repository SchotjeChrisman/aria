package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"aria/internal/api"
	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/enrich"
	"aria/internal/scanner"
)

const version = "2.3.0"

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
	deps.Scanner = scanner.New(cfg.MusicDir, cfg.DataDir, deps.Tracks, deps.Albums, func(done, total int) {
		deps.Events.Publish("scan", map[string]int{"done": done, "total": total})
	})
	enr := enrich.New(ctx, deps.Tracks, deps.EnrichCache, cfg.DataDir)
	enr.Notify = func(status any) { deps.Events.Publish("enrich", status) }
	deps.Enricher = enr

	if err := deps.Profiles.EnsureDefault(ctx); err != nil {
		log.Fatalf("profiles: %v", err)
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
	deps.GoBg(func(ctx context.Context) {
		if err := deps.Enricher.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("enrich: %v", err)
		}
		deps.InvalidateTracks() // enrichment feeds credits/hasArt into /api/tracks
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
