# Library accuracy: identity, analysis, presentation, and corrections

Research + plan, 2026-07-29. Target: the server identifies every album
correctly, analyses the actual audio rather than trusting tags, presents names
in a script the user can read, pulls in what the open internet offers, and
holds every correction in the database. (The original target ended "and can
write correct tags back to the files"; the user cut file write-back — see
Phase 5.)

Four real failures drove this plan and serve as its acceptance tests:

1. **"Barber, Bruch"** displays as composers rather than as Esther Yoo.
2. **"Down the Road Wherever Tour"** (Amsterdam, user was there) matched to the
   Madrid show.
3. **"Essential Brahms, volume 1"** (2013) split into four albums.
4. Conductor renders as **Василий Петренко**, unreadable to the user.

---

## 1. Diagnosis

### 1.1 Album identity is a hash of tag strings

`scanner.go:251-253`:

```go
albumArtist := or(first(tags, taglib.AlbumArtist), artist)
albumID := sha1Hex(strings.ToLower(albumArtist) + "\x00" + strings.ToLower(album))
```

This single expression causes failures **2 and 3**, from opposite directions.

**Splitting (case 3).** When `ALBUMARTIST` is absent the identity falls back to
the track's own `ARTIST`. A Brahms compilation has a different performer per
work, so four performers produce four albums sharing one title. Contributing
vectors: `first()` takes only the first value of a multi-valued `ARTIST`, and
some taggers write `ALBUM ARTIST` as a TXXX frame that TagLib does not surface
as `ALBUMARTIST`. The `COMPILATION` flag — which every correctly-tagged
compilation sets, and which `taglib` exposes at `taglib.go:52` — is ignored
entirely.

**Merging (case 2).** Two different concerts with identical tags hash to one
`albumId` and collapse into a single album, at scan time, before any
enrichment runs.

Both are the same defect: identity derived from tag strings rather than from
where the files live.

### 1.2 Identification is an unverified top hit

`enrich.go:473` takes `searchReleases(album, albumArtist, limit=1)[0]` as
truth. Nothing checks track count, durations, or titles.

Case 2 is the worst version of this. MusicBrainz holds **thirteen** releases
titled `Down The Road Wherever Tour 2019 - <City> (<date>)`, and **no
Amsterdam show**. All thirteen score nearly identically against the query;
Madrid ranked first and was taken with no verification. The danger is not
mismatching to something obviously wrong — it is mismatching to a
near-identical sibling that looks entirely plausible.

A distance threshold alone would not have caught this. A sibling show has the
right artist, tour, era and a nearly identical setlist; it can score *well*.

### 1.3 Credits only work on already-tagged files

`enrich.go:489` skips any track without a MusicBrainz recording ID
(`if t.MBRecordingID == nil { continue }`). A library never run through Picard
gets no per-track credits — precisely the library that needs them.

### 1.4 No presentation layer

Case 1: MusicBrainz is *correct* and the server faithfully copies it. Release
`ec17a59b-6ca3-4817-9ca9-67b137550819` has this artist credit:

| # | Credit | Joinphrase | Artist type |
|---|---|---|---|
| 1 | Barber | `, ` | Person (Samuel Barber) |
| 2 | Bruch | `; ` | Person (Max Bruch) |
| 3 | Esther Yoo | `, ` | Person |
| 4 | Василий Петренко | `, ` | Person |
| 5 | Royal Philharmonic Orchestra | — | Orchestra |

Joined naively: `Barber, Bruch; Esther Yoo, Василий Петренко, Royal
Philharmonic Orchestra`. Perfect identification never yields "Esther Yoo". This
is a display policy problem, and no such layer exists.

Case 4 lives here too. The same query shows the fix is already in the data:
`sort-name` is **"Petrenko, Vasily"** (Latin), and there is an alias with
`locale=en, primary=true` reading **"Vasily Petrenko"**.

### 1.5 Nothing looks at the audio

`lossless` is inferred from the container name (`scanner.go:32`, `:301`), not
the decoded stream. No loudness, no true peak, no BPM, no key, no duplicate
detection, no way to notice a FLAC that is a transcoded MP3.

### 1.6 Enrichment is one-way and gives up permanently

Everything lands in `enrich_cache`; files stay wrong forever, and `/music` is
`:ro` (`compose.yaml:19`). `if mbid == "" && !found` means an album that failed
once is never retried.

## 2. Shape of the fix

Four layers, each able to correct the one below it.

**Identity** — which album is this, established from disk layout first and
MusicBrainz second, with a confidence score and stored evidence.

**Measurement** — facts computed from the audio itself: loudness, true peak,
content hash. (The original plan added BPM/key/mood here; Phase 7 was cut.)

**Enrichment** — facts fetched from open sources, anchored to a confirmed MBID
rather than a guess.

**Presentation** — policy over the above: which credited entity is the display
artist, and in which script names are shown. Never destructive.

## 3. Decisions

| Question | Decision | Why |
|---|---|---|
| Album grouping | Directory-derived, tags as a tiebreak | Fixes cases 2 and 3 with one change; disk layout is a stronger signal than tags in a badly-tagged library |
| Non-Latin names | Resolve to Latin for display; **store both** | User requirement is a display requirement; overwriting would let write-back erase the original script from disk irreversibly |
| Classical display artist | Split artist-credit at the `; ` joinphrase, pick performer by role | MB encodes the composer/performer boundary structurally; role comes from `artist-rels`, already fetched at `enrich.go:485` |
| Match safety | Ambiguity is an independent veto, separate from the distance score | Thirteen sibling shows cluster within noise; "I don't know" must be reachable |
| Candidate verification | Fetch `inc=recordings` per candidate; never trust search rank | Per-track durations are what discriminate two nights of one tour |
| Unmatched albums | First-class `local` state | Some albums are legitimately not in MusicBrainz and the user's own metadata is authoritative |
| Fingerprinting | Bundle static `fpcalc` beside `/ffmpeg`; exec it | `wader/static-ffmpeg:7.1` is **not** built with `--enable-chromaprint`, so ffmpeg's chromaprint muxer is unavailable. No cgo, same pattern as the existing ffmpeg exec |
| Loudness / content hash | ffmpeg `ebur128=peak=true` and `-f md5`, in-process | Already bundled. One decode pass yields ReplayGain 2.0 inputs and a tag-invariant identity |
| BPM / key / mood | ~~Optional Essentia **sidecar**~~ **CUT, not built** | Would have been a separate optional image: Essentia is AGPL-3.0 and the MTG models are CC BY-NC-ND 4.0 |
| Tag writing | ~~`taglib.WriteTags`~~ **CUT, not built** | Corrections go to the database; `MUSIC_DIR` stays read-only. README carries the note on why write-back will eventually be wanted |
| Tag vocabulary | ~~Picard's mapping table~~ **CUT, not built** | Only tag writing needed it |
| MusicBrainz access | Public API at 1 req/s | Requests become per-release, not per-track: ~2,000 albums ≈ 35 min one-off. A local mirror is 50+ GB for no benefit at household scale |
| Spotify | Not an option | `audio-features` / `audio-analysis` killed for new apps on 2024-11-27 — the reason local DSP is the answer |

---

## Phase 0 — album identity

Highest value, blocks everything downstream, fixes two of the four reported
cases. Goes first.

Album identity becomes directory-derived. One folder is one album. Disc
subfolders (`CD1`, `Disc 2`, `Disc One`) merge into the parent. Tags become a
tiebreak for the pathological case of several genuinely different albums
dumped in one folder, rather than the primary key.

Sibling folders with no common parent (`… Volume 1 CD1` … `CD4` at top level)
are *not* merged automatically at this stage — that needs the MusicBrainz
release's media structure, which arrives in Phase 4. `discNo` already exists in
the schema and is ready for it.

Independently and cheaply: read `COMPILATION` and use `Various Artists` for
album identity rather than falling back to per-track `ARTIST`. A few lines,
fixes the whole compilation class on its own, and does not need undoing later.
Also read all values of multi-valued `ARTIST` rather than only the first, and
check `ALBUM ARTIST`-as-TXXX as a fallback source for `ALBUMARTIST`.

A manual `local` / `locked` flag on albums lands here too, even though
automatic routing to it comes in Phase 4. That gives an immediate hand-fix for
the Amsterdam album the day this ships.

Migration is the real work: `albumId` is referenced by `tag_items`,
`enrich_cache`, `edits` and the art files on disk. Write a migration that maps
old ids to new and rewrites those references, and keep the old id in a column
so art filenames can be resolved during a transition period.

**Verification:** "Essential Brahms, volume 1" becomes one album; two Knopfler
show folders stay two albums. Both assertable in a scanner test with fixture
directories.

## Phase 1 — presentation policy

No new data required; the enricher already fetches what this needs. Immediate,
visible, fixes the remaining two reported cases.

### 1a. Latin names, always

Resolution chain per artist: alias with `locale=en` and `primary=true` → any
Latin-script alias of type *Artist name*, preferring primary → de-inverted
`sort-name` → transliteration, marked as such.

`sort-name` is Latin by MusicBrainz guideline, which makes it a reliable
universal floor. De-inversion must be type-aware: `Petrenko, Vasily` →
`Vasily Petrenko` for a Person, `Beatles, The` → `The Beatles` for a Group.

Cost is an added `inc=aliases` on the existing `artist(ctx, mbid, inc)` call
plus caching — no new requests.

Store `name` and `nameLatin` side by side. Display always uses Latin per the
requirement; disk keeps both. This still matters with Phase 5 reduced to
database-only corrections: if Latin-only were baked into the data layer, any
future write-back (see the README) would permanently erase
the original script from the files, which would be wrong for anyone with a
Russian- or Japanese-language library. Same result for the user, nothing
destroyed.

Applies everywhere names surface: artist, albumArtist, composer, conductor,
orchestra, performers, and the credited-people long tail in `Enricher.People()`.
Release and work titles have aliases too and get the same treatment. Files with
no MusicBrainz match have no alias to reach for, so transliteration is the only
option there and should be flagged as approximate.

### 1b. Classical display artist

Split the artist-credit array at the `; ` joinphrase — MusicBrainz's structural
convention separating composers from performers. Left side populates the
composer field; right side supplies the display artist.

Choose among performers by role, read from the release's `artist-rels`
(already requested at `enrich.go:485` and currently discarded): soloist first,
then conductor, then orchestra or choir. Artist `type` disambiguates the last
step. For "Barber, Bruch": Yoo has a violin performer relation, Petrenko a
conductor relation, the RPO is type `Orchestra` — display artist is Esther Yoo,
composers are Barber and Bruch, and the rest populate the credit fields the app
already renders.

The rule is a setting, not a hardcode; a user override pins the display artist
permanently.

**Verification:** "Barber, Bruch" shows as Esther Yoo with Barber and Bruch as
composers; the conductor reads "Vasily Petrenko".

## Phase 2 — audio truth, no network

New package `internal/analyze`. One ffmpeg invocation per file computes
integrated loudness, loudness range and true peak via `ebur128=peak=true`; the
decoded-audio MD5 via `-map 0:a -f md5 -`; and the real codec, bit depth and
sample rate as ffmpeg reports them rather than as the container claims.

Results land in `track_audio`, keyed by track id, with the same incremental
discipline the scanner uses (skip on unchanged `mtime` and `size`). Progress
reuses the existing SSE hub.

`lossless` gets recomputed from the real codec and a `suspect` flag is set when
container and stream disagree — the cheap transcode check. Spectral-cutoff
analysis is deliberately deferred; the codec check catches the common case.

One full decode per file, so this is a background job with its own status, not
part of the scan, parallelised across `NumCPU` like the scanner.

Album ReplayGain is a second aggregation pass over stored per-track values —
arithmetic, not another decode.

## Phase 3 — fingerprinting

Add `fpcalc` (linux amd64 and arm64, statically linked, ~5 MB, from the
Chromaprint releases) to the Dockerfile beside `/ffmpeg`. Config gains
`FPCALC_PATH` mirroring `FFMPEG_PATH`; its absence degrades the feature rather
than breaking startup, exactly as the transcode tiers already do.

`track_fp` stores fingerprint, reported duration, AcoustID, and candidate
recording MBIDs with scores. Fingerprints are stable, so this is computed once
per file version.

Lookups batch multiple fingerprints per request within the 3 req/s ceiling,
with `meta=recordingids+releasegroupids`. **As built: no key ships.** The plan
here was to bundle an application key and let `ACOUSTID_KEY` override it;
instead the key is read from the environment with no default and the lookup
half is completely dark without one. Fingerprinting itself always runs, so a
key arriving later needs no re-scan.

Submitting fingerprints back to AcoustID stays off by default — it needs a user
key and is a data-sharing decision the user should make deliberately.

## Phase 4 — matching, with an ambiguity veto

Match units come from Phase 0's directory grouping.

Candidates are assembled from four sources: MBIDs already in the file tags;
release-groups reached from AcoustID recording matches; barcode or catalogue
number if tagged; and text search as the last resort.

**Every candidate is then fetched with `inc=recordings`.** Search rank is never
trusted. This is what makes case 2 tractable: two nights of one tour share a
setlist but every track differs by seconds to tens of seconds, independently,
so the duration vector discriminates decisively. Thirteen fetches costs
thirteen seconds at MusicBrainz's rate limit.

Scoring is beets-style. Per track: duration delta with a grace window, title
string distance, position agreement. Per album: penalties for track-count
mismatch, missing tracks, unmatched tracks, media type, country, and release
date delta. Normalised to a 0–1 distance.

**Two independent gates, both of which must pass to auto-apply.** First,
absolute quality: distance under roughly 0.10. Second, **separation**: the
runner-up must be clearly worse than the winner. If candidate #2 sits within a
small margin of #1, the match is rejected regardless of how good #1 looks. The
Madrid failure is exactly a separation failure, and a threshold on the winner
alone would have applied it. Both cut-offs are settable and want calibrating
against the real library before being frozen.

Outcomes are three-way, not two: **auto-apply**, **queue for review**, or
**route to `local`**. The evidence pattern of no fingerprint match, plus many
tightly-clustered text candidates, plus durations fitting none of them, is a
strong positive signal that the album is not in MusicBrainz — which is the
correct conclusion for the Amsterdam show, not a failure to be retried forever.

The `local` state means: pinned to no MusicBrainz entity, user metadata
authoritative, enrichment skips it entirely, the derived layer for that album is
dropped, and a disambiguation field carries what only the user knows —
`Down the Road Wherever Tour — 2019-05-XX, Amsterdam`.

Score and evidence persist in `match_candidates` / `match_decisions` so the app
can show *why* a release was chosen and so a user override is a first-class
decision rather than an edit the next enrichment pass overwrites.

The permanent negative cache goes away: failures get a retry timestamp with
backoff, so a release MusicBrainz ingests later is eventually found.

~~Once a release is confirmed, its media structure becomes the authority for
merging the sibling-folder multi-disc case Phase 0 left open.~~

**Deferred, not built.** Merging sibling folders means re-keying an album, and
re-keying orphans its plays, tags, playlists, favourites and cached art (see
`007_album_identity.sql`). This update's hard rule is that no code path changes
an existing `albumId`, so the merge cannot land inside the matcher as written.
Top-level `… CD1`/`… CD2` folders still read as separate albums; the
`CD1`/`Disc 2` *subfolder* case Phase 0 handles is unaffected. Picking this up
needs the id-remap machinery `cmd/aria/remap.go` used for Phase 0, driven by
the confirmed release's media structure — not a rename inside `matchOne`.

**Verification:** the Amsterdam album lands in `local` rather than matching
Madrid, and the review queue explains that thirteen candidates were
indistinguishable.

## Phase 5 — apply the corrections (database only)

**Overruled and rebuilt.** This section originally specified writing corrected
tags back into the files: `/music` remounted `:rw`, a `WRITE_TAGS=1` second
switch, a per-format tag vocabulary, a `tag_journal` for undo, and a dry-run
diff endpoint. The user cut file write-back from this update. `MUSIC_DIR` stays
read-only and nothing in Aria writes to it.

What survives is the *content* of the list — minus BPM and initial key, which
are out of scope entirely, and minus the tag-vocabulary and journal machinery,
which only existed because files are destructive. What replaces the destination
is the read-time overlay that already exists.

**Where corrections go.** `enrich_cache` is the derived layer, `edits` stays
human-only. A confirmed release (state `matched`, auto-applied or user-pinned —
never `review`) extends two blobs that were already there: `albumCache` gains
`album`/`albumArtist`/`year`, and `TrackCredits` gains
`title`/`trackNo`/`discNo`/`mbRecordingId`. Derived values are NOT written as
`edits` rows: `edits` is what the editor's ↺ resets away from and what "clear
all" deletes, so a machine writing there would make its own prior output
indistinguishable from the user's typing, and would show the user overrides
they never entered. The same convention already governs `label`/`date`/
`country`, which arrive derived and surface as `original`.

**Manual always wins, with no code.** `buildMergedTracks` already applies
enrich_cache first and `edits` last, so the precedence — file tags → derived
track blob → derived album blob → album edits → track edits — is the existing
merge order, not a new ownership check. Pinned by `TestCorrectionPrecedence`.

**The alignment, and the free bug fix.** Which local file is which release
track is recomputed from the matcher's own pure pairing (`bestPairing`) rather
than persisted. That removes `enrich.go`'s `if t.MBRecordingID == nil
{ continue }`, which meant credits only ever reached libraries already run
through Picard — §1.3's defect, fixed as a side effect.

**Provenance** is one object per entity, served as a third `source` key on
`GET /api/edits/{kind}/{key}` (additive; older clients read two keys and are
unaffected), built from `match_decisions` and null whenever nothing derived is
being applied. Per-field provenance was rejected: every corrected field on an
album came from the same release.

**Revert**, three levels, all reusing what exists: type the right value (it
becomes a manual edit and wins permanently); `PATCH /api/albums/{id}
{"state":"local"}`, which drops the album's derived rows immediately rather than
masking them and is offered as "Not in MusicBrainz — use my own tags" at the
bottom of the re-identify dialog; or pick a different release through the
existing `POST /api/album/{albumId}/reidentify`, which pins the decision.
Clearing `state` deletes the derived album row with no version marker, so the
next pass re-derives from scratch — the round trip is lossless.

**No `tag_journal` and no replacement table.** Nothing is overwritten, only
shadowed: the file tags stay in the `tracks` row and the manual edits stay in
`edits`, both underneath the derived layer, and the derived layer is refetchable
by definition. Undo already exists per field, per album and per library. The one
real gap is per-run undo ("that pass got 40 albums wrong"), whose upgrade is a
`batchId` column on `match_decisions` — not built until someone asks.

**No migration.** Both destination tables already exist and both changes are
JSON blob additions. The one real cost is `albumV` 3 → 4, which re-fetches every
album at MusicBrainz's 1 req/s.

Explicitly still out of scope: renaming or moving files. Track ids are
`sha1(path)` (`scanner.go:275`), so a rename churns every id and orphans plays,
tags, playlists and favourites. If file organisation is ever wanted, track
identity must move to Phase 2's decoded-audio MD5 first. Separate project.

**Why file write-back is still a known gap**, and what it would take, is
documented for users in `README.md` under "Metadata enrichment". It is a
deliberate deferral, not an oversight — do not resurrect it here as a plan.

## Phase 6 — the source graph

**MusicBrainz** remains the identity spine, now driven by a confirmed MBID.
**Cover Art Archive** — art including back and booklet images, no key.
**AcoustID** — covered in Phase 3.
**Discogs** — genre/style taxonomy, pressing and label detail; 60 req/min
authenticated, with CC0 monthly dumps as the documented escape hatch if rate
limits ever bite.
**Wikidata** — structured and keyless: birth/death, instruments, band
membership with dates, Commons images. Better than parsing prose for the facts
it covers; Wikipedia stays for bios, which the enricher already does well.
**ListenBrainz Labs** — open similar-recordings and similar-artists datasets
plus popularity, feeding mixes and radio.
**LRCLIB**, **Open Opus** and **Deezer** are already integrated and unchanged.
**fanart.tv** and **TheAudioDB** add artist backgrounds and logos behind
optional user-supplied keys.

Genre normalisation: keep the file's string in `genre_raw` and map onto the
MusicBrainz genre list plus Discogs styles as a multi-valued normalised field.
`internal/genres` is the natural home.

## Phase 7 — musical descriptors

**Cut by the user, not built.** No Essentia sidecar, no BPM, no key, no mood,
no danceability, and therefore no harmonic mixing anywhere in the app. Nothing
in the tree half-implements it: there is no descriptor column, no sidecar
contract and no disabled UI. The rest of this section is the design as it
stood, kept for whoever picks it up.

BPM, key, danceability and mood need real MIR; writing that in Go has a bad
expected value.

An optional `aria-analyze` sidecar (compose profile, off by default) runs
Essentia: `essentia_streaming_extractor_music` for rhythm, tonal and loudness
descriptors, plus TensorFlow models — Discogs-EffNet embeddings feeding the
400-genre classifier and the MTG-Jamendo mood and instrument models. Essentia's
own AcousticBrainz-era SVM classifiers are known-noisy; the TensorFlow models
are the ones worth running.

The process boundary is a licensing decision, not squeamishness: Essentia is
AGPL-3.0 and the MTG models are CC BY-NC-ND 4.0. A separate, optional,
unmodified image with attribution keeps Aria's binary and default image free of
both obligations.

Contract is thin — `POST /analyze {path}` returning JSON, results stored in
`track_audio`. Sidecar absent means descriptors absent; same degradation model
as missing ffmpeg for the transcode tiers.

**One spike first:** AcousticBrainz ended in 2022 but its dumps are still
published — roughly 7.5M submissions keyed by recording MBID covering BPM, key
and high-level mood/genre. Once Phase 4 supplies recording MBIDs, a join
prefills descriptors for the mainstream part of the library at zero compute.
Caveats: the high-level data is the noisy SVM output, long-tail coverage is
poor, and the dumps are large. Measure the hit rate on *this* library before
committing to hosting them. Local analysis always overrides.

## Phase 8 — what the accuracy buys

**Built, minus everything that depended on Phase 7.**

Smart-playlist predicates on ~~BPM, key,~~ loudness ~~, mood and instrument~~ —
`loudness` (LUFS), `dynamicRange` (LU), `sampleRate`, `bitsPerSample` and
`suspect`, each with the null rule that an unanalysed track fails every
comparison including `lt`. ~~Harmonic mixing by Camelot-wheel compatibility and
BPM proximity~~ — cut with Phase 7; there is no key to mix on. True duplicate
detection via decoded-audio MD5 (exact) and AcoustID (near-identical across
encodes), where today's dedup can only compare strings; `GET
/api/library/duplicates`, read-only, nothing is deleted.

Loudness normalisation at playback from the ReplayGain tags, **opt-in and off
by default**, with the setting stating plainly that applying gain in mpv costs
bit-perfect output — the project's stated non-negotiable. Users with a DAC that
handles it can decide for themselves.

A library health view: unmatched albums, low-separation matches, missing art,
suspect transcodes, clipping tracks, missing MBIDs. Accuracy work is only
credible when the remaining inaccuracy is visible. `GET /api/library/health`
plus `/settings/health`; low separation is banded at twice the matcher's own
`matchMinSeparation` setting rather than a second copy of the constant.

The near-duplicate half uses AcoustID's clustering rather than comparing
Chromaprint fingerprints pairwise: the ids are already stored, grouping on them
is one `GROUP BY`, and the alternative is an O(n²) popcount over 25,000
fingerprints to answer the same question. It goes dark without `ACOUSTID_KEY`,
which is indistinguishable from a library with no near-duplicates.

## 4. The four cases, traced

| Case | Fixed by | Mechanism |
|---|---|---|
| Essential Brahms split into four | Phase 0 | Directory grouping; `COMPILATION` → Various Artists |
| Amsterdam show matched to Madrid | Phase 0 + 4 | Two folders stay two albums; separation veto rejects thirteen clustered candidates; routes to `local` |
| "Barber, Bruch" not shown as Esther Yoo | Phase 1b | Credit split at `; `, performer chosen by role from `artist-rels` |
| Василий Петренко unreadable | Phase 1a | `locale=en` primary alias → Latin `sort-name` → transliteration |

Cases 1 and 4 are fixed by Phase 1 alone, which needs no new data source and no
new binary. Case 3 is fixed by Phase 0. Case 2 needs Phase 4, but Phase 0's
manual `local` flag makes it hand-fixable immediately.

## 5. Data model additions

**As built**, migrations 007-011. Four things this section originally planned
turned out wrong and are recorded here rather than quietly dropped.

`tracks` gains `legacyAlbumId` (007) — the pre-Phase-0 hash, so plays, tags,
playlists and favourites survive the identity change.
`track_audio` (008, 009) — integrated loudness, LRA, true peak, real codec,
sample rate, bit depth, channels, lossless, suspect, decoded-audio MD5,
analysedAt. **No BPM, key, scale or mood column**: Phase 7 was cut, so there is
nothing to store and no column pretending otherwise.
`track_fp` (010) — fingerprint, duration, acoustid, score, the raw AcoustID
results JSON, lookedUpAt, lookupError.
`match_decisions` (011) — state, reason, release MBID, release group MBID,
disambiguation, distance, separation, pinned, trackSig, attempts, decidedAt,
retryAfter, and the candidate evidence as a JSON array. **There is no
`match_candidates` table**: candidates are never queried across albums, so a
row-per-candidate table would only ever be selected by albumId and immediately
re-serialised into the JSON the review UI wants.

**Not on `albums`, deliberately.** `repo.Albums.Rebuild` runs `DELETE FROM
albums` after every scan, so a column there is erased by the next rescan and a
cascade there would drop every decision the first time the user hits Scan. The
machine's conclusion lives in `match_decisions`; the user's authority over the
same album (`state`, `locked`, `disambiguation`) lives in `edits` and always
wins. Same word, different authority — separate tables are what makes that
expressible.

**No `tracks.genre_raw`.** The raw tag never moved: `tracks.genre` is still the
file's own string, and the canonical multi-valued array is derived at read time
in `buildMergedTracks`. A second column would have to be kept in sync with the
first for no gain.

Latinised names are an `enrich_cache` concern, not new columns.

## 6. Non-goals

No local MusicBrainz mirror — 50+ GB to save 35 minutes of one-off wall clock.
No file renaming or reorganisation. No Essentia in the main image. No
reimplementation of Chromaprint or EBU R128 in Go. No writes to MUSIC_DIR at
all — corrections live in the database (Phase 5).
No Latinisation written to disk. No Spotify — that door is closed.

## 7. Sequencing

Phase 0 blocks everything and fixes one case outright. Phase 1 is independent
of it and fixes two more, using data already being fetched — so 0 and 1 can
land in parallel and between them clear three of the four reported failures.
Phases 2 and 3 are independent of each other and of the network for their
expensive parts. Phase 4 needs 3. Phase 5 needs 4 to be worth trusting. Phases
6 is an add-on once 4 exists (7 was cut). Phase 8 is fallout.

First four concrete steps, in order:

1. Run the split-cause query against the live DB —
   `SELECT albumId, albumArtist, album, COUNT(*), MIN(path) FROM tracks WHERE
   lower(album) LIKE '%essential brahms%' GROUP BY albumId;` — to confirm
   whether case 3 is the `ALBUMARTIST` fallback or tag-string variance, and to
   see the disk layout that Phase 0's grouping rule has to handle.
2. Ship Phase 1a. Smallest diff, most visible result, no schema change.
3. Add the single-invocation ffmpeg analysis pass and `track_audio`; run it over
   the real library and look at the numbers.
4. Add `fpcalc` and fingerprint the library, then measure the AcoustID hit rate.
   That number determines how ambitious Phase 4 can be, so it comes before any
   matching code is written.

---

### Sources

- [MusicBrainz WS/2](https://musicbrainz.org/doc/MusicBrainz_API) · [aliases](https://musicbrainz.org/doc/Aliases) · [classical style](https://musicbrainz.org/doc/Style/Classical)
- [AcousticBrainz: ending the project](https://blog.metabrainz.org/2022/02/16/acousticbrainz-making-a-hard-decision-to-end-the-project/) · [dumps](https://acousticbrainz.org/download)
- [Essentia](https://essentia.upf.edu/) · [music extractor](https://essentia.upf.edu/streaming_extractor_music.html) · [TensorFlow models](https://mtg.github.io/essentia-labs/news/tensorflow/2020/01/16/tensorflow-models-released/) · [Docker images](https://github.com/MTG/essentia-docker)
- [AcoustID / Chromaprint](https://acoustid.org/chromaprint) · [pyacoustid](https://github.com/beetbox/pyacoustid)
- [ffmpeg chromaprint muxer](http://underpop.online.fr/f/ffmpeg/help/chromaprint-1.htm.gz) · [wader/static-ffmpeg](https://github.com/wader/static-ffmpeg)
- [rsgain (Opus R128 handling)](https://github.com/complexlogic/rsgain) · [loudgain](https://github.com/Moonbase59/loudgain)
- [go-taglib](https://pkg.go.dev/go.senan.xyz/taglib)
- [Picard tag mapping](https://picard-docs.musicbrainz.org/en/latest/appendices/tag_mapping.html)
- [beets match configuration](https://beets.readthedocs.io/en/stable/reference/config.html)
- [Discogs dumps (CC0)](https://data.discogs.com/) · [API terms](https://support.discogs.com/hc/en-us/articles/360009334593-API-Terms-of-Use)
- [ListenBrainz API](https://listenbrainz.readthedocs.io/en/latest/users/api/metadata.html)
- [musicbrainz-docker](https://github.com/metabrainz/musicbrainz-docker)
- [Spotify API deprecations](https://developers.brizm.dev/blog/spotify-api-changes-2026/)
