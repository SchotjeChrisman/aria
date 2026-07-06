// Command migrate-json is a one-shot importer of the legacy Node server's
// DATA_DIR JSON stores (index.json, profiles.json, plays.json, playlists.json,
// tags.json, edits.json, enrich.json, settings.json, radio.json) into
// DATA_DIR/aria.db. Idempotent: INSERT OR IGNORE keyed rows, plays deduped on
// (trackId, profileId, at); re-runs import only what's missing.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"aria/internal/config"
	"aria/internal/db"
	"aria/internal/repo"
)

type track struct {
	ID              string   `json:"id"`
	Path            string   `json:"path"`
	AddedAt         string   `json:"addedAt"`
	Title           string   `json:"title"`
	Artist          string   `json:"artist"`
	AlbumArtist     string   `json:"albumArtist"`
	Album           string   `json:"album"`
	AlbumID         string   `json:"albumId"`
	TrackNo         *int     `json:"trackNo"`
	DiscNo          *int     `json:"discNo"`
	Year            *int     `json:"year"`
	Genre           *string  `json:"genre"`
	Composer        *string  `json:"composer"`
	Conductor       *string  `json:"conductor"`
	Work            *string  `json:"work"`
	Movement        *string  `json:"movement"`
	MBAlbumID       *string  `json:"mbAlbumId"`
	MBRecordingID   *string  `json:"mbRecordingId"`
	MBAlbumArtistID *string  `json:"mbAlbumArtistId"`
	Duration        *float64 `json:"duration"`
	Format          string   `json:"format"`
	SampleRate      *int     `json:"sampleRate"`
	BitsPerSample   *int     `json:"bitsPerSample"`
	Channels        *int     `json:"channels"`
	Lossless        bool     `json:"lossless"`
	HasArt          bool     `json:"hasArt"`
}

type playlist struct {
	ID        string          `json:"id"`
	ProfileID string          `json:"profileId"`
	Name      string          `json:"name"`
	Type      string          `json:"type"`
	Rules     json.RawMessage `json:"rules"`
	TrackIDs  []string        `json:"trackIds"`
	CreatedAt string          `json:"createdAt"`
	UpdatedAt string          `json:"updatedAt"`
}

type migrator struct {
	ctx context.Context
	tx  *sql.Tx
}

func (m *migrator) exec(query string, args ...any) int64 {
	res, err := m.tx.ExecContext(m.ctx, query, args...)
	if err != nil {
		log.Fatalf("%s: %v", query, err)
	}
	n, _ := res.RowsAffected()
	return n
}

// readJSON mirrors store.js readJson: missing or corrupt file -> false, skip.
func readJSON(dir, name string, v any) bool {
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return false
	}
	if err := json.Unmarshal(b, v); err != nil {
		log.Printf("corrupt %s, skipping: %v", name, err)
		return false
	}
	return true
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func main() {
	src := flag.String("data", "", "directory holding the legacy *.json files (default: DATA_DIR)")
	flag.Parse()
	cfg := config.FromEnv()
	dir := orDefault(*src, cfg.DataDir)

	sqlDB, err := db.Open(cfg.DataDir)
	if err != nil {
		log.Fatalf("db: %v", err)
	}
	defer sqlDB.Close()

	ctx := context.Background()
	tx, err := sqlDB.BeginTx(ctx, nil)
	if err != nil {
		log.Fatalf("begin: %v", err)
	}
	defer tx.Rollback()
	m := &migrator{ctx: ctx, tx: tx}

	now := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	counts := map[string]int64{}

	// profiles first: plays and playlists FK onto them.
	var profs struct {
		Profiles []struct{ ID, Name, Color, CreatedAt string } `json:"profiles"`
	}
	if readJSON(dir, "profiles.json", &profs) {
		for _, p := range profs.Profiles {
			if p.ID == "" {
				continue
			}
			counts["profiles"] += m.exec(`INSERT OR IGNORE INTO profiles (id, name, color, createdAt) VALUES (?, ?, ?, ?)`,
				p.ID, orDefault(p.Name, "Listener"), orDefault(p.Color, "#6d3fd2"), orDefault(p.CreatedAt, now))
		}
	}
	knownProfiles := map[string]bool{}
	rows, err := tx.QueryContext(ctx, `SELECT id FROM profiles`)
	if err != nil {
		log.Fatalf("profiles: %v", err)
	}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			log.Fatalf("profiles: %v", err)
		}
		knownProfiles[id] = true
	}
	if err := rows.Err(); err != nil {
		log.Fatalf("profiles: %v", err)
	}

	var index struct {
		Tracks []track `json:"tracks"`
	}
	if readJSON(dir, "index.json", &index) {
		for _, t := range index.Tracks {
			if t.ID == "" || t.Path == "" || t.AlbumID == "" {
				continue
			}
			// mtime/size unknown to the legacy index; 0 forces a re-parse on first rescan.
			counts["tracks"] += m.exec(`INSERT OR IGNORE INTO tracks
				(id, path, mtime, size, addedAt, title, artist, albumArtist, album, albumId,
				 trackNo, discNo, year, genre, composer, conductor, work, movement,
				 mbAlbumId, mbRecordingId, mbAlbumArtistId, duration, format,
				 sampleRate, bitsPerSample, channels, lossless, hasArt)
				VALUES (?, ?, 0, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				t.ID, t.Path, orDefault(t.AddedAt, now), orDefault(t.Title, t.Path),
				orDefault(t.Artist, "Unknown Artist"), orDefault(t.AlbumArtist, "Unknown Artist"),
				orDefault(t.Album, "Unknown Album"), t.AlbumID,
				t.TrackNo, t.DiscNo, t.Year, t.Genre, t.Composer, t.Conductor, t.Work, t.Movement,
				t.MBAlbumID, t.MBRecordingID, t.MBAlbumArtistID, t.Duration, t.Format,
				t.SampleRate, t.BitsPerSample, t.Channels, t.Lossless, t.HasArt)
		}
	}

	var tags struct {
		Tags []struct {
			ID        string                       `json:"id"`
			Name      string                       `json:"name"`
			Parent    *string                      `json:"parent"`
			CreatedAt string                       `json:"createdAt"`
			Items     []struct{ Kind, Key string } `json:"items"`
		} `json:"tags"`
	}
	if readJSON(dir, "tags.json", &tags) {
		knownTags := map[string]bool{}
		for _, t := range tags.Tags {
			if t.ID != "" && t.Name != "" {
				knownTags[t.ID] = true
			}
		}
		// two passes: parent is a self-FK and may point at a later array entry.
		for _, t := range tags.Tags {
			if !knownTags[t.ID] {
				continue
			}
			counts["tags"] += m.exec(`INSERT OR IGNORE INTO tags (id, name, parent, createdAt) VALUES (?, ?, NULL, ?)`,
				t.ID, t.Name, orDefault(t.CreatedAt, now))
		}
		for _, t := range tags.Tags {
			if !knownTags[t.ID] || t.Parent == nil || !knownTags[*t.Parent] {
				continue
			}
			m.exec(`UPDATE tags SET parent = ? WHERE id = ?`, *t.Parent, t.ID)
		}
		for _, t := range tags.Tags {
			if !knownTags[t.ID] {
				continue
			}
			for _, it := range t.Items {
				if it.Kind != "track" && it.Kind != "album" && it.Kind != "artist" {
					continue
				}
				if it.Key == "" {
					continue
				}
				counts["tag_items"] += m.exec(`INSERT OR IGNORE INTO tag_items (tagId, kind, key) VALUES (?, ?, ?)`,
					t.ID, it.Kind, it.Key)
			}
		}
	}

	var pls struct {
		Playlists []playlist `json:"playlists"`
	}
	if readJSON(dir, "playlists.json", &pls) {
		for _, p := range pls.Playlists {
			if p.ID == "" || p.Name == "" || !knownProfiles[p.ProfileID] {
				continue
			}
			if p.Type != "manual" && p.Type != "smart" {
				continue
			}
			var rules any // NULL for manual
			if p.Type == "smart" && len(p.Rules) > 0 && string(p.Rules) != "null" {
				rules = string(p.Rules)
			}
			counts["playlists"] += m.exec(`INSERT OR IGNORE INTO playlists
				(id, profileId, name, type, rules, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)`,
				p.ID, p.ProfileID, p.Name, p.Type, rules, orDefault(p.CreatedAt, now), orDefault(p.UpdatedAt, now))
			for i, tid := range p.TrackIDs {
				counts["playlist_tracks"] += m.exec(`INSERT OR IGNORE INTO playlist_tracks (playlistId, pos, trackId) VALUES (?, ?, ?)`,
					p.ID, i, tid)
			}
		}
	}

	var plays struct {
		Plays []struct{ TrackID, ProfileID, At string } `json:"plays"`
	}
	if readJSON(dir, "plays.json", &plays) {
		for _, p := range plays.Plays {
			if p.TrackID == "" || !knownProfiles[p.ProfileID] {
				continue
			}
			counts["plays"] += m.exec(`INSERT INTO plays (trackId, profileId, at)
				SELECT ?, ?, ? WHERE NOT EXISTS
				(SELECT 1 FROM plays WHERE trackId = ? AND profileId = ? AND at = ?)`,
				p.TrackID, p.ProfileID, p.At, p.TrackID, p.ProfileID, p.At)
		}
	}

	var edits struct {
		Tracks  map[string]json.RawMessage `json:"tracks"`
		Albums  map[string]json.RawMessage `json:"albums"`
		Artists map[string]json.RawMessage `json:"artists"`
	}
	if readJSON(dir, "edits.json", &edits) {
		for _, s := range []struct {
			kind string
			m    map[string]json.RawMessage
		}{{"track", edits.Tracks}, {"album", edits.Albums}, {"artist", edits.Artists}} {
			for key, doc := range s.m {
				counts["edits"] += m.exec(`INSERT OR IGNORE INTO edits (kind, key, json) VALUES (?, ?, ?)`,
					s.kind, key, string(doc))
			}
		}
	}

	var en struct {
		Albums    map[string]json.RawMessage `json:"albums"`
		Tracks    map[string]json.RawMessage `json:"tracks"`
		Artists   map[string]json.RawMessage `json:"artists"`
		Composers map[string]json.RawMessage `json:"composers"`
		LyricsV2  map[string]json.RawMessage `json:"lyricsV2"`  // -> kind "lyrics"
		AlbumInfo map[string]json.RawMessage `json:"albumInfo"` // -> kind "albumInfo"
	}
	if readJSON(dir, "enrich.json", &en) {
		for _, s := range []struct {
			kind string
			m    map[string]json.RawMessage
		}{{"album", en.Albums}, {"track", en.Tracks}, {"artist", en.Artists}, {"composer", en.Composers},
			{"lyrics", en.LyricsV2}, {"albumInfo", en.AlbumInfo}} {
			for key, doc := range s.m {
				// literal null survives: it's the legacy negative cache.
				counts["enrich"] += m.exec(`INSERT OR IGNORE INTO enrich_cache (kind, key, json, fetchedAt) VALUES (?, ?, ?, ?)`,
					s.kind, key, string(doc), now)
			}
		}
	}

	var settings map[string]any
	if readJSON(dir, "settings.json", &settings) {
		for key, v := range settings {
			val, ok := v.(string)
			if !ok {
				b, _ := json.Marshal(v)
				val = string(b)
			}
			counts["settings"] += m.exec(`INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)`, key, val)
		}
	}

	var radio struct {
		Stations []struct {
			ID        string  `json:"id"`
			Name      string  `json:"name"`
			URL       string  `json:"url"`
			Genre     *string `json:"genre"`
			CreatedAt string  `json:"createdAt"`
		} `json:"stations"`
	}
	if readJSON(dir, "radio.json", &radio) {
		for _, s := range radio.Stations {
			if s.ID == "" || s.Name == "" || s.URL == "" {
				continue
			}
			counts["radio"] += m.exec(`INSERT OR IGNORE INTO radio (id, name, url, genre, createdAt) VALUES (?, ?, ?, ?, ?)`,
				s.ID, s.Name, s.URL, s.Genre, orDefault(s.CreatedAt, now))
		}
	}

	if err := tx.Commit(); err != nil {
		log.Fatalf("commit: %v", err)
	}

	if err := repo.NewAlbums(sqlDB).Rebuild(ctx); err != nil {
		log.Fatalf("albums rebuild: %v", err)
	}
	var albums int64
	if err := sqlDB.QueryRowContext(ctx, `SELECT COUNT(*) FROM albums`).Scan(&albums); err != nil {
		log.Fatalf("albums count: %v", err)
	}

	fmt.Printf("imported from %s into %s:\n", dir, filepath.Join(cfg.DataDir, "aria.db"))
	for _, k := range []string{"tracks", "profiles", "plays", "playlists", "playlist_tracks", "tags", "tag_items", "edits", "enrich", "settings", "radio"} {
		fmt.Printf("  %-15s %d\n", k, counts[k])
	}
	fmt.Printf("  %-15s %d (rebuilt)\n", "albums", albums)
}
