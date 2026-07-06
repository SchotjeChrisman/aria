package repo

import (
	"context"
	"database/sql"
	"encoding/json"
)

// Edits stores metadata overrides as JSON blobs keyed by (kind, key):
// kind track|album|artist, key = track id | albumId | artist name.
type Edits struct{ db *sql.DB }

func NewEdits(db *sql.DB) *Edits { return &Edits{db} }

// Get returns nil when no edits exist for the key.
func (r *Edits) Get(ctx context.Context, kind, key string) (json.RawMessage, error) {
	var s string
	err := r.db.QueryRowContext(ctx, `SELECT json FROM edits WHERE kind = ? AND key = ?`, kind, key).Scan(&s)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return json.RawMessage(s), nil
}

func (r *Edits) Put(ctx context.Context, kind, key string, doc json.RawMessage) error {
	_, err := r.db.ExecContext(ctx, `INSERT INTO edits (kind, key, json) VALUES (?,?,?)
		ON CONFLICT(kind, key) DO UPDATE SET json = excluded.json`, kind, key, string(doc))
	return err
}

func (r *Edits) Delete(ctx context.Context, kind, key string) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM edits WHERE kind = ? AND key = ?`, kind, key)
	return err
}

// ListKind returns key -> json for every edit of one kind (overlay pass).
func (r *Edits) ListKind(ctx context.Context, kind string) (map[string]json.RawMessage, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT key, json FROM edits WHERE kind = ?`, kind)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]json.RawMessage{}
	for rows.Next() {
		var k, s string
		if err := rows.Scan(&k, &s); err != nil {
			return nil, err
		}
		out[k] = json.RawMessage(s)
	}
	return out, rows.Err()
}
