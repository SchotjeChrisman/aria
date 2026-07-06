package repo

import (
	"context"
	"database/sql"
	"time"
)

type Profile struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Color     string `json:"color"`
	CreatedAt string `json:"createdAt"`
}

type Profiles struct{ db *sql.DB }

func NewProfiles(db *sql.DB) *Profiles { return &Profiles{db} }

// EnsureDefault seeds the legacy default profile when the table is empty.
func (r *Profiles) EnsureDefault(ctx context.Context) error {
	var n int
	if err := r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM profiles`).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return nil
	}
	return r.Create(ctx, Profile{
		ID: "default", Name: "Listener", Color: "#6d3fd2",
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
	})
}

func (r *Profiles) List(ctx context.Context) ([]Profile, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT id, name, color, createdAt FROM profiles ORDER BY createdAt, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Profile
	for rows.Next() {
		var p Profile
		if err := rows.Scan(&p.ID, &p.Name, &p.Color, &p.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ByID returns nil, nil when the profile does not exist.
func (r *Profiles) ByID(ctx context.Context, id string) (*Profile, error) {
	var p Profile
	err := r.db.QueryRowContext(ctx, `SELECT id, name, color, createdAt FROM profiles WHERE id = ?`, id).
		Scan(&p.ID, &p.Name, &p.Color, &p.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &p, nil
}

func (r *Profiles) Create(ctx context.Context, p Profile) error {
	_, err := r.db.ExecContext(ctx, `INSERT INTO profiles (id, name, color, createdAt) VALUES (?,?,?,?)`,
		p.ID, p.Name, p.Color, p.CreatedAt)
	return err
}

func (r *Profiles) Update(ctx context.Context, p Profile) error {
	_, err := r.db.ExecContext(ctx, `UPDATE profiles SET name = ?, color = ? WHERE id = ?`, p.Name, p.Color, p.ID)
	return err
}

// Delete cascades to playlists (and their tracks) and plays via FKs.
func (r *Profiles) Delete(ctx context.Context, id string) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM profiles WHERE id = ?`, id)
	return err
}

func (r *Profiles) Count(ctx context.Context) (int, error) {
	var n int
	err := r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM profiles`).Scan(&n)
	return n, err
}
