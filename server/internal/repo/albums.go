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

func (r *Albums) List(ctx context.Context) ([]Album, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT albumId, album, albumArtist, year, genre,
		trackCount, duration, hasArt FROM albums ORDER BY albumArtist, album`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Album
	for rows.Next() {
		var a Album
		if err := rows.Scan(&a.AlbumID, &a.Album, &a.AlbumArtist, &a.Year, &a.Genre,
			&a.TrackCount, &a.Duration, &a.HasArt); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// ByID returns nil, nil when the album does not exist.
func (r *Albums) ByID(ctx context.Context, albumID string) (*Album, error) {
	var a Album
	err := r.db.QueryRowContext(ctx, `SELECT albumId, album, albumArtist, year, genre,
		trackCount, duration, hasArt FROM albums WHERE albumId = ?`, albumID).
		Scan(&a.AlbumID, &a.Album, &a.AlbumArtist, &a.Year, &a.Genre, &a.TrackCount, &a.Duration, &a.HasArt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &a, nil
}
