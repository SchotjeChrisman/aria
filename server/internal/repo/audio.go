package repo

import (
	"context"
	"database/sql"
)

// TrackAudio is one row of track_audio: what the decoder actually saw. Every
// measured field is nullable — ebur128 reports "unmeasurable" for silence and
// for files shorter than one 400 ms gating block, and that must stay
// distinguishable from a real measurement (see 008_track_audio.sql).
type TrackAudio struct {
	TrackID        string   `json:"trackId"`
	IntegratedLUFS *float64 `json:"integratedLufs"`
	LRA            *float64 `json:"lra"`
	TruePeakDBFS   *float64 `json:"truePeakDbfs"`
	Codec          string   `json:"codec"`
	SampleRate     *int     `json:"sampleRate"`
	BitsPerSample  *int     `json:"bitsPerSample"`
	Channels       *int     `json:"channels"`
	Lossless       bool     `json:"lossless"`
	Suspect        bool     `json:"suspect"`
	// AudioMD5 is the MD5 of the decoded s32 audio: tag-invariant content
	// identity, computed by the same ffmpeg pass. "" means ffmpeg produced none
	// (which is stored, so it is not retried forever); see 009_audio_md5.sql.
	AudioMD5 string `json:"audioMd5"`
}

// Pending is one file the analyzer still owes work on, carrying the values the
// scanner claimed off the container so `suspect` is computed without a second
// query.
type Pending struct {
	ID, Path                            string
	Mtime, Size                         int64
	SampleRate, BitsPerSample, Channels *int
	Lossless                            bool
}

type Audio struct{ db *sql.DB }

func NewAudio(db *sql.DB) *Audio { return &Audio{db} }

// ListPending is the whole incremental discipline in one statement:
// deliberately the same three-way test the scanner uses on its own walk
// (no row / mtime moved / size moved). ORDER BY path so one album's files
// decode consecutively — a real seek win on a spinning NAS, and it makes the
// album aggregation useful before the pass finishes.
//
// `audioMd5 IS NULL` is the fourth clause and is a one-time backfill: rows
// analysed before migration 009 have no hash, and re-decoding them is the only
// way to get one. It re-queues the whole already-analysed library exactly once
// on upgrade — hours — which is deliberate; the pass is nice(10), scan-aware,
// resumable and single-flight, so it is the cheapest place for that work to
// happen. An empty string (ffmpeg produced no hash) is NOT NULL, so it never
// re-queues.
func (r *Audio) ListPending(ctx context.Context) ([]Pending, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT t.id, t.path, t.mtime, t.size,
		       t.sampleRate, t.bitsPerSample, t.channels, t.lossless
		FROM tracks t LEFT JOIN track_audio a ON a.trackId = t.id
		WHERE a.trackId IS NULL OR a.mtime <> t.mtime OR a.size <> t.size
		   OR a.audioMd5 IS NULL
		ORDER BY t.path`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Pending
	for rows.Next() {
		var p Pending
		if err := rows.Scan(&p.ID, &p.Path, &p.Mtime, &p.Size,
			&p.SampleRate, &p.BitsPerSample, &p.Channels, &p.Lossless); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// Put upserts one analysed file. Called once per file rather than in batches,
// for the reason the Enricher writes per item: a pass interrupted after four
// hours must keep its four hours.
func (r *Audio) Put(ctx context.Context, a TrackAudio, mtime, size int64, analysedAt string) error {
	_, err := r.db.ExecContext(ctx, `
		INSERT INTO track_audio (trackId, mtime, size, analysedAt, integratedLufs, lra,
		  truePeakDbfs, codec, sampleRate, bitsPerSample, channels, lossless, suspect, audioMd5)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(trackId) DO UPDATE SET
		  mtime=excluded.mtime, size=excluded.size, analysedAt=excluded.analysedAt,
		  integratedLufs=excluded.integratedLufs, lra=excluded.lra,
		  truePeakDbfs=excluded.truePeakDbfs, codec=excluded.codec,
		  sampleRate=excluded.sampleRate, bitsPerSample=excluded.bitsPerSample,
		  channels=excluded.channels, lossless=excluded.lossless, suspect=excluded.suspect,
		  audioMd5=excluded.audioMd5`,
		a.TrackID, mtime, size, analysedAt, a.IntegratedLUFS, a.LRA,
		a.TruePeakDBFS, a.Codec, a.SampleRate, a.BitsPerSample, a.Channels, a.Lossless, a.Suspect,
		a.AudioMD5)
	return err
}

// Count is how many tracks have been analysed at all — a scalar for the health
// view, which must not pull 25k rows to print one number. ListAll's map is the
// wrong tool here and is already loaded for a different reason.
func (r *Audio) Count(ctx context.Context) (int, error) {
	var n int
	err := r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM track_audio`).Scan(&n)
	return n, err
}

// ListAll returns every analysed row keyed by track id. The merged /api/tracks
// view already holds durations and album ids, so album aggregation needs no
// second query and no per-album round trip.
func (r *Audio) ListAll(ctx context.Context) (map[string]TrackAudio, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT trackId, integratedLufs, lra, truePeakDbfs, codec,
		       sampleRate, bitsPerSample, channels, lossless, suspect,
		       -- pre-009 rows are NULL; readers only ever want "the hash or
		       -- nothing", and the NULL/'' distinction that ListPending needs
		       -- lives in SQL, not in the struct.
		       COALESCE(audioMd5, '')
		FROM track_audio`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]TrackAudio{}
	for rows.Next() {
		var a TrackAudio
		if err := rows.Scan(&a.TrackID, &a.IntegratedLUFS, &a.LRA, &a.TruePeakDBFS,
			&a.Codec, &a.SampleRate, &a.BitsPerSample, &a.Channels, &a.Lossless, &a.Suspect,
			&a.AudioMD5); err != nil {
			return nil, err
		}
		out[a.TrackID] = a
	}
	return out, rows.Err()
}
