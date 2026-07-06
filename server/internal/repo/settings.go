package repo

import (
	"context"
	"database/sql"
)

type Settings struct{ db *sql.DB }

func NewSettings(db *sql.DB) *Settings { return &Settings{db} }

// Get returns "" when the key is unset.
func (r *Settings) Get(ctx context.Context, key string) (string, error) {
	var v string
	err := r.db.QueryRowContext(ctx, `SELECT value FROM settings WHERE key = ?`, key).Scan(&v)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return v, err
}

func (r *Settings) Set(ctx context.Context, key, value string) error {
	_, err := r.db.ExecContext(ctx, `INSERT INTO settings (key, value) VALUES (?,?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
	return err
}

func (r *Settings) Delete(ctx context.Context, key string) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM settings WHERE key = ?`, key)
	return err
}

func (r *Settings) All(ctx context.Context) (map[string]string, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT key, value FROM settings`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			return nil, err
		}
		out[k] = v
	}
	return out, rows.Err()
}
