package repo

import (
	"context"
	"database/sql"
)

// Station is a user-added station; builtins live in the API layer.
type Station struct {
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	URL       string  `json:"url"`
	Genre     *string `json:"genre"`
	CreatedAt string  `json:"createdAt"`
}

type Radio struct{ db *sql.DB }

func NewRadio(db *sql.DB) *Radio { return &Radio{db} }

func (r *Radio) List(ctx context.Context) ([]Station, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT id, name, url, genre, createdAt FROM radio ORDER BY createdAt, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Station
	for rows.Next() {
		var s Station
		if err := rows.Scan(&s.ID, &s.Name, &s.URL, &s.Genre, &s.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (r *Radio) Create(ctx context.Context, s Station) error {
	_, err := r.db.ExecContext(ctx, `INSERT INTO radio (id, name, url, genre, createdAt) VALUES (?,?,?,?,?)`,
		s.ID, s.Name, s.URL, s.Genre, s.CreatedAt)
	return err
}

// Delete reports whether a row was removed (builtins are checked upstream).
func (r *Radio) Delete(ctx context.Context, id string) (bool, error) {
	res, err := r.db.ExecContext(ctx, `DELETE FROM radio WHERE id = ?`, id)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}
