package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"aria/internal/db"
	"aria/internal/repo"
	"aria/internal/scanner"
)

// id builds a plausible 40-hex album id from a short label.
func id(label string) string {
	return label + strings.Repeat("0", 40-len(label))
}

// The merge/split rules, which decide what is safe to carry over and what has
// to be re-identified. Nothing here touches the database.
func TestPlanRemap(t *testing.T) {
	oneToOne := []mapRow{{id("a"), id("b"), 5}}
	merge := []mapRow{{id("m1"), id("n"), 4}, {id("m2"), id("n"), 9}}
	split := []mapRow{{id("s"), id("t1"), 2}, {id("s"), id("t2"), 3}}

	cases := []struct {
		name      string
		rows      []mapRow
		pairs     int
		cacheMove []pair
		editSrc   map[string][]string
	}{
		// 1:1 keeps the pinned MBID and avoids a full re-enrichment
		{name: "1:1", rows: oneToOne, pairs: 1,
			cacheMove: []pair{{id("a"), id("b")}},
			editSrc:   map[string][]string{id("b"): {id("a")}}},
		// merge: most tracks wins a field collision, cache is re-identified (no
		// cacheMove entry, so the blanket delete is all that happens to it)
		{name: "N to 1", rows: merge, pairs: 2,
			editSrc: map[string][]string{id("n"): {id("m2"), id("m1")}}},
		// split: copying the cache would propagate one concert's MBID to both
		{name: "1 to M", rows: split, pairs: 2,
			editSrc: map[string][]string{id("t1"): {id("s")}, id("t2"): {id("s")}}},
		{name: "both directions", rows: append(append([]mapRow{}, merge...), mapRow{id("m1"), id("u"), 1}), pairs: 3,
			editSrc: map[string][]string{
				id("n"): {id("m2"), id("m1")}, id("u"): {id("m1")}}},
		{name: "empty", rows: nil},
		// a crash mid-remap must re-run cleanly, so already-mapped rows are inert
		{name: "already remapped", rows: []mapRow{{id("a"), id("a"), 3}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := planRemap(tc.rows)
			if len(p.pairs) != tc.pairs {
				t.Errorf("pairs = %d, want %d", len(p.pairs), tc.pairs)
			}
			if !reflect.DeepEqual(p.cacheMove, tc.cacheMove) {
				t.Errorf("cacheMove = %v, want %v", p.cacheMove, tc.cacheMove)
			}
			if tc.editSrc != nil && !reflect.DeepEqual(p.editSrc, tc.editSrc) {
				t.Errorf("editSrc = %v, want %v", p.editSrc, tc.editSrc)
			}
			// the winner of an edits collision must never come from map order
			for i := 0; i < 20; i++ {
				if again := planRemap(tc.rows); !reflect.DeepEqual(again, p) {
					t.Fatalf("planRemap is not deterministic: %v vs %v", again, p)
				}
			}
		})
	}
}

func mustExec(t *testing.T, d *sql.DB, q string, args ...any) {
	t.Helper()
	if _, err := d.Exec(q, args...); err != nil {
		t.Fatalf("%s: %v", q, err)
	}
}

func seedTrack(t *testing.T, d *sql.DB, name, legacy, album string) {
	t.Helper()
	mustExec(t, d, `INSERT INTO tracks (id, path, addedAt, title, artist, albumArtist, album, albumId, legacyAlbumId)
		VALUES (?,?,'2026-01-01','T','A','A','Al',?,?)`, name, name+".flac", album, legacy)
}

func editOf(t *testing.T, d *sql.DB, key string) map[string]any {
	t.Helper()
	var doc string
	err := d.QueryRow(`SELECT json FROM edits WHERE kind='album' AND key=?`, key).Scan(&doc)
	if err == sql.ErrNoRows {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(doc), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

// Everything keyed by albumId has to follow the id: tags, edits (including the
// art slot pointer), the enrichment cache and the art files themselves.
func TestRemapAlbumIDs(t *testing.T) {
	dataDir := t.TempDir()
	d, err := db.Open(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	ctx := context.Background()
	artDir := filepath.Join(dataDir, "art")
	if err := os.MkdirAll(artDir, 0o755); err != nil {
		t.Fatal(err)
	}

	m1, m2, n := id("m1"), id("m2"), id("n") // merge: two old ids into one
	s, t1, t2 := id("s"), id("t1"), id("t2") // split: one old id into two
	o, o2 := id("o"), id("o2")               // 1:1

	seedTrack(t, d, "m1a", m1, n)
	seedTrack(t, d, "m1b", m1, n)
	seedTrack(t, d, "m2a", m2, n)
	seedTrack(t, d, "sa", s, t1)
	seedTrack(t, d, "sb", s, t2)
	seedTrack(t, d, "oa", o, o2)

	mustExec(t, d, `INSERT INTO tags (id, name, createdAt) VALUES ('tag','Favourites','2026-01-01')`)
	for _, key := range []string{m1, m2, s} {
		mustExec(t, d, `INSERT INTO tag_items (tagId, kind, key) VALUES ('tag','album',?)`, key)
	}
	mustExec(t, d, `INSERT INTO edits (kind, key, json) VALUES ('album',?,?)`, m1,
		`{"blurb":"from m1","artSource":"custom","artVersion":3}`)
	mustExec(t, d, `INSERT INTO edits (kind, key, json) VALUES ('album',?,?)`, m2, `{"blurb":"from m2","label":"L"}`)
	mustExec(t, d, `INSERT INTO edits (kind, key, json) VALUES ('album',?,?)`, s, `{"blurb":"from s"}`)
	for _, key := range []string{m1, s, o} {
		mustExec(t, d, `INSERT INTO enrich_cache (kind, key, json, fetchedAt) VALUES ('album',?,'{"art":true}','2026-01-01')`, key)
		mustExec(t, d, `INSERT INTO enrich_cache (kind, key, json, fetchedAt) VALUES ('albumInfo',?,'{"label":"X"}','2026-01-01')`, key)
	}
	for _, name := range []string{m1 + ".custom.jpg", m1 + ".api.jpg", s + ".custom.jpg"} {
		if err := os.WriteFile(filepath.Join(artDir, name), []byte("jpg"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, key := range []string{m1, m2, s, o} {
		mustExec(t, d, `INSERT INTO match_decisions (albumId, state, reason, decidedAt, attempts)
			VALUES (?, 'matched', 'test', '2026-01-01', 1)`, key)
	}

	if err := remapAlbumIDs(ctx, d, dataDir); err != nil {
		t.Fatalf("remap: %v", err)
	}

	// tags: the merged album inherits its parts', both halves of the split keep theirs
	for _, tc := range []struct {
		key  string
		want int
	}{{n, 1}, {t1, 1}, {t2, 1}, {m1, 0}, {m2, 0}, {s, 0}} {
		var got int
		if err := d.QueryRow(`SELECT COUNT(*) FROM tag_items WHERE kind='album' AND key=?`, tc.key).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if got != tc.want {
			t.Errorf("tag_items for %s = %d, want %d", tc.key, got, tc.want)
		}
	}

	// edits: merged first-writer-wins by track count desc; m1 has 2 tracks to m2's 1
	merged := editOf(t, d, n)
	for k, want := range map[string]any{"blurb": "from m1", "label": "L", "artSource": "custom", "artVersion": 3.0} {
		if merged[k] != want {
			t.Errorf("edits[%s] on merged album = %v, want %v", k, merged[k], want)
		}
	}
	for _, key := range []string{t1, t2} {
		if got := editOf(t, d, key); got["blurb"] != "from s" {
			t.Errorf("edits blurb on %s = %v, want %q", key, got["blurb"], "from s")
		}
	}
	for _, key := range []string{m1, m2, s} {
		if got := editOf(t, d, key); got != nil {
			t.Errorf("edits for old id %s survived: %v", key, got)
		}
	}

	// enrich_cache: 1:1 moves (MBID kept), merge and split are re-identified
	for _, tc := range []struct {
		key  string
		want int
	}{{o2, 2}, {o, 0}, {n, 0}, {t1, 0}, {t2, 0}, {m1, 0}, {s, 0}} {
		var got int
		if err := d.QueryRow(`SELECT COUNT(*) FROM enrich_cache WHERE kind IN ('album','albumInfo') AND key=?`,
			tc.key).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if got != tc.want {
			t.Errorf("enrich_cache for %s = %d rows, want %d", tc.key, got, tc.want)
		}
	}

	// match_decisions: same 1:1-or-drop rule as enrich_cache, and stricter about
	// why. A merged album's stored trackSig was computed over one disc's tracks,
	// so a carried-over decision would claim to describe a set it has never seen.
	for _, tc := range []struct {
		key  string
		want int
	}{{o2, 1}, {o, 0}, {n, 0}, {t1, 0}, {t2, 0}, {m1, 0}, {m2, 0}, {s, 0}} {
		var got int
		if err := d.QueryRow(`SELECT COUNT(*) FROM match_decisions WHERE albumId=?`, tc.key).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if got != tc.want {
			t.Errorf("match_decisions for %s = %d rows, want %d", tc.key, got, tc.want)
		}
	}

	// legacyAlbumId is consumed, not left lying around: it is what a LATER
	// grouping-rule change re-stamps, and a leftover value would point that pass
	// at a generation whose rows this one already moved and deleted.
	var stale int
	if err := d.QueryRow(`SELECT COUNT(*) FROM tracks WHERE legacyAlbumId <> ''`).Scan(&stale); err != nil {
		t.Fatal(err)
	}
	if stale != 0 {
		t.Errorf("%d tracks still carry legacyAlbumId, want it cleared", stale)
	}

	// art: the custom slot is served with no fallback, so a stranded upload is a
	// permanent 404 with no in-app recovery. Copied, never moved.
	for _, name := range []string{n + ".custom.jpg", n + ".api.jpg", t1 + ".custom.jpg", t2 + ".custom.jpg",
		m1 + ".custom.jpg", s + ".custom.jpg"} {
		if _, err := os.Stat(filepath.Join(artDir, name)); err != nil {
			t.Errorf("art/%s: %v", name, err)
		}
	}
	// a split gives two albums one cover: independent files, or uploading art for
	// one silently replaces the other's and the old-id undo copy as well
	if err := os.WriteFile(filepath.Join(artDir, t1+".custom.jpg"), []byte("new cover for t1"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{t2 + ".custom.jpg", s + ".custom.jpg"} {
		if b, err := os.ReadFile(filepath.Join(artDir, name)); err != nil || string(b) != "jpg" {
			t.Errorf("art/%s = %q (%v), want the original bytes — the copies share an inode", name, b, err)
		}
	}
	// the scan read art/ before those copies existed, so hasArt needs correcting
	var hasArt int
	if err := d.QueryRow(`SELECT MIN(hasArt) FROM tracks WHERE albumId=?`, n).Scan(&hasArt); err != nil {
		t.Fatal(err)
	}
	if hasArt != 1 {
		t.Errorf("hasArt for merged album = %d, want 1", hasArt)
	}

	// a crash between the remap and the settings flag re-runs the whole thing
	if err := remapAlbumIDs(ctx, d, dataDir); err != nil {
		t.Fatalf("second remap: %v", err)
	}
	if got := editOf(t, d, n); got["blurb"] != "from m1" {
		t.Errorf("edits blurb after re-run = %v, want %q", got["blurb"], "from m1")
	}
}

// Collision policy on a merge: the cover file and the artSource pointer that
// selects it have to come from the same old album, an edit already made against
// the new id survives, and a run that crashed after the art copies still ends up
// with hasArt set.
func TestRemapMergeCollisions(t *testing.T) {
	dataDir := t.TempDir()
	d, err := db.Open(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	ctx := context.Background()
	artDir := filepath.Join(dataDir, "art")
	if err := os.MkdirAll(artDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// z wins on track count, a wins lexicographically: the two orders disagree
	z, a, w := id("z"), id("a"), id("w")
	o, o2 := id("o"), id("o2")
	seedTrack(t, d, "z1", z, w)
	seedTrack(t, d, "z2", z, w)
	seedTrack(t, d, "z3", z, w)
	seedTrack(t, d, "a1", a, w)
	seedTrack(t, d, "o1", o, o2)

	mustExec(t, d, `INSERT INTO edits (kind, key, json) VALUES ('album',?,?)`, z, `{"artSource":"custom"}`)
	// POST /api/scan re-derives albumIds but never remaps, so the user can
	// legitimately have re-entered this under the new id before the remap runs
	mustExec(t, d, `INSERT INTO edits (kind, key, json) VALUES ('album',?,?)`, w, `{"blurb":"user retyped this"}`)
	for name, body := range map[string]string{
		z + ".custom.jpg": "USER-PICKED", a + ".custom.jpg": "STALE",
		o2 + ".api.jpg": "already copied by a run that crashed",
	} {
		if err := os.WriteFile(filepath.Join(artDir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if err := remapAlbumIDs(ctx, d, dataDir); err != nil {
		t.Fatalf("remap: %v", err)
	}

	if b, err := os.ReadFile(filepath.Join(artDir, w+".custom.jpg")); err != nil || string(b) != "USER-PICKED" {
		t.Errorf("merged custom cover = %q (%v), want the one artSource=custom points at", b, err)
	}
	merged := editOf(t, d, w)
	if merged["blurb"] != "user retyped this" {
		t.Errorf("edits blurb on the new id = %v, want the user's own value", merged["blurb"])
	}
	if merged["artSource"] != "custom" {
		t.Errorf("edits artSource = %v, want custom", merged["artSource"])
	}
	var hasArt int
	if err := d.QueryRow(`SELECT MIN(hasArt) FROM tracks WHERE albumId=?`, o2).Scan(&hasArt); err != nil {
		t.Fatal(err)
	}
	if hasArt != 1 {
		t.Errorf("hasArt for an album whose art was copied by an earlier crashed run = %d, want 1", hasArt)
	}
}

// The 007 upgrade re-keys albums from stored columns alone — no re-parse, so no
// boot-blocking scan, nothing to lose on a restart, and no row can go missing
// because one file happened to be unreadable.
func TestUpgradeAlbumIDs(t *testing.T) {
	dataDir := t.TempDir()
	d, err := db.Open(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	ctx := context.Background()
	albums := repo.NewAlbums(d)

	// two folders, tagged identically: the tag hash merged them, disk layout must not
	mustExec(t, d, `INSERT INTO tracks (id, path, addedAt, title, artist, albumArtist, album, albumId, legacyAlbumId, discNo)
		VALUES ('t1','Knopfler/Amsterdam/01.flac','x','T','MK','MK','Tour',?,?,NULL)`, id("old"), id("old"))
	mustExec(t, d, `INSERT INTO tracks (id, path, addedAt, title, artist, albumArtist, album, albumId, legacyAlbumId, discNo)
		VALUES ('t2','Knopfler/Madrid/01.flac','x','T','MK','MK','Tour',?,?,NULL)`, id("old"), id("old"))
	// a disc subfolder recovers its disc number without reading the file
	mustExec(t, d, `INSERT INTO tracks (id, path, addedAt, title, artist, albumArtist, album, albumId, legacyAlbumId, discNo)
		VALUES ('t3','Box/CD2/01.flac','x','T','A','A','Set',?,?,NULL)`, id("old2"), id("old2"))

	if err := upgradeAlbumIDs(ctx, d, albums); err != nil {
		t.Fatalf("upgrade: %v", err)
	}
	get := func(id string) (albumID string, disc *int) {
		if err := d.QueryRow(`SELECT albumId, discNo FROM tracks WHERE id=?`, id).Scan(&albumID, &disc); err != nil {
			t.Fatal(err)
		}
		return
	}
	a1, _ := get("t1")
	a2, _ := get("t2")
	if a1 == a2 {
		t.Errorf("two concert folders share albumId %s, want two albums", a1)
	}
	want, _ := scanner.AlbumID("Knopfler/Amsterdam/01.flac", "Tour", "MK")
	if a1 != want {
		t.Errorf("albumId = %s, want the scanner's own %s", a1, want)
	}
	if _, disc := get("t3"); disc == nil || *disc != 2 {
		t.Errorf("discNo from the CD2 folder = %v, want 2", disc)
	}
	// albums is derived from tracks and has to follow
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM albums`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 3 {
		t.Errorf("albums rows = %d, want 3", n)
	}
	// idempotent: the boot path runs it on every start until the flag is set
	if err := upgradeAlbumIDs(ctx, d, albums); err != nil {
		t.Fatalf("second upgrade: %v", err)
	}
	if again, _ := get("t1"); again != a1 {
		t.Errorf("albumId changed on the second run: %s -> %s", a1, again)
	}

	// legacyAlbumId points at the id being REPLACED, not at whatever migration
	// 007 first wrote there. This is what lets the grouping rule change a second
	// time: the remap reads legacyAlbumId to find where tags, edits, enrichment
	// and art are filed, and after one re-key that is the id this pass just
	// overwrote — not the tag-hash generation, whose rows are long deleted.
	var legacy string
	if err := d.QueryRow(`SELECT legacyAlbumId FROM tracks WHERE id='t1'`).Scan(&legacy); err != nil {
		t.Fatal(err)
	}
	if legacy != id("old") {
		t.Errorf("legacyAlbumId = %s, want the replaced id %s", legacy, id("old"))
	}

	// ... and a re-key of an ALREADY-remapped library re-stamps it again. Faked
	// here by moving the file, which is the only input the rule reads — the real
	// trigger is discSegRE learning a new disc-folder spelling.
	mustExec(t, d, `UPDATE tracks SET legacyAlbumId = '' WHERE id='t1'`) // as the remap leaves it
	mustExec(t, d, `UPDATE tracks SET path = 'Knopfler/Amsterdam 2/01.flac' WHERE id='t1'`)
	if err := upgradeAlbumIDs(ctx, d, albums); err != nil {
		t.Fatalf("third upgrade: %v", err)
	}
	if err := d.QueryRow(`SELECT legacyAlbumId FROM tracks WHERE id='t1'`).Scan(&legacy); err != nil {
		t.Fatal(err)
	}
	if legacy != a1 {
		t.Errorf("second re-key stamped legacyAlbumId = %s, want the id it replaced %s", legacy, a1)
	}
}
