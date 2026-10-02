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

// LocalArt is an image found in the library next to the music (see migration
// 012). Path is relative to MUSIC_DIR; Name is the album artist an artist
// image belongs to.
type LocalArt struct {
	Path  string
	Mtime int64
	Name  string
}

// LocalArts returns every row of one kind ("album" or "artist") by key.
func (r *Albums) LocalArts(ctx context.Context, kind string) (map[string]LocalArt, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT key, path, mtime, name FROM local_art WHERE kind = ?`, kind)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]LocalArt{}
	for rows.Next() {
		var k string
		var a LocalArt
		if err := rows.Scan(&k, &a.Path, &a.Mtime, &a.Name); err != nil {
			return nil, err
		}
		out[k] = a
	}
	return out, rows.Err()
}

// LocalArtOf returns one row; ok is false when the library has no image for key.
func (r *Albums) LocalArtOf(ctx context.Context, kind, key string) (a LocalArt, ok bool, err error) {
	err = r.db.QueryRowContext(ctx, `SELECT path, mtime, name FROM local_art WHERE kind = ? AND key = ?`, kind, key).
		Scan(&a.Path, &a.Mtime, &a.Name)
	if err == sql.ErrNoRows {
		return a, false, nil
	}
	return a, err == nil, err
}

// ReplaceLocalArt swaps every row of one kind for m in a single transaction.
func (r *Albums) ReplaceLocalArt(ctx context.Context, kind string, m map[string]LocalArt) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM local_art WHERE kind = ?`, kind); err != nil {
		return err
	}
	stmt, err := tx.PrepareContext(ctx, `INSERT INTO local_art (kind, key, path, mtime, name) VALUES (?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for k, a := range m {
		if _, err := stmt.ExecContext(ctx, kind, k, a.Path, a.Mtime, a.Name); err != nil {
			return err
		}
	}
	return tx.Commit()
}
