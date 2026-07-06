package repo

import (
	"context"
	"database/sql"
	"encoding/json"
)

type Playlist struct {
	ID        string          `json:"id"`
	ProfileID string          `json:"profileId"`
	Name      string          `json:"name"`
	Type      string          `json:"type"`            // manual | smart
	Rules     json.RawMessage `json:"rules,omitempty"` // smart only
	CreatedAt string          `json:"createdAt"`
	UpdatedAt string          `json:"updatedAt"`
}

type Playlists struct{ db *sql.DB }

func NewPlaylists(db *sql.DB) *Playlists { return &Playlists{db} }

const playlistCols = `id, profileId, name, type, rules, createdAt, updatedAt`

// List returns all playlists, or only one profile's when profileID != "".
func (r *Playlists) List(ctx context.Context, profileID string) ([]Playlist, error) {
	q, args := `SELECT `+playlistCols+` FROM playlists ORDER BY createdAt, id`, []any{}
	if profileID != "" {
		q = `SELECT ` + playlistCols + ` FROM playlists WHERE profileId = ? ORDER BY createdAt, id`
		args = append(args, profileID)
	}
	rows, err := r.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Playlist
	for rows.Next() {
		p, err := scanPlaylist(rows.Scan)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ByID returns nil, nil when the playlist does not exist.
func (r *Playlists) ByID(ctx context.Context, id string) (*Playlist, error) {
	row := r.db.QueryRowContext(ctx, `SELECT `+playlistCols+` FROM playlists WHERE id = ?`, id)
	p, err := scanPlaylist(row.Scan)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &p, nil
}

func (r *Playlists) Create(ctx context.Context, p Playlist) error {
	_, err := r.db.ExecContext(ctx, `INSERT INTO playlists (`+playlistCols+`) VALUES (?,?,?,?,?,?,?)`,
		p.ID, p.ProfileID, p.Name, p.Type, nullRaw(p.Rules), p.CreatedAt, p.UpdatedAt)
	return err
}

// Update sets name, rules and updatedAt.
func (r *Playlists) Update(ctx context.Context, p Playlist) error {
	_, err := r.db.ExecContext(ctx, `UPDATE playlists SET name = ?, rules = ?, updatedAt = ? WHERE id = ?`,
		p.Name, nullRaw(p.Rules), p.UpdatedAt, p.ID)
	return err
}

func (r *Playlists) Delete(ctx context.Context, id string) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM playlists WHERE id = ?`, id)
	return err
}

// TrackIDs returns the ordered track ids of a manual playlist (duplicates kept).
func (r *Playlists) TrackIDs(ctx context.Context, playlistID string) ([]string, error) {
	rows, err := r.db.QueryContext(ctx,
		`SELECT trackId FROM playlist_tracks WHERE playlistId = ? ORDER BY pos`, playlistID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// AddTrack appends a track (duplicates allowed, legacy semantics).
func (r *Playlists) AddTrack(ctx context.Context, playlistID, trackID string) error {
	_, err := r.db.ExecContext(ctx, `INSERT INTO playlist_tracks (playlistId, pos, trackId)
		SELECT ?, COALESCE(MAX(pos), 0) + 1, ? FROM playlist_tracks WHERE playlistId = ?`,
		playlistID, trackID, playlistID)
	return err
}

// RemoveTrack removes all occurrences of trackID (legacy semantics).
func (r *Playlists) RemoveTrack(ctx context.Context, playlistID, trackID string) error {
	_, err := r.db.ExecContext(ctx,
		`DELETE FROM playlist_tracks WHERE playlistId = ? AND trackId = ?`, playlistID, trackID)
	return err
}

func scanPlaylist(scan func(...any) error) (Playlist, error) {
	var p Playlist
	var rules sql.NullString
	err := scan(&p.ID, &p.ProfileID, &p.Name, &p.Type, &rules, &p.CreatedAt, &p.UpdatedAt)
	if rules.Valid {
		p.Rules = json.RawMessage(rules.String)
	}
	return p, err
}

func nullRaw(r json.RawMessage) any {
	if len(r) == 0 {
		return nil
	}
	return string(r)
}
