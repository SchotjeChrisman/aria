package repo

import (
	"context"
	"database/sql"
	"strings"
)

// DupeGroup is one set of tracks sharing a content key: the decoded-audio MD5
// (byte-identical audio) or the AcoustID (the same recording, possibly at a
// different bitrate or from a different release). Key is opaque to the client
// and exists only so groups have a stable identity across refreshes.
type DupeGroup struct {
	Key      string   `json:"key"`
	TrackIDs []string `json:"trackIds"`
}

// dupeGroups runs a `SELECT key, group_concat(trackId) ... HAVING COUNT(*)>1`
// and splits the concatenation. group_concat is safe here for the reason it
// usually is not: track ids are sha1 hex, so the default ',' separator cannot
// appear inside one. The alternative — every duplicated row into Go and
// grouped there — is a full table read to find a handful of groups.
func dupeGroups(ctx context.Context, db *sql.DB, q string) ([]DupeGroup, error) {
	rows, err := db.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DupeGroup
	for rows.Next() {
		var key, ids string
		if err := rows.Scan(&key, &ids); err != nil {
			return nil, err
		}
		out = append(out, DupeGroup{Key: key, TrackIDs: strings.Split(ids, ",")})
	}
	return out, rows.Err()
}

// DuplicateMD5 groups tracks whose DECODED audio is byte-identical. This is the
// only exact answer available: it ignores tags, container and encoder entirely,
// so the same master ripped twice with different tags is one group, and a
// re-encode of it is not (see 009_audio_md5.sql).
//
// An empty string is excluded as well as NULL — that is the "ffmpeg produced no hash" marker
// and grouping on it would collapse every unhashable file into one enormous
// bogus group.
func (r *Audio) DuplicateMD5(ctx context.Context) ([]DupeGroup, error) {
	return dupeGroups(ctx, r.db, `
		SELECT audioMd5, group_concat(trackId)
		FROM track_audio
		WHERE audioMd5 IS NOT NULL AND audioMd5 <> ''
		GROUP BY audioMd5 HAVING COUNT(*) > 1
		ORDER BY COUNT(*) DESC, audioMd5`)
}

// DuplicateAcoustID groups tracks AcoustID resolved to the same recording:
// the near-identical case MD5 cannot see, where a FLAC and its 320k MP3 are
// the same performance through different encoders.
//
// Not every group is unwanted — one recording legitimately appears on an album
// and on a compilation — which is exactly why this presents rather than acts.
//
// Empty whenever ACOUSTID_KEY is unset, because acoustId is only ever written
// by a successful lookup. The feature being dark is indistinguishable from a
// library with no duplicates, which is the correct degradation.
func (r *FP) DuplicateAcoustID(ctx context.Context) ([]DupeGroup, error) {
	return dupeGroups(ctx, r.db, `
		SELECT acoustId, group_concat(trackId)
		FROM track_fp
		WHERE acoustId IS NOT NULL AND acoustId <> ''
		GROUP BY acoustId HAVING COUNT(*) > 1
		ORDER BY COUNT(*) DESC, acoustId`)
}
