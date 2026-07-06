package api

import (
	"context"
	"database/sql"

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
	Search      *repo.Search

	Scanner  Scanner
	Enricher Enricher
	Events   *Hub
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
		Search:      repo.NewSearch(db),

		Events: NewHub(),
	}
}
