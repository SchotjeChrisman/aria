-- The matcher's conclusion about which MusicBrainz release an album is, one row
-- per albumId.
--
-- NOT columns on `albums`, and NOT a foreign key to it. repo.Albums.Rebuild runs
-- `DELETE FROM albums` followed by INSERT..SELECT..GROUP BY after every scan, so
-- a column added there is erased by the next rescan and a cascade there would
-- drop every decision the first time the user hits Scan. Same reasoning as
-- 008_track_audio.sql ("the scanner's UpsertAll replaces every column"), one
-- level up. There is deliberately no FK at all here: albumId is the scanner's
-- sha1(dir||album||artist) and rows for a vanished album are harmless (a few
-- hundred bytes) next to the alternative.
--
-- This table is the MACHINE's conclusion. The USER's authority over the same
-- album — state/disambiguation/locked, api/edits.go — stays in `edits` and
-- always wins, which is the codebase's existing edits-beat-enrichment rule, not
-- a new one. The two must not share a table: a machine `local` carries
-- retryAfter and is reconsidered on backoff, a user `local` is permanent and
-- means "never ask MusicBrainz about this album again". Same word, different
-- authority; separate tables are what makes that expressible.
--
-- `candidates` is a JSON array rather than a second match_candidates table.
-- Candidates are never queried across albums, never joined and never updated
-- individually — they are the evidence blob for exactly one decision, rewritten
-- wholesale on every re-match. A row-per-candidate table would only ever be
-- SELECTed WHERE albumId=? and immediately re-serialised into the JSON the
-- review UI wants.
-- ponytail: opaque to SQL. Ceiling is a cross-album query over candidates
-- ("every album that considered release X"); upgrade is json_each or a split-out
-- table. Nothing needs it today — "low-separation matches" is the `separation`
-- column right here.
CREATE TABLE match_decisions (
  albumId          TEXT PRIMARY KEY,
  state            TEXT NOT NULL CHECK (state IN ('matched','review','local')),
  -- no-candidates | no-plausible-candidate | indistinguishable-siblings |
  -- low-separation | weak-match | pinned | ok
  reason           TEXT NOT NULL DEFAULT '',
  releaseMbid      TEXT,                       -- NULL for review/local
  releaseGroupMbid TEXT,
  disambiguation   TEXT NOT NULL DEFAULT '',   -- MB's release disambiguation, for display
  distance         REAL,                       -- D1, the winner's distance
  separation       REAL,                       -- D2-D1; NULL when no rival release group existed
  pinned           INTEGER NOT NULL DEFAULT 0, -- user chose this release; never re-decided

  -- Idempotency key: count||':'||sum(size) over the album's tracks, computed in
  -- SQL so there is no Go-side pass over 25k rows. Files added, removed or
  -- replaced move it; a DB-only metadata edit does not, which is correct — the
  -- manual re-match route is what exists for that.
  trackSig         TEXT NOT NULL DEFAULT '',

  attempts         INTEGER NOT NULL DEFAULT 0,
  decidedAt        TEXT NOT NULL,
  -- '' = never retry (matched, or pinned). Otherwise the ISO instant after
  -- which this album is reconsidered: 24h doubling to a 30d ceiling. This is
  -- what replaces enrich.go's permanent negative cache — a release MusicBrainz
  -- ingests next month is eventually found. NOT an HTTP backoff; politeClient
  -- owns that.
  retryAfter       TEXT NOT NULL DEFAULT '',
  candidates       TEXT NOT NULL DEFAULT '[]'
);
-- The review queue is `WHERE state <> 'matched'`; everything else is by primary
-- key. One index, and only because that scan is what the app polls.
CREATE INDEX idx_match_state ON match_decisions(state);
