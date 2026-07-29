package repo

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
)

// Decision is one row of match_decisions: what the matcher concluded about one
// album. Album/AlbumArtist are display-only, filled by the queries that join
// tracks; they are not stored.
type Decision struct {
	AlbumID          string          `json:"albumId"`
	Album            string          `json:"album,omitempty"`
	AlbumArtist      string          `json:"albumArtist,omitempty"`
	State            string          `json:"state"` // matched | review | local
	Reason           string          `json:"reason"`
	ReleaseMbid      *string         `json:"releaseMbid"`
	ReleaseGroupMbid *string         `json:"releaseGroupMbid"`
	Disambiguation   string          `json:"disambiguation"`
	Distance         *float64        `json:"distance"`
	Separation       *float64        `json:"separation"`
	Pinned           bool            `json:"pinned"`
	TrackSig         string          `json:"-"`
	Attempts         int             `json:"attempts"`
	DecidedAt        string          `json:"decidedAt"`
	RetryAfter       string          `json:"retryAfter"`
	Candidates       json.RawMessage `json:"candidates"`
}

// PendingAlbum is one album owed a decision, carrying everything matchAlbum
// needs that is not in the tracks rows: the freshness key it must store back
// and the attempt count the retry backoff doubles.
type PendingAlbum struct {
	AlbumID     string
	Album       string
	AlbumArtist string
	TrackSig    string
	Attempts    int
}

type Matches struct{ db *sql.DB }

func NewMatches(db *sql.DB) *Matches { return &Matches{db} }

// trackSigExpr is the album freshness key, in SQL so no Go pass over the
// library is needed. Shared by PendingAlbums and TrackSig so the batch and the
// interactive path can never disagree about whether an album moved.
const trackSigExpr = `COUNT(*) || ':' || COALESCE(SUM(size), 0)`

// albumsExpr groups tracks into the match unit. MIN() over album/albumArtist
// rather than any-value: albumId is derived from those strings, so within one
// group they are identical anyway and MIN is just how SQLite spells "the one".
const albumsExpr = `SELECT albumId, MIN(album) AS album, MIN(albumArtist) AS albumArtist,
	       MIN(path) AS path, ` + trackSigExpr + ` AS trackSig
	FROM tracks GROUP BY albumId`

// PendingAlbums is the entire skip discipline in one statement, the way
// Audio.ListPending is. An album is pending when it is not pinned, the user has
// not claimed it (locked, or state=local in the edits overlay), and either it
// has never been decided, its files moved, or its retry window elapsed.
//
// The edits join is why the Enricher needs no *repo.Edits of its own: "the user
// said don't touch this" is a property of the pending set, not a check the
// caller can forget. json_extract returns SQLite 1/0 for JSON true/false, so
// the COALESCE default of 0 covers both "no edits row" and "no locked field".
//
// ORDER BY path so one artist's albums decide consecutively — the same reason
// the scanner and the analyzer order by path.
func (r *Matches) PendingAlbums(ctx context.Context, nowISO string) ([]PendingAlbum, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT a.albumId, a.album, a.albumArtist, a.trackSig, COALESCE(m.attempts, 0)
		FROM (`+albumsExpr+`) a
		LEFT JOIN match_decisions m ON m.albumId = a.albumId
		LEFT JOIN edits e ON e.kind = 'album' AND e.key = a.albumId
		WHERE COALESCE(m.pinned, 0) = 0
		  AND COALESCE(json_extract(e.json, '$.locked'), 0) = 0
		  AND COALESCE(json_extract(e.json, '$.state'), '') <> 'local'
		  AND (m.albumId IS NULL
		       OR m.trackSig <> a.trackSig
		       OR (m.state <> 'matched' AND m.retryAfter <> '' AND m.retryAfter <= ?))
		ORDER BY a.path`, nowISO)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PendingAlbum
	for rows.Next() {
		var p PendingAlbum
		if err := rows.Scan(&p.AlbumID, &p.Album, &p.AlbumArtist, &p.TrackSig, &p.Attempts); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// TrackSig computes one album's freshness key, for the interactive re-match
// route which has no PendingAlbums row to carry it. "" when the album has no
// tracks.
func (r *Matches) TrackSig(ctx context.Context, albumID string) (string, error) {
	var sig string
	err := r.db.QueryRowContext(ctx,
		`SELECT `+trackSigExpr+` FROM tracks WHERE albumId = ?`, albumID).Scan(&sig)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return sig, err
}

// Put upserts one decision. Called once per album rather than batched, for the
// reason Audio.Put is: a pass interrupted after two hours must keep its two
// hours.
func (r *Matches) Put(ctx context.Context, d Decision) error {
	if d.Candidates == nil {
		d.Candidates = json.RawMessage("[]")
	}
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO match_decisions (albumId, state, reason, releaseMbid, releaseGroupMbid,
		  disambiguation, distance, separation, pinned, trackSig, attempts, decidedAt,
		  retryAfter, candidates)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(albumId) DO UPDATE SET
		  state=excluded.state, reason=excluded.reason, releaseMbid=excluded.releaseMbid,
		  releaseGroupMbid=excluded.releaseGroupMbid, disambiguation=excluded.disambiguation,
		  distance=excluded.distance, separation=excluded.separation, pinned=excluded.pinned,
		  trackSig=excluded.trackSig, attempts=excluded.attempts, decidedAt=excluded.decidedAt,
		  retryAfter=excluded.retryAfter, candidates=excluded.candidates`,
		d.AlbumID, d.State, d.Reason, d.ReleaseMbid, d.ReleaseGroupMbid, d.Disambiguation,
		d.Distance, d.Separation, d.Pinned, d.TrackSig, d.Attempts, d.DecidedAt,
		d.RetryAfter, string(d.Candidates))
	return err
}

// One line, no tabs: mDecisionCols is derived from it by string surgery, so
// the two column lists cannot drift apart.
const decisionCols = `albumId, state, reason, releaseMbid, releaseGroupMbid, disambiguation, distance, separation, pinned, trackSig, attempts, decidedAt, retryAfter, candidates`

var mDecisionCols = "m." + strings.ReplaceAll(decisionCols, ", ", ", m.")

// Get returns the stored decision; ok=false when the album was never decided.
func (r *Matches) Get(ctx context.Context, albumID string) (*Decision, bool, error) {
	ds, err := r.query(ctx, `SELECT `+decisionCols+`, '', '' FROM match_decisions WHERE albumId = ?`, albumID)
	if err != nil || len(ds) == 0 {
		return nil, false, err
	}
	return &ds[0], true, nil
}

// NonMatched is the review queue: every album the matcher did not settle,
// joined to its title and artist so the client needs no second request.
func (r *Matches) NonMatched(ctx context.Context) ([]Decision, error) {
	return r.query(ctx, `
		SELECT `+mDecisionCols+`, COALESCE(a.album, ''), COALESCE(a.albumArtist, '')
		FROM match_decisions m
		LEFT JOIN (`+albumsExpr+`) a ON a.albumId = m.albumId
		WHERE m.state <> 'matched'
		ORDER BY m.distance IS NULL, m.distance, m.albumId`)
}

// LowSeparation is the confidence tail: albums the matcher DID settle, but
// where the runner-up release was nearly as good a fit. They cleared the veto
// by construction — everything below minSeparation is already `review` — so max
// here is the caller's "close to the line" band, not the veto threshold itself.
//
// Pinned rows are excluded: the user already looked at that album and chose,
// which is a better answer than the distance metric has.
func (r *Matches) LowSeparation(ctx context.Context, max float64) ([]Decision, error) {
	return r.query(ctx, `
		SELECT `+mDecisionCols+`, COALESCE(a.album, ''), COALESCE(a.albumArtist, '')
		FROM match_decisions m
		LEFT JOIN (`+albumsExpr+`) a ON a.albumId = m.albumId
		WHERE m.state = 'matched' AND m.pinned = 0
		  AND m.separation IS NOT NULL AND m.separation < ?
		ORDER BY m.separation, m.albumId`, max)
}

// Reset drops every unpinned decision, which is how "re-match the whole
// library" is spelled: PendingAlbums then sees `m.albumId IS NULL` for all of
// them. Deleting rather than clearing retryAfter, because a forced re-match
// should also restart the backoff ladder — a review row with an empty
// retryAfter would otherwise be pending never again.
func (r *Matches) Reset(ctx context.Context) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM match_decisions WHERE pinned = 0`)
	return err
}

// Delete removes one album's decision (unpinning, so the next pass re-decides).
func (r *Matches) Delete(ctx context.Context, albumID string) error {
	_, err := r.db.ExecContext(ctx, `DELETE FROM match_decisions WHERE albumId = ?`, albumID)
	return err
}

// ReleaseGroupVotes counts, per MusicBrainz release group, how many of the
// album's tracks AcoustID placed in it. The nesting is unwrapped in SQL with
// json_each because track_fp.recordings is the raw AcoustID results array and
// the alternative is dragging ~2 KB of JSON per track into Go to count strings.
//
// Soft-fails to (nil, nil) on ANY error, deliberately: track_fp may not exist
// on a deployment that never ran fingerprinting, and an absent fingerprint
// source must degrade matching to text search rather than fail the pass.
// ponytail: soft-fail instead of a table-exists probe. The ceiling is that a
// genuinely broken query looks identical to "no fingerprints"; the upgrade is
// returning the error and letting the caller log it.
func (r *Matches) ReleaseGroupVotes(ctx context.Context, albumID string) map[string]int {
	rows, err := r.db.QueryContext(ctx, `
		SELECT json_extract(rgs.value, '$.id') AS rgid, COUNT(DISTINCT t.id)
		FROM tracks t
		JOIN track_fp f ON f.trackId = t.id
		JOIN json_each(f.recordings) res
		JOIN json_each(res.value, '$.recordings') rec
		JOIN json_each(rec.value, '$.releasegroups') rgs
		WHERE t.albumId = ? AND f.recordings IS NOT NULL
		GROUP BY rgid`, albumID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := map[string]int{}
	for rows.Next() {
		var id sql.NullString
		var n int
		if err := rows.Scan(&id, &n); err != nil {
			return nil
		}
		if id.Valid && id.String != "" {
			out[id.String] = n
		}
	}
	if rows.Err() != nil {
		return nil
	}
	return out
}

func (r *Matches) query(ctx context.Context, q string, args ...any) ([]Decision, error) {
	rows, err := r.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Decision
	for rows.Next() {
		var d Decision
		var cands string
		if err := rows.Scan(&d.AlbumID, &d.State, &d.Reason, &d.ReleaseMbid, &d.ReleaseGroupMbid,
			&d.Disambiguation, &d.Distance, &d.Separation, &d.Pinned, &d.TrackSig, &d.Attempts,
			&d.DecidedAt, &d.RetryAfter, &cands, &d.Album, &d.AlbumArtist); err != nil {
			return nil, err
		}
		d.Candidates = json.RawMessage(cands)
		out = append(out, d)
	}
	return out, rows.Err()
}
