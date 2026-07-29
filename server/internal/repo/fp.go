package repo

import (
	"context"
	"database/sql"
)

// PendingFP is one file still owed a fingerprint, carrying the freshness key so
// PutFP needs no second query.
type PendingFP struct {
	ID, Path    string
	Mtime, Size int64
}

// PendingLookup is one fingerprint still owed an AcoustID query. Duration is
// the full-track seconds AcoustID matches against with maxdurationdiff.
type PendingLookup struct {
	TrackID     string
	Fingerprint string
	Duration    int
}

type FP struct{ db *sql.DB }

func NewFP(db *sql.DB) *FP { return &FP{db} }

// ListPendingFP is the same three-way freshness test track_audio uses (no row /
// mtime moved / size moved), for the same reason: a fingerprint is a pure
// function of the bytes. ORDER BY path keeps one album's files consecutive on a
// spinning NAS.
func (r *FP) ListPendingFP(ctx context.Context) ([]PendingFP, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT t.id, t.path, t.mtime, t.size
		FROM tracks t LEFT JOIN track_fp f ON f.trackId = t.id
		WHERE f.trackId IS NULL OR f.mtime <> t.mtime OR f.size <> t.size
		ORDER BY t.path`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PendingFP
	for rows.Next() {
		var p PendingFP
		if err := rows.Scan(&p.ID, &p.Path, &p.Mtime, &p.Size); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// PutFP upserts the local half. The lookup columns are deliberately reset to
// NULL: if the bytes moved the fingerprint moved, so the old AcoustID answer
// describes a file that no longer exists and must be asked again.
func (r *FP) PutFP(ctx context.Context, trackID, fingerprint string, duration int, mtime, size int64, at string) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO track_fp (trackId, mtime, size, calculatedAt, fingerprint, duration)
		VALUES (?,?,?,?,?,?)
		ON CONFLICT(trackId) DO UPDATE SET
		  mtime=excluded.mtime, size=excluded.size, calculatedAt=excluded.calculatedAt,
		  fingerprint=excluded.fingerprint, duration=excluded.duration,
		  acoustId=NULL, score=NULL, recordings=NULL, lookedUpAt=NULL, lookupError=NULL`,
		trackID, mtime, size, at, fingerprint, duration)
	return err
}

// ListPendingLookup returns fingerprints never sent to AcoustID, newest work
// last. limit bounds one pass's network appetite; the next pass picks up the
// rest, so a 25k library is not one uninterruptible 14-minute burst.
//
// `lookedUpAt IS NULL` is the whole rule, which is what makes an ACOUSTID_KEY
// arriving later Just Work: rows written while the feature was dark are
// indistinguishable from rows never tried.
func (r *FP) ListPendingLookup(ctx context.Context, limit int) ([]PendingLookup, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT trackId, fingerprint, duration FROM track_fp
		WHERE lookedUpAt IS NULL AND fingerprint <> ''
		ORDER BY trackId LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PendingLookup
	for rows.Next() {
		var p PendingLookup
		if err := rows.Scan(&p.TrackID, &p.Fingerprint, &p.Duration); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// CountPendingLookup is ListPendingLookup's count, for the progress total. A
// separate query rather than loading every pending row up front: a 25k library
// is ~65 MB of fingerprint strings, and the pass consumes them ten at a time.
func (r *FP) CountPendingLookup(ctx context.Context) (int, error) {
	var n int
	err := r.db.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM track_fp WHERE lookedUpAt IS NULL AND fingerprint <> ''`).Scan(&n)
	return n, err
}

// Counts is the health view's two scalars: tracks fingerprinted, and of those
// how many AcoustID has actually answered for. Both from one scan, and neither
// pulls the ~2.6 KB fingerprint strings ListAll would.
func (r *FP) Counts(ctx context.Context) (fingerprinted, identified int, err error) {
	err = r.db.QueryRowContext(ctx, `
		SELECT COUNT(*), COUNT(acoustId) FROM track_fp WHERE fingerprint <> ''`).
		Scan(&fingerprinted, &identified)
	return
}

// PutLookup stores one track's AcoustID answer. A no-match is a successful
// lookup: acoustId/score/recordings stay NULL but lookedUpAt is set, so it is
// not asked again on every pass forever. lookupError is cleared — this row now
// has a real answer.
func (r *FP) PutLookup(ctx context.Context, trackID string, acoustID *string, score *float64, recordings *string, at string) error {
	_, err := r.db.ExecContext(ctx, `
		UPDATE track_fp SET acoustId=?, score=?, recordings=?, lookedUpAt=?, lookupError=NULL
		WHERE trackId=?`, acoustID, score, recordings, at, trackID)
	return err
}

// PutLookupError records why a lookup failed and deliberately leaves lookedUpAt
// NULL, so the row is retried on the next pass. The two are separate columns
// exactly so a failure can be both visible and transient: an invalid key or a
// 429 must not permanently mark 25,000 tracks as "looked up, no match".
func (r *FP) PutLookupError(ctx context.Context, trackID, msg string) error {
	_, err := r.db.ExecContext(ctx, `UPDATE track_fp SET lookupError=? WHERE trackId=?`, msg, trackID)
	return err
}
