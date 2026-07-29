-- Chromaprint fingerprints and their AcoustID lookup results. One row per track.
--
-- Its own table rather than columns on track_audio, for three reasons each of
-- which is sufficient on its own: a different producer (fpcalc, not ffmpeg), a
-- different feature gate (a deployment can have ffmpeg and no fpcalc, or the
-- reverse), and a second, independent staleness key — the network half must be
-- re-runnable without re-fingerprinting when an ACOUSTID_KEY finally arrives.
--
-- FK cascade so DeleteNotIn does not leak rows, same as track_audio.
CREATE TABLE track_fp (
  trackId      TEXT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,

  -- copied from tracks at fingerprint time; identical rule to track_audio and to
  -- the scanner's own skip test. A fingerprint is a pure function of the bytes,
  -- so if the bytes did not move neither did it.
  mtime        INTEGER NOT NULL DEFAULT 0,
  size         INTEGER NOT NULL DEFAULT 0,
  calculatedAt TEXT NOT NULL,

  -- fpcalc -json -length 120: URL-safe base64, ~2.6 KB for a real 120 s window.
  -- -length is pinned in the command rather than left to fpcalc's (identical)
  -- default, because AcoustID's index is built over the first 120 s and a future
  -- default change would invalidate every row here without moving mtime or size.
  fingerprint  TEXT NOT NULL,
  -- FULL track duration in whole seconds — fpcalc reports the whole file even
  -- when only 120 s were fingerprinted — because that is what AcoustID matches
  -- against with maxdurationdiff (default 7 s).
  duration     INTEGER NOT NULL,

  -- The lookup half. All NULL until a request succeeds, which is also the state
  -- of every row when no ACOUSTID_KEY is set: the feature being dark must be
  -- indistinguishable from "not looked up yet", so that setting a key later just
  -- works with no backfill step.
  acoustId     TEXT,   -- results[0].id, the AcoustID UUID
  score        REAL,   -- results[0].score, 0..1
  -- The full results array, [{"id","score","recordings":[{"id","releasegroups":
  -- [{"id"}]}]}], as returned. JSON blob, not a child table: the matcher counts
  -- release-group votes across one album's tracks in SQL with json_each
  -- (repo.Matches.ReleaseGroupVotes) and never reads a row whole in Go, so a
  -- track_fp_recordings table would be a join serving zero queries.
  -- Same call enrich_cache already makes.
  -- ponytail: opaque to SQL. Ceiling is "find every track matching recording X"
  -- without a scan; upgrade is a generated column + index, or json_each.
  recordings   TEXT,

  -- Separate from calculatedAt so a key arriving later re-runs lookups over
  -- fingerprints already computed. lookupError holds the API's error.message, so
  -- a systematic failure (invalid key, 429) is visible instead of looking like
  -- "no match".
  lookedUpAt   TEXT,
  lookupError  TEXT
);
-- No indexes: 25k rows, and both pending queries are full scans that run once
-- per pass. Add one when a query, not a guess, is slow.
