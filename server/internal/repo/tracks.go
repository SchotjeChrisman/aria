// Package repo holds plain database/sql data access, one file per aggregate.
// Repos are dumb: overlay-merging of edits/enrichment happens in the API layer.
package repo

import (
	"context"
	"database/sql"
	"encoding/json"
)

type Track struct {
	ID              string   `json:"id"`
	Path            string   `json:"path"` // relative to MUSIC_DIR; stripped by /api/tracks
	Mtime           int64    `json:"-"`
	Size            int64    `json:"-"`
	AddedAt         string   `json:"addedAt"`
	Title           string   `json:"title"`
	Artist          string   `json:"artist"`
	AlbumArtist     string   `json:"albumArtist"`
	Album           string   `json:"album"`
	AlbumID         string   `json:"albumId"`
	TrackNo         *int     `json:"trackNo"`
	DiscNo          *int     `json:"discNo"`
	Year            *int     `json:"year"`
	Genre           *string  `json:"genre"`
	Composer        *string  `json:"composer"`
	Conductor       *string  `json:"conductor"`
	Work            *string  `json:"work"`
	Movement        *string  `json:"movement"`
	MBAlbumID       *string  `json:"mbAlbumId"`
	MBRecordingID   *string  `json:"mbRecordingId"`
	MBAlbumArtistID *string  `json:"mbAlbumArtistId"`
	Duration        *float64 `json:"duration"`
	Format          string   `json:"format"`
	SampleRate      *int     `json:"sampleRate"`
	BitsPerSample   *int     `json:"bitsPerSample"`
	Channels        *int     `json:"channels"`
	Lossless        bool     `json:"lossless"`
	HasArt          bool     `json:"hasArt"`
	Favourite       bool     `json:"favourite"`
}

const trackCols = `id, path, mtime, size, addedAt, title, artist, albumArtist, album, albumId,
	trackNo, discNo, year, genre, composer, conductor, work, movement,
	mbAlbumId, mbRecordingId, mbAlbumArtistId,
	duration, format, sampleRate, bitsPerSample, channels, lossless, hasArt`

// Reads also pull the user favourite flag; it stays out of trackCols so the
// scanner's UpsertAll (which never sets it) leaves it intact across rescans.
const trackSelectCols = trackCols + `, favourite`

type Tracks struct{ db *sql.DB }

func NewTracks(db *sql.DB) *Tracks { return &Tracks{db} }

// UpsertAll writes all tracks in one transaction. Existing rows keep their
// addedAt (legacy carry-forward across rescans); everything else is replaced.
func (r *Tracks) UpsertAll(ctx context.Context, ts []Track) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	stmt, err := tx.PrepareContext(ctx, `INSERT INTO tracks (`+trackCols+`)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(id) DO UPDATE SET
			path=excluded.path, mtime=excluded.mtime, size=excluded.size,
			title=excluded.title, artist=excluded.artist, albumArtist=excluded.albumArtist,
			album=excluded.album, albumId=excluded.albumId,
			trackNo=excluded.trackNo, discNo=excluded.discNo, year=excluded.year,
			genre=excluded.genre, composer=excluded.composer, conductor=excluded.conductor,
			work=excluded.work, movement=excluded.movement,
			mbAlbumId=excluded.mbAlbumId, mbRecordingId=excluded.mbRecordingId,
			mbAlbumArtistId=excluded.mbAlbumArtistId,
			duration=excluded.duration, format=excluded.format,
			sampleRate=excluded.sampleRate, bitsPerSample=excluded.bitsPerSample,
			channels=excluded.channels, lossless=excluded.lossless, hasArt=excluded.hasArt`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, t := range ts {
		if _, err := stmt.ExecContext(ctx,
			t.ID, t.Path, t.Mtime, t.Size, t.AddedAt, t.Title, t.Artist, t.AlbumArtist, t.Album, t.AlbumID,
			t.TrackNo, t.DiscNo, t.Year, t.Genre, t.Composer, t.Conductor, t.Work, t.Movement,
			t.MBAlbumID, t.MBRecordingID, t.MBAlbumArtistID,
			t.Duration, t.Format, t.SampleRate, t.BitsPerSample, t.Channels, t.Lossless, t.HasArt,
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// DeleteNotIn removes tracks whose id is not in keep (files gone from disk).
// Returns the number of rows deleted.
func (r *Tracks) DeleteNotIn(ctx context.Context, keep []string) (int64, error) {
	ids, err := json.Marshal(keep)
	if err != nil {
		return 0, err
	}
	res, err := r.db.ExecContext(ctx,
		`DELETE FROM tracks WHERE id NOT IN (SELECT value FROM json_each(?))`, string(ids))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func (r *Tracks) ListAll(ctx context.Context) ([]Track, error) {
	return r.query(ctx, `SELECT `+trackSelectCols+` FROM tracks ORDER BY path`)
}

func (r *Tracks) Paged(ctx context.Context, limit, offset int) ([]Track, error) {
	return r.query(ctx, `SELECT `+trackSelectCols+` FROM tracks ORDER BY path LIMIT ? OFFSET ?`, limit, offset)
}

func (r *Tracks) ByAlbum(ctx context.Context, albumID string) ([]Track, error) {
	return r.query(ctx, `SELECT `+trackSelectCols+` FROM tracks WHERE albumId = ? ORDER BY discNo, trackNo, path`, albumID)
}

// SetFavourite flips the independent favourite flag on one track.
func (r *Tracks) SetFavourite(ctx context.Context, id string, fav bool) error {
	_, err := r.db.ExecContext(ctx, `UPDATE tracks SET favourite=? WHERE id=?`, fav, id)
	return err
}

// ByID returns nil, nil when the track does not exist.
func (r *Tracks) ByID(ctx context.Context, id string) (*Track, error) {
	ts, err := r.query(ctx, `SELECT `+trackSelectCols+` FROM tracks WHERE id = ?`, id)
	if err != nil || len(ts) == 0 {
		return nil, err
	}
	return &ts[0], nil
}

func (r *Tracks) Count(ctx context.Context) (int, error) {
	var n int
	err := r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM tracks`).Scan(&n)
	return n, err
}

// PathInfo is what the incremental scanner needs to decide skip vs re-parse.
type PathInfo struct {
	ID, Path, AddedAt string
	Mtime, Size       int64
}

func (r *Tracks) ListPathInfo(ctx context.Context) ([]PathInfo, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT id, path, addedAt, mtime, size FROM tracks`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PathInfo
	for rows.Next() {
		var p PathInfo
		if err := rows.Scan(&p.ID, &p.Path, &p.AddedAt, &p.Mtime, &p.Size); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (r *Tracks) query(ctx context.Context, q string, args ...any) ([]Track, error) {
	rows, err := r.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Track
	for rows.Next() {
		var t Track
		if err := rows.Scan(
			&t.ID, &t.Path, &t.Mtime, &t.Size, &t.AddedAt, &t.Title, &t.Artist, &t.AlbumArtist, &t.Album, &t.AlbumID,
			&t.TrackNo, &t.DiscNo, &t.Year, &t.Genre, &t.Composer, &t.Conductor, &t.Work, &t.Movement,
			&t.MBAlbumID, &t.MBRecordingID, &t.MBAlbumArtistID,
			&t.Duration, &t.Format, &t.SampleRate, &t.BitsPerSample, &t.Channels, &t.Lossless, &t.HasArt,
			&t.Favourite,
		); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
