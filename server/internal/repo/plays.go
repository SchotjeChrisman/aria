package repo

import (
	"context"
	"database/sql"
)

type Play struct {
	TrackID   string `json:"trackId"`
	ProfileID string `json:"profileId"`
	At        string `json:"at"`
}

type Plays struct{ db *sql.DB }

func NewPlays(db *sql.DB) *Plays { return &Plays{db} }

// Add is idempotent on the exact (trackId, profileId, at) triple: an offline
// client replays a queued play after a timeout the server may have already
// committed. `at` has millisecond precision, so two legitimate plays of the
// same track can only collide within the same millisecond — applying the
// dedupe universally (server-clock plays included) is fine.
func (r *Plays) Add(ctx context.Context, p Play) error {
	_, err := r.db.ExecContext(ctx, `INSERT INTO plays (trackId, profileId, at)
		SELECT ?,?,? WHERE NOT EXISTS
		(SELECT 1 FROM plays WHERE trackId = ? AND profileId = ? AND at = ?)`,
		p.TrackID, p.ProfileID, p.At, p.TrackID, p.ProfileID, p.At)
	return err
}

// Trim keeps only the newest keep rows (legacy 20000 cap).
func (r *Plays) Trim(ctx context.Context, keep int) error {
	_, err := r.db.ExecContext(ctx,
		`DELETE FROM plays WHERE id NOT IN (SELECT id FROM plays ORDER BY id DESC LIMIT ?)`, keep)
	return err
}

// List returns plays in insertion order; profileID == "" means all profiles.
func (r *Plays) List(ctx context.Context, profileID string) ([]Play, error) {
	q, args := `SELECT trackId, profileId, at FROM plays ORDER BY id`, []any{}
	if profileID != "" {
		q = `SELECT trackId, profileId, at FROM plays WHERE profileId = ? ORDER BY id`
		args = append(args, profileID)
	}
	rows, err := r.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Play
	for rows.Next() {
		var p Play
		if err := rows.Scan(&p.TrackID, &p.ProfileID, &p.At); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// CountsFor returns per-track play counts for one profile (smart playlists).
func (r *Plays) CountsFor(ctx context.Context, profileID string) (map[string]int, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT trackId, COUNT(*) FROM plays WHERE profileId = ? GROUP BY trackId`, profileID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var id string
		var n int
		if err := rows.Scan(&id, &n); err != nil {
			return nil, err
		}
		out[id] = n
	}
	return out, rows.Err()
}
