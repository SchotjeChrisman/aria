package api

import (
	"context"
	"database/sql"
	"sync"

	"aria/internal/config"
	"aria/internal/repo"
)

// Scanner runs a full library scan (concurrent, incremental). Scan returns the
// resulting track count. Status is JSON-shaped progress, e.g.
// {"scanning":bool,"done":int,"total":int}.
type Scanner interface {
	Scan(ctx context.Context) (int, error)
	Status() any
}

// Enricher mirrors enrich.js: Run is an incremental background pass, Status
// returns {"phase":string,"done":int,"total":int,"running":bool}.
type Enricher interface {
	Run(ctx context.Context) error
	Status() any
}

// Deps is everything route files need. Scanner/Enricher are wired in main.
type Deps struct {
	DB      *sql.DB
	Cfg     config.Config
	Version string

	Tracks      *repo.Tracks
	Albums      *repo.Albums
	Tags        *repo.Tags
	Playlists   *repo.Playlists
	Profiles    *repo.Profiles
	Plays       *repo.Plays
	Edits       *repo.Edits
	EnrichCache *repo.Enrich
	Settings    *repo.Settings
	Radio       *repo.Radio

	Scanner  Scanner
	Enricher Enricher
	Events   *Hub

	// Bg is the app-lifetime context (set in main); background scan/enrich
	// work derives from it so SIGTERM cancels it, and GoBg tracks it so main
	// can wait before closing the DB.
	Bg   context.Context
	bgWG sync.WaitGroup

	// cached merged /api/tracks view (built lazily by mergedTracks in
	// library.go; mutators call InvalidateTracks)
	tracksMu   sync.Mutex
	tracksGen  uint64 // bumped by InvalidateTracks; guards stale publishes
	tracksView []map[string]any
	tracksGz   []byte     // pre-gzipped JSON of the full view (same generation)
	buildMu    sync.Mutex // single-flight for buildMergedTracks
	gzMu       sync.Mutex // single-flight for the encode (must NOT nest inside buildMu)
}

// bgCtx returns the app-lifetime context (Background until main wires Bg).
func (d *Deps) bgCtx() context.Context {
	if d.Bg != nil {
		return d.Bg
	}
	return context.Background()
}

// GoBg runs f on the app-lifetime context, tracked so WaitBg can drain
// in-flight background work (scan-triggered enrich, POST /api/enrich) before
// the DB closes on shutdown.
func (d *Deps) GoBg(f func(context.Context)) {
	d.bgWG.Add(1)
	go func() {
		defer d.bgWG.Done()
		f(d.bgCtx())
	}()
}

// WaitBg blocks until all GoBg work has finished.
func (d *Deps) WaitBg() { d.bgWG.Wait() }

// InvalidateTracks drops the cached merged /api/tracks view. Every mutation
// that feeds the merge (scan/enrich done, edits, reidentify, tags) calls it;
// the next read rebuilds lazily.
func (d *Deps) InvalidateTracks() {
	d.tracksMu.Lock()
	d.tracksGen++
	d.tracksView = nil
	d.tracksGz = nil
	d.tracksMu.Unlock()
}

// NewDeps wires all repos and the SSE hub; Scanner/Enricher stay nil until
// the caller sets them.
func NewDeps(db *sql.DB, cfg config.Config, version string) *Deps {
	return &Deps{
		DB:      db,
		Cfg:     cfg,
		Version: version,

		Tracks:      repo.NewTracks(db),
		Albums:      repo.NewAlbums(db),
		Tags:        repo.NewTags(db),
		Playlists:   repo.NewPlaylists(db),
		Profiles:    repo.NewProfiles(db),
		Plays:       repo.NewPlays(db),
		Edits:       repo.NewEdits(db),
		EnrichCache: repo.NewEnrich(db),
		Settings:    repo.NewSettings(db),
		Radio:       repo.NewRadio(db),

		Events: NewHub(),
	}
}
