package db

import "testing"

func TestOpenMigratesAndIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	for i := 0; i < 2; i++ { // second Open must skip applied migrations
		d, err := Open(dir)
		if err != nil {
			t.Fatalf("open #%d: %v", i+1, err)
		}
		var n int
		if err := d.QueryRow(`SELECT COUNT(*) FROM schema_migrations`).Scan(&n); err != nil {
			t.Fatalf("schema_migrations: %v", err)
		}
		if n == 0 {
			t.Fatal("no migrations recorded")
		}
		for _, table := range []string{"tracks", "albums", "tags", "tag_items", "playlists",
			"playlist_tracks", "plays", "profiles", "edits", "enrich_cache", "settings", "radio"} {
			var name string
			if err := d.QueryRow(`SELECT name FROM sqlite_master WHERE name = ?`, table).Scan(&name); err != nil {
				t.Errorf("missing table %s: %v", table, err)
			}
		}
		// 002_drop_fts removed the dead search index and its triggers
		var fts int
		if err := d.QueryRow(`SELECT COUNT(*) FROM sqlite_master
			WHERE name IN ('tracks_fts', 'tracks_ai', 'tracks_ad', 'tracks_au')`).Scan(&fts); err != nil || fts != 0 {
			t.Errorf("fts leftovers = %d, %v; want 0", fts, err)
		}
		// 007 carries the pre-directory albumId for the one-shot boot remap
		var legacy int
		if err := d.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('tracks')
			WHERE name = 'legacyAlbumId'`).Scan(&legacy); err != nil || legacy != 1 {
			t.Errorf("tracks.legacyAlbumId = %d, %v; want 1", legacy, err)
		}
		var mode string
		if err := d.QueryRow(`PRAGMA journal_mode`).Scan(&mode); err != nil || mode != "wal" {
			t.Errorf("journal_mode = %q, %v; want wal", mode, err)
		}
		var fk int
		if err := d.QueryRow(`PRAGMA foreign_keys`).Scan(&fk); err != nil || fk != 1 {
			t.Errorf("foreign_keys = %d, %v; want 1", fk, err)
		}
		d.Close()
	}
}
