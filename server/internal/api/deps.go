package api

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"sync"

	"aria/internal/config"
	"aria/internal/repo"
)

// Scanner runs a full library scan (concurrent, incremental). Scan returns the
// resulting track count. Status is JSON-shaped progress, e.g.
// {"scanning":bool,"done":int,"total":int}. LastParsed is how many files the
// last scan re-read rather than skipped, which is how the periodic scan tells
// a quiet hour from one that needs the enrichment passes run. LastChanged
// additionally counts deletions, so the periodic scan can tell a tick that
// moved the library from one that did not.
type Scanner interface {
	Scan(ctx context.Context) (int, error)
	LastParsed() int
	LastChanged() bool
	Status() any
}

// Enricher mirrors enrich.js: Run is an incremental background pass, Status
// returns {"phase":string,"done":int,"total":int,"running":bool}.
type Enricher interface {
	Run(ctx context.Context) error
	Status() any
}

// Analyzer decodes audio for EBU R128 loudness and the real stream format.
// Same Run/Status contract as Enricher; nil when no ffmpeg was found at
// startup, which is the feature gate (501 from /api/analyze).
type Analyzer interface {
	Run(ctx context.Context) error
	Status() any
}

// Fingerprinter computes Chromaprint fingerprints and resolves them against
// AcoustID. Same Run/Status contract again; nil when fpcalc did not run at
// startup, which is the feature gate (501 from /api/fingerprint). Note this is
// gated on fpcalc, NOT on ffmpeg or on an AcoustID key: a deployment can have
// one binary and not the other, and a missing key only darkens the lookup half.
type Fingerprinter interface {
	Run(ctx context.Context) error
	Status() any
}

// Deps is everything route files need. Scanner/Enricher/Analyzer/Fingerprinter
// are wired in main.
type Deps struct {
	DB      *sql.DB
	Cfg     config.Config
	Version string

	// CanTranscode is set at startup when cfg.FFmpegPath resolves to an
	// executable; gates the high/low stream tiers (501 otherwise).
	CanTranscode bool

	Tracks      *repo.Tracks
	Albums      *repo.Albums
	Tags        *repo.Tags
	Playlists   *repo.Playlists
	ListenLater *repo.ListenLaters
	Profiles    *repo.Profiles
	Plays       *repo.Plays
	Edits       *repo.Edits
	EnrichCache *repo.Enrich
	Settings    *repo.Settings
	Radio       *repo.Radio
	Logs        *repo.Logs
	Audio       *repo.Audio
	FP          *repo.FP
	Matches     *repo.Matches

	Scanner       Scanner
	Enricher      Enricher
	Analyzer      Analyzer
	Fingerprinter Fingerprinter
	Events        *Hub

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

// RunPasses is the fingerprint -> enrich -> analyse chain that follows a scan,
// in that order and strictly sequentially. Three callers need it identically —
// boot, POST /api/scan and the periodic scan — and it was copy-pasted between
// the first two before the third made that untenable.
//
// The ORDER is load-bearing, not stylistic. Matching is a phase of the
// enricher, and its strongest candidate source is the release groups AcoustID
// voted for, which do not exist until fingerprinting has run. Behind the
// enricher, a fresh library decides every album on text search alone, and a
// `matched` decision is never revisited (retryAfter is empty for matched), so
// that first weak answer is permanent.
//
// Sequential is what guarantees no pass ever runs concurrently with itself, and
// keeps three disk-heavy jobs off each other and off the scanner. Each pass is
// incremental: with nothing pending, every one of them is a single query.
//
// Cancellation is not an error worth logging: SIGTERM cancels the shared bg
// context mid-pass by design, and every pass resumes from the DB next boot.
func (d *Deps) RunPasses(ctx context.Context) {
	if d.Fingerprinter != nil {
		if err := d.Fingerprinter.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("fingerprint: %v", err)
		}
		// Nothing it writes reaches /api/tracks, hence no invalidate.
	}
	if d.Enricher != nil {
		if err := d.Enricher.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("enrich: %v", err)
		}
		d.InvalidateTracks() // enrichment feeds credits/hasArt into the merge
	}
	if d.Analyzer != nil {
		if err := d.Analyzer.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("analyze: %v", err)
		}
		d.InvalidateTracks() // loudness feeds trackGainDb/albumGainDb
	}
}

// InvalidateTracks drops the cached merged /api/tracks view AND announces the
// new generation to every connected app. Every mutation that feeds the merge
// (scan/enrich done, edits, reidentify, tags) already calls it, which is
// exactly why the announcement belongs here and not at each call site: the
// server is where the library changes, so one signal from here is what keeps
// every client — not just the device that made the change — from sitting on a
// stale copy until someone presses Rescan on it.
//
// The frame carries the generation rather than a "something changed" flag so a
// client that MISSED one (asleep, offline, or a full hub buffer — the hub drops
// frames for slow subscribers) still notices on reconnect, where the stream
// opens with the current generation. A boolean would be lost with the frame.
func (d *Deps) InvalidateTracks() {
	gen := d.invalidateTracks()
	if d.Events != nil { // hand-built Deps in tests carry no hub
		d.Events.Publish("library", map[string]any{"gen": gen})
	}
}

// InvalidateTracksQuiet drops the cache WITHOUT announcing it. For changes the
// apps already apply themselves and that are not worth a whole-library refetch
// on every device — the favourite toggle, which is optimistic client-side
// precisely so a heart tap costs nothing. The generation still rises, so the
// next real announcement carries the favourite along with it.
func (d *Deps) InvalidateTracksQuiet() { d.invalidateTracks() }

// invalidateTracks does the cache drop and returns the new generation.
func (d *Deps) invalidateTracks() uint64 {
	d.tracksMu.Lock()
	defer d.tracksMu.Unlock()
	d.tracksGen++
	d.tracksView = nil
	d.tracksGz = nil
	return d.tracksGen
}

// TracksGen is the current merged-view generation, sent to every new SSE
// subscriber so a reconnecting app can tell whether it slept through a change.
func (d *Deps) TracksGen() uint64 {
	d.tracksMu.Lock()
	defer d.tracksMu.Unlock()
	return d.tracksGen
}

// NewDeps wires all repos and the SSE hub; Scanner/Enricher/Analyzer/
// Fingerprinter stay nil until the caller sets them.
func NewDeps(db *sql.DB, cfg config.Config, version string) *Deps {
	return &Deps{
		DB:      db,
		Cfg:     cfg,
		Version: version,

		Tracks:      repo.NewTracks(db),
		Albums:      repo.NewAlbums(db),
		Tags:        repo.NewTags(db),
		Playlists:   repo.NewPlaylists(db),
		ListenLater: repo.NewListenLaters(db),
		Profiles:    repo.NewProfiles(db),
		Plays:       repo.NewPlays(db),
		Edits:       repo.NewEdits(db),
		EnrichCache: repo.NewEnrich(db),
		Settings:    repo.NewSettings(db),
		Radio:       repo.NewRadio(db),
		Logs:        repo.NewLogs(db),
		Audio:       repo.NewAudio(db),
		FP:          repo.NewFP(db),
		Matches:     repo.NewMatches(db),

		Events: NewHub(),
	}
}
