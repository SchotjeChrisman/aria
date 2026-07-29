package main

// One-shot upgrade glue for migration 007: re-key every track to the new
// directory-derived albumId, then move everything else keyed by albumId —
// tag_items, edits, enrich_cache and DATA_DIR/art/* — from the old id to the new
// one. Deleted in a year; a new internal/ package for one function is not worth
// it, and it must not live in Scanner.Scan, which owns tracks+albums and has no
// business writing edits or enrich_cache.

import (
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"log"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"sort"

	"aria/internal/repo"
	"aria/internal/scanner"
)

// upgradeAlbumIDs rewrites every track's albumId with the scanner's current
// grouping rule. That rule is a pure function of path, album and albumArtist —
// all stored columns — so migration 007 needs no re-parse of the library at
// all: boot is not blocked on an NFS walk, an interrupted upgrade loses
// nothing, and an unreadable file cannot cost a row. Idempotent.
func upgradeAlbumIDs(ctx context.Context, db *sql.DB, albums *repo.Albums) error {
	rows, err := db.QueryContext(ctx, `SELECT id, path, album, albumArtist, albumId, discNo FROM tracks`)
	if err != nil {
		return err
	}
	type upd struct {
		id, albumID string
		disc        *int
	}
	var todo []upd
	for rows.Next() {
		var id, path, album, albumArtist, albumID string
		var disc *int
		if err := rows.Scan(&id, &path, &album, &albumArtist, &albumID, &disc); err != nil {
			rows.Close()
			return err
		}
		newID, discFromDir := scanner.AlbumID(path, album, albumArtist)
		if disc == nil && discFromDir > 0 {
			disc = &discFromDir // untagged multi-disc set: the CD1/CD2 folder said it
		}
		if newID != albumID {
			todo = append(todo, upd{id, newID, disc})
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if len(todo) == 0 {
		return nil
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, u := range todo {
		if _, err := tx.ExecContext(ctx,
			`UPDATE tracks SET albumId = ?, discNo = ? WHERE id = ?`, u.albumID, u.disc, u.id); err != nil {
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	log.Printf("album identity upgrade: re-keyed %d tracks", len(todo))
	return albums.Rebuild(ctx) // albums is derived from tracks.albumId
}

// mapRow is one old->new album id edge plus how many tracks moved along it.
// Both ids come off the same tracks row, so the map is exact by construction —
// nothing about the grouping rule is reimplemented in SQL.
type mapRow struct {
	old, new string
	tracks   int
}

type pair struct{ old, new string }

// remapPlan is the pure decision layer. Several olds mapping to one new is a
// merge (a compilation that had split); one old mapping to several news is a
// split (two concerts that had merged). Both can apply to the same id.
type remapPlan struct {
	pairs     []pair              // every edge: tag union + edits copy
	editSrc   map[string][]string // new id -> old ids in winner order (first writer wins)
	cacheMove []pair              // 1:1 only — keeps the pinned MBID, avoids a refetch
	oldIDs    []string            // every old id, sorted; rows deleted after the copies
}

// planRemap classifies the edges. Deterministic: every output slice is sorted,
// never in map-iteration order.
func planRemap(rows []mapRow) remapPlan {
	p := remapPlan{editSrc: map[string][]string{}}
	byNew := map[string][]mapRow{}
	byOld := map[string]int{}
	var clean []mapRow
	for _, r := range rows {
		if r.old == "" || r.new == "" || r.old == r.new {
			continue // already remapped, or never had a legacy id
		}
		clean = append(clean, r)
		byNew[r.new] = append(byNew[r.new], r)
		byOld[r.old]++
	}
	if len(clean) == 0 {
		return remapPlan{}
	}
	seenOld := map[string]bool{}
	for _, r := range clean {
		p.pairs = append(p.pairs, pair{r.old, r.new})
		// merge/split old ids get no cacheMove entry and so are only deleted:
		// copying an album cache row across a split would propagate one concert's
		// MBID to both folders, and a merged compilation's cached MBID belonged to
		// a quarter of the album. Both must be re-identified.
		if len(byNew[r.new]) == 1 && byOld[r.old] == 1 {
			p.cacheMove = append(p.cacheMove, pair{r.old, r.new})
		}
		if !seenOld[r.old] {
			seenOld[r.old] = true
			p.oldIDs = append(p.oldIDs, r.old)
		}
	}
	for newID, srcs := range byNew {
		// most tracks wins a field collision, old id breaks the tie — never file order
		sort.Slice(srcs, func(i, j int) bool {
			if srcs[i].tracks != srcs[j].tracks {
				return srcs[i].tracks > srcs[j].tracks
			}
			return srcs[i].old < srcs[j].old
		})
		ids := make([]string, len(srcs))
		for i, s := range srcs {
			ids[i] = s.old
		}
		p.editSrc[newID] = ids
	}
	sort.Slice(p.pairs, func(i, j int) bool {
		if p.pairs[i].old != p.pairs[j].old {
			return p.pairs[i].old < p.pairs[j].old
		}
		return p.pairs[i].new < p.pairs[j].new
	})
	sort.Slice(p.cacheMove, func(i, j int) bool { return p.cacheMove[i].old < p.cacheMove[j].old })
	sort.Strings(p.oldIDs)
	return p
}

// remapAlbumIDs runs the plan against the DB and the art directory. Every step
// is skip-if-already-done, so a crash anywhere leaves the caller's flag unset
// and the whole thing re-runs cleanly on the next boot.
func remapAlbumIDs(ctx context.Context, db *sql.DB, dataDir string) error {
	rows, err := db.QueryContext(ctx, `SELECT legacyAlbumId, albumId, COUNT(*) FROM tracks
		WHERE legacyAlbumId <> '' AND legacyAlbumId <> albumId GROUP BY 1, 2`)
	if err != nil {
		return err
	}
	var mrs []mapRow
	for rows.Next() {
		var m mapRow
		if err := rows.Scan(&m.old, &m.new, &m.tracks); err != nil {
			rows.Close()
			return err
		}
		mrs = append(mrs, m)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	p := planRemap(mrs)
	if len(p.pairs) == 0 {
		return nil
	}

	oldJSON, err := json.Marshal(p.oldIDs)
	if err != nil {
		return err
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	// tag_items: union is unambiguously correct in both directions — a merged
	// album inherits every tag its parts had, both halves of a split keep it.
	var tagRows int64
	for _, pr := range p.pairs {
		res, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO tag_items (tagId, kind, key)
			SELECT tagId, 'album', ? FROM tag_items WHERE kind = 'album' AND key = ?`, pr.new, pr.old)
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		tagRows += n
	}
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM tag_items WHERE kind = 'album' AND key IN (SELECT value FROM json_each(?))`,
		string(oldJSON)); err != nil {
		return err
	}

	// edits: a plain UPDATE SET key=? throws UNIQUE on a merge and INSERT OR
	// IGNORE picks an arbitrary winner, so the sources are merged explicitly,
	// key by key, first writer wins. artSource/artVersion ride along in the blob,
	// which is what keeps a user's uploaded cover addressable.
	var editRows int
	for newID, srcs := range p.editSrc {
		merged := map[string]any{}
		// the new id first, so an edit the user already made against it survives.
		// POST /api/scan re-derives albumIds without remapping, so a user whose
		// upgrade scan failed can legitimately have re-typed a blurb under the new
		// id before this ever runs — INSERT OR REPLACE would then bury it.
		for _, old := range append([]string{newID}, srcs...) {
			var doc string
			err := tx.QueryRowContext(ctx, `SELECT json FROM edits WHERE kind = 'album' AND key = ?`, old).Scan(&doc)
			if err == sql.ErrNoRows {
				continue
			}
			if err != nil {
				return err
			}
			var m map[string]any
			if json.Unmarshal([]byte(doc), &m) != nil {
				continue
			}
			for k, v := range m {
				if _, ok := merged[k]; !ok {
					merged[k] = v
				}
			}
		}
		if len(merged) == 0 {
			continue
		}
		blob, err := json.Marshal(merged)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT OR REPLACE INTO edits (kind, key, json) VALUES ('album', ?, ?)`, newID, string(blob)); err != nil {
			return err
		}
		editRows++
	}
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM edits WHERE kind = 'album' AND key IN (SELECT value FROM json_each(?))`,
		string(oldJSON)); err != nil {
		return err
	}

	// enrich_cache: 1:1 moves (the overwhelming majority, so the full-library
	// re-enrichment is avoided); merges and splits are dropped, never copied.
	var cacheRows int64
	for _, pr := range p.cacheMove {
		res, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO enrich_cache (kind, key, json, fetchedAt)
			SELECT kind, ?, json, fetchedAt FROM enrich_cache WHERE kind IN ('album','albumInfo') AND key = ?`,
			pr.new, pr.old)
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		cacheRows += n
	}
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM enrich_cache WHERE kind IN ('album','albumInfo') AND key IN (SELECT value FROM json_each(?))`,
		string(oldJSON)); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}

	// art files, after the commit — copy, never move: copy is the only thing
	// correct for a split, is idempotent, and leaves the old file as the undo.
	// .custom.jpg is the unrecoverable one (served with no fallback, and
	// artSource:"file" is refused without embedded art), .api.jpg saves a
	// refetch, and the bare .jpg is the embedded cover the scanner extracted once.
	artDir := filepath.Join(dataDir, "art")
	gained := map[string]bool{}
	var artFiles int
	// editSrc order, not pair order: the merged album's artSource=custom pointer
	// comes from the winner there, so its cover file has to come from the same
	// old id or the album gets pinned to a cover the user never chose.
	for _, newID := range slices.Sorted(maps.Keys(p.editSrc)) {
		for _, old := range p.editSrc[newID] {
			for _, suffix := range []string{"", ".jpg", ".api.jpg", ".custom.jpg"} {
				dst := filepath.Join(artDir, newID+suffix)
				if _, err := os.Stat(dst); err == nil {
					gained[newID] = true // may be a copy from a run that crashed before the hasArt update
					continue
				}
				src := filepath.Join(artDir, old+suffix)
				if _, err := os.Stat(src); err != nil {
					continue
				}
				if err := copyFile(src, dst); err != nil {
					log.Printf("album id remap: art %s: %v", dst, err)
					continue
				}
				artFiles++
				gained[newID] = true
			}
		}
	}

	// the scan read art/ before these copies existed, so albums whose art is
	// only in the .api/.custom slot came out with hasArt=0
	if len(gained) > 0 {
		ids := make([]string, 0, len(gained))
		for id := range gained {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		idJSON, err := json.Marshal(ids)
		if err != nil {
			return err
		}
		if _, err := db.ExecContext(ctx,
			`UPDATE tracks SET hasArt = 1 WHERE albumId IN (SELECT value FROM json_each(?))`,
			string(idJSON)); err != nil {
			return err
		}
	}

	// every albumId consumer is string-keyed with no FK and no compile-time link
	// to the scanner: an incomplete remap builds, runs, and just returns nothing.
	// This line is the only thing that will ever tell you.
	log.Printf("album id remap: %d mappings (%d 1:1, %d re-identify), %d tag items, %d edits, %d cache rows, %d art files",
		len(p.pairs), len(p.cacheMove), len(p.oldIDs)-len(p.cacheMove), tagRows, editRows, cacheRows, artFiles)
	return nil
}

// copyFile byte-copies src to dst. Not os.Link: a split gives two new ids one
// old cover, and a shared inode would make POST /api/art for one of them
// silently rewrite the other's — and the old file kept as the undo.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
