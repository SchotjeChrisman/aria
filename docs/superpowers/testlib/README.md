# aria test server — artist-credits fix

A throwaway aria instance on port 3999 with a 10-album synthetic library, built
to prove the missing `artist-credits` in the MusicBrainz `inc=` set.

## Why synthetic

The files are 8 kHz mono sine tones with the **real track titles and real
durations** of ten real MusicBrainz releases (123 MB total). Nothing about this
fix touches audio; everything about it touches tags, durations and track
counts, which is exactly what is reproduced faithfully.

The tags are **deliberately imperfect in the ways real rips are** — tagging the
files with MusicBrainz's own truth would make every match trivial and test
nothing. `build_lib.py` records the specific lie per album in a `lie` field.

## The library

| album | difficulty it delivers | MB ID in tags |
| --- | --- | --- |
| `baseline-acdc` | control: tags agree with MB; its 15 release artist-rels are ALL production credits, which is how the dead `roleRank` was found | yes |
| `baseline-portishead` | control on the search path instead of the tag path | no |
| `classical-barber` | **the reported bug** — `;` split, zero relations, so `displayArtist` must fall back to credit order | yes |
| `classical-toscanini` | second `;` split, conductor rather than soloist as performer | yes |
| `trap-vivaldi` | the 2005 Decca Janine Jansen recording — MB holds **11** near-identical Jansen releases, so the artist signal *cannot* separate them and must not pretend to | no |
| `compilation-trainspotting` | Various Artists, 13 distinct track artists, empty-artist search fallback | no |
| `multidisc-wall` | 2 media / 26 tracks across CD1+CD2 folders — `discSegRE` folding before matching | yes |
| `nonlatin-utada` | original-script credit; must store raw, latinise only at display | yes |
| `selftitled-weezer94` + `-01` | identical album+artist tags, different tracklists — guards against false separation | no |

89% of the live library is Picard-tagged, so five albums carry
`MUSICBRAINZ_ALBUMID` (tag-seeded candidate) and five do not (search + score).
Withholding it from Barber is what first exposed that the album fails at
*search*, not scoring.

## Ground truth is computed, never asserted

`display_artist.py` is a line-by-line port of `server/internal/enrich/credits.go`.
It runs over the cached `shapes.json` to produce `expected.json`, which
`compare.py` reads. Expectations were hand-written once and were wrong — the
Vivaldi pick expected the wrong performer — so they are derived now.

Probing 23 releases (13 pop, 10 classical) found **zero** with a performance-role
relation at release level: MusicBrainz keeps conductor/orchestra/soloist rels on
RECORDINGS. `displayArtist` reads release-level rels only, so `roleRank` never
fires in practice and the answer always comes from artist-credit ORDER. That is
still correct, because MB convention lists the soloist first.

## Use

    ./testserver.sh build            # rebuild from the working tree
    ./testserver.sh run before       # reset + scan + enrich + snapshot
    ...apply the fix...
    ./testserver.sh build
    ./testserver.sh run after
    python3 compare.py snap-before.json snap-after.json

`compare.py` exits non-zero until the fix lands. Against the unfixed baseline it
reports **28 passed, 10 failed** — the 10 being the three dead classical splits
and the missing MB album artist.

`FPCALC_PATH` points at a nonexistent file on purpose: with no fingerprinter and
no `ACOUSTID_KEY`, the AcoustID path stays dark and the tag+search matcher is
what gets tested. `SCAN_INTERVAL=0` disables the background cadence so runs are
deterministic.

## Rebuilding from scratch

    python3 probe.py search "Artist" "Album"   # find candidates
    python3 build_lib.py testlib               # regenerate files + tags

`shapes.json` caches the probed MusicBrainz data so a rebuild costs no requests.
