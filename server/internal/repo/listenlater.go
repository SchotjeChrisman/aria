package repo

import (
	"context"
	"database/sql"
	"encoding/json"
)

// ListenLater is one saved album the user does not own yet. ID is the
// universal identity ("rg:<mbid>" or "dz:<id>", see 006_listen_later.sql);
// Releases holds the MusicBrainz release MBIDs in the group, used to spot the
// album arriving in the library under any edition.
type ListenLater struct {
	ID        string          `json:"id"`
	ProfileID string          `json:"profileId"`
	Artist    string          `json:"artist"`
	Title     string          `json:"title"`
	TitleKey  string          `json:"titleKey"`
	UPC       *string         `json:"upc"`
	DeezerID  *int64          `json:"deezerId"`
	Cover     *string         `json:"cover"`
	Date      *string         `json:"date"`
	Type      string          `json:"type"`
	Releases  json.RawMessage `json:"releases,omitempty"`
	AddedAt   string          `json:"addedAt"`
}

type ListenLaters struct{ db *sql.DB }

func NewListenLaters(db *sql.DB) *ListenLaters { return &ListenLaters{db} }

const listenLaterCols = `id, profileId, artist, title, titleKey, upc, deezerId, cover, date, type, releases, addedAt`

func scanListenLater(scan func(...any) error) (ListenLater, error) {
	var e ListenLater
	var releases sql.NullString
	err := scan(&e.ID, &e.ProfileID, &e.Artist, &e.Title, &e.TitleKey, &e.UPC, &e.DeezerID,
		&e.Cover, &e.Date, &e.Type, &releases, &e.AddedAt)
	if releases.Valid {
		e.Releases = json.RawMessage(releases.String)
	}
	return e, err
}

// List returns one profile's entries, newest first.
func (r *ListenLaters) List(ctx context.Context, profileID string) ([]ListenLater, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT `+listenLaterCols+` FROM listen_later WHERE profileId = ? ORDER BY addedAt DESC, id`, profileID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ListenLater
	for rows.Next() {
		e, err := scanListenLater(rows.Scan)
		if err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// Add is idempotent: re-adding an album the user already saved refreshes its
// denormalized fields rather than erroring or duplicating.
//
// An album's id can legitimately change between saves: entries are keyed
// "dz:<deezer id>" until MusicBrainz ingests the record, then "rg:<mbid>" once
// the cache refreshes. The upsert alone can't see that — a new id is a new row
// — so first drop any earlier row for the same Deezer album.
func (r *ListenLaters) Add(ctx context.Context, e ListenLater) error {
	if e.DeezerID != nil {
		if _, err := r.db.ExecContext(ctx,
			`DELETE FROM listen_later WHERE profileId = ? AND deezerId = ? AND id <> ?`,
			e.ProfileID, *e.DeezerID, e.ID); err != nil {
			return err
		}
	}
	_, err := r.db.ExecContext(ctx, `INSERT INTO listen_later (`+listenLaterCols+`) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(profileId, id) DO UPDATE SET
			artist = excluded.artist, title = excluded.title, titleKey = excluded.titleKey,
			upc = excluded.upc, deezerId = excluded.deezerId, cover = excluded.cover,
			date = excluded.date, type = excluded.type, releases = excluded.releases`,
		e.ID, e.ProfileID, e.Artist, e.Title, e.TitleKey, e.UPC, e.DeezerID,
		e.Cover, e.Date, e.Type, nullRaw(e.Releases), e.AddedAt)
	return err
}

func (r *ListenLaters) Delete(ctx context.Context, profileID, id string) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM listen_later WHERE profileId = ? AND id = ?`, profileID, id)
	return err
}

// DeleteMany drops entries whose albums have arrived in the library.
func (r *ListenLaters) DeleteMany(ctx context.Context, profileID string, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, id := range ids {
		if _, err := tx.ExecContext(ctx, `DELETE FROM listen_later WHERE profileId = ? AND id = ?`, profileID, id); err != nil {
			return err
		}
	}
	return tx.Commit()
}
