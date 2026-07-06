package repo

import (
	"context"
	"database/sql"
)

type TagItem struct {
	Kind string `json:"kind"` // track | album | artist
	Key  string `json:"key"`  // track id, albumId, or free-form artist name
}

type Tag struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Parent    *string   `json:"parent"`
	Items     []TagItem `json:"items"`
	CreatedAt string    `json:"createdAt"`
}

type Tags struct{ db *sql.DB }

func NewTags(db *sql.DB) *Tags { return &Tags{db} }

func (r *Tags) List(ctx context.Context) ([]Tag, error) {
	rows, err := r.db.QueryContext(ctx, `SELECT id, name, parent, createdAt FROM tags ORDER BY createdAt, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Tag
	idx := map[string]int{}
	for rows.Next() {
		var t Tag
		if err := rows.Scan(&t.ID, &t.Name, &t.Parent, &t.CreatedAt); err != nil {
			return nil, err
		}
		t.Items = []TagItem{} // JSON [] not null
		idx[t.ID] = len(out)
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	irows, err := r.db.QueryContext(ctx, `SELECT tagId, kind, key FROM tag_items ORDER BY rowid`)
	if err != nil {
		return nil, err
	}
	defer irows.Close()
	for irows.Next() {
		var tagID string
		var it TagItem
		if err := irows.Scan(&tagID, &it.Kind, &it.Key); err != nil {
			return nil, err
		}
		if i, ok := idx[tagID]; ok {
			out[i].Items = append(out[i].Items, it)
		}
	}
	return out, irows.Err()
}

// ByID returns nil, nil when the tag does not exist.
func (r *Tags) ByID(ctx context.Context, id string) (*Tag, error) {
	var t Tag
	err := r.db.QueryRowContext(ctx, `SELECT id, name, parent, createdAt FROM tags WHERE id = ?`, id).
		Scan(&t.ID, &t.Name, &t.Parent, &t.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	t.Items = []TagItem{}
	rows, err := r.db.QueryContext(ctx, `SELECT kind, key FROM tag_items WHERE tagId = ? ORDER BY rowid`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var it TagItem
		if err := rows.Scan(&it.Kind, &it.Key); err != nil {
			return nil, err
		}
		t.Items = append(t.Items, it)
	}
	return &t, rows.Err()
}

func (r *Tags) Create(ctx context.Context, t Tag) error {
	_, err := r.db.ExecContext(ctx, `INSERT INTO tags (id, name, parent, createdAt) VALUES (?,?,?,?)`,
		t.ID, t.Name, t.Parent, t.CreatedAt)
	return err
}

// Update sets name and parent (cycle checks belong to the API layer).
func (r *Tags) Update(ctx context.Context, id, name string, parent *string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE tags SET name = ?, parent = ? WHERE id = ?`, name, parent, id)
	return err
}

// Delete removes a tag, promoting its children to the deleted tag's parent.
func (r *Tags) Delete(ctx context.Context, id string) error {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx,
		`UPDATE tags SET parent = (SELECT parent FROM tags WHERE id = ?) WHERE parent = ?`, id, id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM tags WHERE id = ?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

func (r *Tags) AddItem(ctx context.Context, tagID, kind, key string) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO tag_items (tagId, kind, key) VALUES (?,?,?)`, tagID, kind, key)
	return err
}

func (r *Tags) RemoveItem(ctx context.Context, tagID, kind, key string) error {
	_, err := r.db.ExecContext(ctx,
		`DELETE FROM tag_items WHERE tagId = ? AND kind = ? AND key = ?`, tagID, kind, key)
	return err
}
