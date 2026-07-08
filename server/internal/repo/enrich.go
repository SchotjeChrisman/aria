package repo

import (
	"context"
	"database/sql"
	"encoding/json"
)

// Enrich is the enrichment cache. json may be the literal "null": a negative
// cache entry ("looked up, nothing found") — hence the found bool on Get.
type Enrich struct{ db *sql.DB }

func NewEnrich(db *sql.DB) *Enrich { return &Enrich{db} }

func (r *Enrich) Get(ctx context.Context, kind, key string) (json.RawMessage, bool, error) {
	var s string
	err := r.db.QueryRowContext(ctx, `SELECT json FROM enrich_cache WHERE kind = ? AND key = ?`, kind, key).Scan(&s)
	if err == sql.ErrNoRows {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return json.RawMessage(s), true, nil
}

// GetFetched is Get plus the fetchedAt timestamp, for TTL checks.
func (r *Enrich) GetFetched(ctx context.Context, kind, key string) (json.RawMessage, string, bool, error) {
	var s, at string
	err := r.db.QueryRowContext(ctx, `SELECT json, fetchedAt FROM enrich_cache WHERE kind = ? AND key = ?`, kind, key).Scan(&s, &at)
	if err == sql.ErrNoRows {
		return nil, "", false, nil
	}
	if err != nil {
		return nil, "", false, err
	}
	return json.RawMessage(s), at, true, nil
}

func (r *Enrich) Put(ctx context.Context, kind, key string, doc json.RawMessage, fetchedAt string) error {
	_, err := r.db.ExecContext(ctx, `INSERT INTO enrich_cache (kind, key, json, fetchedAt) VALUES (?,?,?,?)
		ON CONFLICT(kind, key) DO UPDATE SET json = excluded.json, fetchedAt = excluded.fetchedAt`,
		kind, key, string(doc), fetchedAt)
	return err
}

func (r *Enrich) Delete(ctx context.Context, kind, key string) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM enrich_cache WHERE kind = ? AND key = ?`, kind, key)
	return err
}

func (r *Enrich) ListKind(ctx context.Context, kind string) (map[string]json.RawMessage, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT key, json FROM enrich_cache WHERE kind = ?`, kind)
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

// Keys lists cached keys of one kind (enricher skip-list for incremental runs).
func (r *Enrich) Keys(ctx context.Context, kind string) ([]string, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT key FROM enrich_cache WHERE kind = ?`, kind)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}
