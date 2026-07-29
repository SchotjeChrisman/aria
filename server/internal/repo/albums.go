package repo

import (
	"context"
	"database/sql"
)

type Album struct {
	AlbumID     string  `json:"albumId"`
	Album       string  `json:"album"`
	AlbumArtist string  `json:"albumArtist"`
	Year        *int    `json:"year"`
	Genre       *string `json:"genre"`
	TrackCount  int     `json:"trackCount"`
	Duration    float64 `json:"duration"`
	HasArt      bool    `json:"hasArt"`
}

type Albums struct{ db *sql.DB }

func NewAlbums(db *sql.DB) *Albums { return &Albums{db} }

// Rebuild re-derives the albums table from tracks; call after every scan.
func (r *Albums) Rebuild(ctx context.Context) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM albums`); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO albums
		(albumId, album, albumArtist, year, genre, trackCount, duration, hasArt)
		SELECT albumId, album, albumArtist, MAX(year), MAX(genre),
		       COUNT(*), COALESCE(SUM(duration), 0), MAX(hasArt)
		FROM tracks GROUP BY albumId`); err != nil {
		return err
	}
	return tx.Commit()
}
