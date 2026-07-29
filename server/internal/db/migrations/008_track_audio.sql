-- Facts read off the decoded audio rather than off the container name and the
-- tags. One row per track, written by internal/analyze from a single
-- `ffmpeg -af ebur128=peak=true` decode pass.
--
-- Its own table rather than columns on tracks: the scanner's UpsertAll replaces
-- every column in trackCols whenever mtime or size moves, so analysis results
-- stored on tracks would be silently erased by a rescan triggered by nothing
-- more than a tag edit — hours of decoding thrown away by a one-byte change.
-- The FK cascade is what DeleteNotIn needs to not leak rows.
--
-- mtime/size are copied from the tracks row at analysis time and ARE the whole
-- incremental rule, identical to the scanner's own skip test. No content hash,
-- no analysedAt comparison: if the bytes did not move, the loudness did not
-- either. analysedAt exists for the health view, not for deciding what to redo.
--
-- Every measured column is nullable on purpose. ebur128 prints `I: -70.0 LUFS`
-- (its absolute gate) for silence and for anything shorter than one 400 ms
-- gating block, and `Peak: -inf dBFS` for digital silence. Those mean
-- "unmeasurable", not "very quiet", and must never become a +52 dB ReplayGain.
--
-- Gains are deliberately NOT stored: trackGain is -18.0 - integratedLufs and
-- trackPeak is 10^(truePeakDbfs/20). Two lines in Go, and the reference level
-- stays a decision instead of being frozen into 25,000 rows. Album gain is
-- likewise aggregated on read — no album_audio table.
CREATE TABLE track_audio (
  trackId        TEXT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
  mtime          INTEGER NOT NULL DEFAULT 0,
  size           INTEGER NOT NULL DEFAULT 0,
  analysedAt     TEXT NOT NULL,

  integratedLufs REAL,    -- ebur128 "I:";   NULL when nothing passed the gate
  lra            REAL,    -- ebur128 "LRA:", in LU
  truePeakDbfs   REAL,    -- ebur128 true-peak "Peak:"; NULL for -inf

  codec          TEXT NOT NULL DEFAULT '', -- as ffmpeg decodes it: flac, mp3, alac, aac, opus
  sampleRate     INTEGER,
  bitsPerSample  INTEGER, -- NULL for float sample formats, where it is meaningless
  channels       INTEGER,
  lossless       INTEGER NOT NULL DEFAULT 0, -- from the real codec, not the file extension
  -- stream contradicts what the scanner read off the container (a transcode
  -- wearing a lossless extension). Read by the library health view and by the
  -- `suspect` smart-playlist predicate.
  suspect        INTEGER NOT NULL DEFAULT 0
);
