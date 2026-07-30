# Periodic rescan, disc-folder folding, and the zero-sample hash

Date: 2026-07-30 · Ships in: 3.6.0 · Branch: `feat/periodic-rescan`

Three findings from an audit of the live server after the 3.5.0 rollout, plus
the fixes. All three were invisible from the test suite because all three are
about what the server does over *time* on a *real* library.

## 1. Nothing ever rescanned

### The bug

`Scanner.Scan` had exactly two triggers: boot **when the tracks table is empty**,
and `POST /api/scan`. There was no ticker, no timer, no filesystem watcher.

The boot chain (fingerprint → enrich → analyse) *did* run on every start, which
made it look like the server was keeping itself current. It was not: those three
passes all work from the `tracks` table, and only the scanner writes it. So:

- **a new album never appeared** until someone pressed Rescan;
- **a changed file was never re-analysed**, even across a restart. `ListPending`
  compares `track_audio.mtime/size` against **`tracks.mtime/size`** — the
  scanner's recorded values, not the filesystem's. With no scan the first link
  never fires, so the mismatch that should trigger a re-decode never exists.

Observed on the live server: 51 files had been rewritten on disk that morning
(cover art embedded by another NFS client), and `pending analyze` was `0`.

### The fix

Two cadences, one goroutine, one `select` — which is also what serialises them.

| Env | Default | What it does |
| --- | --- | --- |
| `SCAN_INTERVAL` | `1h` | Walk. Run the passes **only if the walk found new or changed files**. |
| `FULL_SCAN_INTERVAL` | `24h` | Walk. Run the passes **regardless**. |

`0` disables a cadence; a nil channel blocks forever in `select`, so that needs
no branch in the loop. An unparseable duration logs and takes the default —
a typo must not silently disable a scan the user meant to schedule.

Both walk, because walking is the only way a new album is ever discovered, and
it is cheap: the scanner re-parses nothing whose mtime and size are unchanged.
The daily pass exists for the *other* half of the ask — new data for albums
already in the library. The enricher is TTL-driven internally (discography 7d,
artist popularity 30d) and those TTLs can only expire on a pass that reaches
them. Running that hourly would mean 24× the requests to MusicBrainz, Discogs
and Deezer to discover the same nothing, which is why the hourly pass has to
earn the chain by finding something.

A failed scan skips the chain entirely, including `ErrScanRunning`: `LastParsed`
then describes the *other* scan, not this tick's.

### Deliberately not built

- **Cron expressions.** "Every day at 04:00" needs a parser, a timezone and a UI
  to set it in. The daily pass lands at boot-time + 24h. Ceiling noted in the
  code: the upgrade is one `time.Until` before the loop, not a dependency.
- **A forced full re-parse mode.** Considered and rejected in planning: mtime +
  size is a sound change detector, and re-reading 7572 tag headers nightly buys
  only the case of a tagger that rewrites tags without moving mtime.
- **A filesystem watcher.** Would not survive the NFS mount this runs on.

## 2. Multi-disc sets fragmented into one album per disc

### The bug

`discSegRE` folded a disc subfolder into its parent album, but only recognised
`cd|disc|disk`. A MusicBrainz-aware tagger (Picard) names disc folders after the
release **medium format** instead — `Digital Media 01`, `Hybrid SACD 2`. Those
did not match, so every disc became its own album.

On the live library: 29 album rows that are really 9 albums, so **20 phantom
albums** — the bulk of an unexplained 604-vs-577 gap against the same library in
Jellyfin (which merges on the `DISCNUMBER` tag).

### The fix

The medium formats join the alternation. The numeral stays mandatory, which is
what keeps `Vinyl Days`, `Cassette Tapes`, `Discography` and `Disc Jockey` from
folding — all covered by tests.

A fixed word list, not "any word followed by a number": the general rule needs
sibling-folder context ("are this folder's neighbours named the same way?") and
`albumIdentity` is deliberately a pure function of one path, which is what lets
the remap recompute ids from stored columns without re-walking the library.
Ceiling: `7" Vinyl` and localised format names still split.

### Making a grouping-rule change reach an existing library

This is the part that needed real care. `albumId` is a pure function of stored
columns, so `upgradeAlbumIDs` can re-key without re-parsing — but the remap that
carries `tag_items`, `edits`, `enrich_cache` and `art/*` across reads
`tracks.legacyAlbumId`, which migration 007 stamped **once** with the pre-007
id and nothing ever reset.

Bumping the sentinel alone would therefore have been wrong: the remap would map
*ancient* → *new*, while the data actually sits under the *current* (007-era)
ids, orphaning all of it.

Three changes make a second re-key sound, and any later one after that:

1. `upgradeAlbumIDs` re-stamps `legacyAlbumId` from the id it is replacing
   (`SET legacyAlbumId = albumId, albumId = ?` — SQLite evaluates the whole SET
   list against the pre-update row). On the 007 run the two are already equal,
   so this is a no-op there.
2. The remap clears `legacyAlbumId` when it is done, so its
   `legacyAlbumId <> ''` filter means "moved in *this* pass".
3. The sentinel becomes a **grouping-rule** version, not a schema-migration one.
   `007` → `012`.

### `match_decisions` joins the remap

Migration 011 added `match_decisions`, keyed by `albumId`, *after* the remap was
written — so it was not being carried and those albums would have silently lost
their MusicBrainz match.

It follows the same 1:1-or-drop rule as `enrich_cache`, for a stronger reason: a
merge is exactly the case here, each disc carried its own decision against its
own MB release, and the stored `trackSig` — the matcher's proof that its
decision still applies to these tracks — was computed over one disc's tracks and
cannot survive the merge.

## 3. Undecodable files all hashed to the same value

### The bug

A file whose audio stream describes itself fine but decodes to **zero samples**
(a FLAC with a valid header and no readable frames, seen in the wild) still
exits 0, and the md5 muxer hashes the nothing it received:
`d41d8cd98f00b204e9800998ecf8427e` — the MD5 of the empty string.

That digest is not an identity for the file. *Every* undecodable file in the
library produces it, so a second one would make `/api/library/duplicates` report
two unrelated broken files as byte-identical copies — a false positive in the
one view a user deletes from.

The existing comment claimed the stored hash "cannot false-POSITIVE against a
different file". That reasoning covers a *partial* decode, whose hash is still
derived from the file's own audio. It does not cover the zero-sample case.

### The fix

`parseMD5` returns `""` for it, which is the established sentinel: excluded from
`DuplicateMD5`, and per `009_audio_md5.sql` not re-queued forever.

### Left alone

`truePeakDbfs` is stored as `0.0` on those rows, from `ebur128` reporting a peak
over no samples. It is meaningless but harmless — it is below the clipping
threshold, so it surfaces nowhere. Nulling it, or adding an `undecodable` health
issue kind so broken files are visible instead of merely quiet, is a separate
change.
