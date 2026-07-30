# Restoring the MusicBrainz artist credit

2026-07-30

## The bug

Neither MusicBrainz release lookup asked for `artist-credits` in its `inc=` set:

- `internal/enrich/match.go` — `recordings+labels+release-groups`
- `internal/enrich/enrich.go` — `recordings+recording-level-rels+work-rels+work-level-rels+artist-rels`

Without it MusicBrainz answers `"artist-credit": null`, so `rel.ArtistCredit` was empty on
every release aria has ever fetched. One omission killed three features, all confirmed dead on
the live 584-album library before any change was made:

1. **The matcher's artist distance.** `candidateOf` sets `Artist: joinCredit(rel.ArtistCredit)`,
   which was always `""`. All 2222 stored candidates scored `artist: 1` — the maximum — including
   perfect matches: AC/DC's *Back in Black* scored 0 on album, trackTitle, trackLength and year,
   and its entire 0.043 distance was the artist penalty it could not avoid. Every album in the
   library was matched on title and tracklist alone, and the review screen's `why` breakdown
   always blamed the artist because it was the one component that never varied.
2. **`albumCache.AlbumArtist`.** Written from the same empty credit, so dropped by `omitempty`.
   0 of 584 album cache entries had one.
3. **The classical composer/performer split.** `displayArtist()` needs the `; ` joinphrase to
   find composers; with no credit there is nothing to split, so `len(comps) > 0` was never true.
   0 of 584 entries had a `displayArtist`. This was the reported symptom: *Barber, Bruch* fell
   back to the file tag `ALBUMARTIST=Samuel Barber`, a composer, instead of the performer.

`TestBuildMergedTracksDisplay` passed throughout because its fixture hand-writes the cache blob
the enricher never actually produced.

## The fix

Add `artist-credits` to both `inc=` sets. Everything below exists to make that reach data.

- `mbArtistCredit.Artist` gains `Type`, which identifies ensembles.
- `match.go`'s verify loop keeps the search hit's artist when the full re-fetch has none,
  mirroring the `RGMbid` fallback beside it — search hits carry `artist-credit` natively.
- `displayArtist` returns an ordered performer list alongside the lead and the composers.
- `albumCache` gains `Performers` (raw script) and `DzContributors`; `albumV` 4 → 5 re-enriches.
- A one-shot sentinel clears every unpinned `match_decisions` row so all 584 albums re-decide
  with a live artist signal. Pinned rows survive; `edits` is untouched, so a user's
  "use my own tags" answer keeps its override while the album re-decides underneath it.

## Restoring the signal naively breaks classical matching

Turning the artist distance back on regressed a *correct* classical match out of `matched`.
`candidate.Artist` is the whole credit joined, and `strDist` is plain normalised Levenshtein
with no containment, so:

    tag "Ludwig van Beethoven"  vs  "Beethoven; Arturo Toscanini"  ->  0.85

The album's total distance improved (0.0779 -> 0.0659) but its separation fell from 0.2517 to
0.1742, under the 0.25 gate, and it became `low-separation` review. That cascades: a `review`
album gets no MBID, so no enrichment, so no `displayArtist` — the feature this change exists to
deliver silently stops applying to exactly the albums that need it.

The cause is structural, not a tuning problem. MusicBrainz files classical as
`composers; performers`, and a rip's ALBUMARTIST names ONE side — Picard writes the composer, a
streaming-shaped tagger writes the performer. Comparing against the joined string penalises both
conventions for not being the other.

`artistDist` therefore takes the best of the joined credit and each credited artist on its own,
with `candidate.ArtistNames` carrying both spellings of every credit: the artist's own name and
the name this release credited them under. They differ constantly — the credit reads `Barber`
where the artist is `Samuel Barber` — and the tag can hold either. The same shape covers
`Artist feat. Other` tagged as plain `Artist`, and collaborations tagged with either partner.

The field is additive, so candidates persisted before it existed still score off the joined
string exactly as they did.

## Ordering: the Qobuz convention

For a release whose credit contains a `;` joinphrase, the album-header list is

    [lead performer] + [ensembles among the rest] + [remaining people]

where an ensemble is `artist.Type` in {Orchestra, Choir, Chorus, Group}. For `ec17a59b` that
gives **Esther Yoo · Royal Philharmonic Orchestra · Vasily Petrenko** — the orchestra ahead of
the conductor, which is what Qobuz displays and what Deezer independently returns.

Only the album page renders the list. Grids, search and now-playing keep the scalar
`albumArtist`, which album grouping and sorting also key on; long classical credits truncate
badly in tiles.

### Empirical note: `roleRank` never fires

Across 23 probed releases — 13 pop, 10 classical including Karajan and the Berliner
Philharmoniker — **zero** carried a performance-role relation at release level. MusicBrainz
keeps conductor, soloist and orchestra relations on RECORDINGS, and `displayArtist(rel)` reads
`rel.Relations`. AC/DC's 15 release-level artist relations are all production credits (art
direction, engineer, mastering, photography), every one ignored by `roleOf`.

So the ranking is correct but effectively dead, and in practice the lead is the first performer
credit and the order comes from credit order plus `artist.Type`. It stays because a release that
does carry the relations must still be ordered by them, and `creditsByRecording` shares the
classifier.

## Deezer as a supplement

Deezer is keyed on the **lead performer**, never on the file's `ALBUMARTIST`. Verified: keyed on
`Samuel Barber` it confidently returns a Gregorio Allegri record by The Sixteen, and Jansen's
*Four Seasons* resolves to a budget recording by The Royal Festival Orchestra — wrong credits,
no error. A guard therefore only trusts an album that credits someone MusicBrainz also lists as
a performer; it immediately caught Deezer answering a Trainspotting query with *T2 Trainspotting
— The Complete Fantasy Playlist*.

Deezer labels every contributor `"Main"` even for classical, so only the ordered names are
useful. It adds `NBC Symphony Orchestra` to the Toscanini album, which MusicBrainz's credit omits.

### Three merge hazards, all verified against real data

The merge runs at **display time** in `library.go`, not in the enricher, because the only thing
that makes the two sources comparable is the Latin substitution — itself a display step whose
map grows every time the names phase resolves another spelling.

1. **Double-listing across the latin boundary.** MusicBrainz has `Василий Петренко`, Deezer has
   `Vasily Petrenko`. If any performer is still unresolved the supplement is skipped wholesale
   for that album; the names phase resolves it and the next build merges cleanly. Self-healing,
   and never a visible duplicate.
2. **Composer leak.** `Antonio Vivaldi` must not enter the Jansen performer list. Filtered
   because MusicBrainz's own `;` split already said which side of the credit he sits on.
3. **Dedup key mismatch.** `contributorsAgree` accepts a Deezer list using `enrich.norm()`, which
   deletes apostrophes and strips a leading `the `. The merge originally deduped on
   `strings.ToLower`, a *weaker* key — so exactly the pairs the agreement check waved through
   were appended twice: `Academy of St. Martin in the Fields` / `Academy of St Martin in the
   Fields`, straight versus curly apostrophes, `The Royal Philharmonic Orchestra` / `Royal
   Philharmonic Orchestra`. `normName` mirrors `enrich.norm` deliberately. It is not `normTitle`,
   which strips edition markers — right for a release title, wrong for an ensemble.

## Art flag recovery

`persist()` drops an album's cache entry whenever its decision changes, and the sentinel makes
that happen for every unpinned album at once. `enrichAlbum` then rebuilds the blob from the zero
value with `Art=false`, while `<id>.api.jpg` is still on disk — so the fetch is skipped (the file
exists), `a.Art` is never re-set, `artByAlbum` loses the album and the cover renders as a
placeholder. Permanently: the V marker stops the album being revisited and the file stops the
fetch re-arming.

The art flag is now recovered from disk. The live library has **0** `.api.jpg` files out of 1190,
so this had no blast radius there — it is latent, and cheap to close.

## Browsable credited artists

`artistsProvider` bucketed solely by `displayArtist(t)`, so an orchestra had a working artist page
nothing could navigate to — `artist/providers.dart` and `artist_discography.dart` already resolve
conductor, orchestra and performer credits. It now also buckets those names, with a **≥2 distinct
albums** threshold for names that are not already album artists: the live library holds 2416
distinct credited names against 157 tagged album artists, so an unfiltered merge buries the list.
The threshold yields roughly 649 additions.

Side effect, accepted: `ArtistEntry.albumIds` is now the union of fronted and credited albums, so
an existing artist's "N albums" subtitle and the "most albums" sort count appearances too.

## What no source provides

Per-person role labels for *Barber, Bruch*. MusicBrainz has zero artist relations on the release,
the release group and every recording; the release group holds only this one release. The files
carry only Picard's IDs. There is no Discogs url-rel, so the existing Discogs client cannot reach
it. Deezer says `"Main"` for everyone. Only the AllMusic and Presto links MusicBrainz points at
carry "Violin – Esther Yoo", and neither offers an API.

## Test harness

`docs/superpowers/testlib/` holds a synthetic 10-album library built from real MusicBrainz
releases — real track titles and durations as 8 kHz sine tones — with deliberately imperfect
tags. Ground truth is computed by `display_artist.py`, a port of `credits.go`, never asserted by
hand: the first version expected the wrong Vivaldi performer.
