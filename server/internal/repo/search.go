package repo

import (
	"context"
	"database/sql"
	"strings"
)

// Search queries tracks_fts (title, artist, albumArtist, album, composer).
type Search struct{ db *sql.DB }

func NewSearch(db *sql.DB) *Search { return &Search{db} }

// Tracks returns ids of matching tracks, best first. The raw query is turned
// into quoted prefix tokens so FTS5 operator syntax can't leak in.
func (s *Search) Tracks(ctx context.Context, query string, limit int) ([]string, error) {
	match := ftsQuery(query)
	if match == "" {
		return []string{}, nil
	}
	rows, err := s.db.QueryContext(ctx, `SELECT t.id FROM tracks_fts f
		JOIN tracks t ON t.rowid = f.rowid
		WHERE tracks_fts MATCH ? ORDER BY rank LIMIT ?`, match, limit)
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

// ftsQuery: `bee gees` -> `"bee"* "gees"*` (implicit AND, prefix match).
func ftsQuery(q string) string {
	var toks []string
	for _, f := range strings.Fields(q) {
		f = strings.ReplaceAll(f, `"`, "")
		if f != "" {
			toks = append(toks, `"`+f+`"*`)
		}
	}
	return strings.Join(toks, " ")
}
