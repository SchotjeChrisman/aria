# Aria

A self-hosted, Roon-style music system. One Go server in a container, one
Flutter app for macOS, Linux, and Android. The server indexes your library
into SQLite and streams the **original, untouched files** bit-perfect by
default; optional **high/low Opus tiers** (~192k/~96k, from a bundled static
ffmpeg) are there for constrained networks. The app plays through **libmpv** —
native, gapless, bit-perfect; audio never touches a browser engine.

## Server (container)

```sh
# edit compose.yaml: point the music volume at your library
podman-compose up -d  # docker-compose works too
```

The shipped `compose.yaml` mounts a host path read-only at `/music` — change
that line to your library before first boot. Up at `http://localhost:3001`
(the container listens on 3000; compose publishes it on 3001). First boot scans
the music mount into SQLite on the `aria-data` volume; later boots rescan
incrementally (only changed files are re-read). The `aria-data` volume uses a
`:z` SELinux label for Fedora-style hosts; NFS shares can't be relabeled, so
grant access with the `virt_use_nfs` boolean instead.

Local dev builds: `docker compose up --build`.

### Updating

`:latest` only moves on stable (non-prerelease) releases, so it is a safe
auto-update target. Library data lives on the `aria-data` volume and survives
recreates. Two automatic paths:

- **Podman (rootless):** compose stays the single source of truth, but
  `podman auto-update` can only restart a container owned by a real systemd
  unit — so run the project through the template unit
  [`deploy/podman-compose@.service`](deploy/podman-compose@.service) (put your
  `compose.yaml` in `~/podman/<name>/`, then
  `systemctl --user enable --now podman-compose@<name>`). The compose service
  must carry the `io.containers.autoupdate: registry` label (already set
  below), and the unit runs with `--in-pod=false` so the container — not a pod
  — is the auto-update target. Then enable the timer:
  `systemctl --user enable --now podman-auto-update.timer`; for 15-minute
  checks instead of daily, install
  [`deploy/podman-auto-update-override.conf`](deploy/podman-auto-update-override.conf).
- **Docker:** start the bundled watchtower service:
  `docker compose --profile watchtower up -d` (checks hourly, updates only
  labeled containers, prunes old images).

Manual fallback:
`podman-compose pull && podman-compose up -d --force-recreate aria`.

- Distroless image, static Go binary + bundled static ffmpeg, non-root.
- Healthcheck built in (`/aria -healthcheck`); graceful shutdown on SIGTERM.
- Database: SQLite (WAL) at `/data/aria.db`; FTS5 powers search.

**Migrating from v1 (JSON index):** run the importer once against your old
data volume — `go run ./server/cmd/migrate-json` with `DATA_DIR` pointing at
the legacy files. Track/album IDs are unchanged (sha1, see below).

## App (Flutter)

```sh
cd app_flutter
flutter run -d linux      # or: macos, ios, or an Android device
flutter build linux --release
```

Point it at your server URL on first launch (default `http://localhost:3000`;
the bundled container publishes on `:3001`).

### Installing a release build

Every release carries `aria-linux-x64.tar.gz`, `aria-linux-x86_64.AppImage`,
`aria-linux-x64.flatpak`, `aria-macos.zip`, `aria-android.apk` and
`aria-ios-unsigned.ipa`.

- **Linux — AppImage:** `chmod +x aria-linux-x86_64.AppImage && ./aria-…`.
  Self-contained for libmpv; GTK and the graphics stack come from the host, and
  glibc must be at least the build runner's. Older distros: use the flatpak.
- **macOS:** unless the repo has Apple signing secrets configured, the `.app`
  is ad-hoc signed but not notarized (that needs a paid Developer account), so
  macOS quarantines a browser download and refuses to open it — *"Apple could
  not verify 'aria' is free of malware"*. There is no Control-click bypass any
  more (removed in macOS 15). Drag `aria.app` to `/Applications`, then run once:

  ```sh
  xattr -dr com.apple.quarantine /Applications/aria.app
  ```

  Downloading with `gh release download` or `curl` never sets the quarantine
  flag, so no command is needed that way.
- **iOS:** the `.ipa` is unsigned and cannot be installed as-is. iOS has no
  Developer ID equivalent — an installable build needs an Apple Distribution
  certificate plus a provisioning profile naming each device, which no public
  repo can ship. Re-sign it yourself with [AltStore] or [Sideloadly]; a free
  Apple ID works but the signature expires every 7 days.

[AltStore]: https://altstore.io
[Sideloadly]: https://sideloadly.io

Playback engine: libmpv is bundled inside the app on **macOS, iOS and
Android**. On **Linux**, bundle it into the build output with
`linux/bundle_libmpv.sh` (rootless — extracts distro RPMs into `bundle/lib`;
re-run after each `flutter build linux`; needs `patchelf`, or point
`PATCHELF=` at one). Alternatively install system libmpv
(`dnf install mpv-libs` / `apt install libmpv2`). Without either, the app
runs and says so, but won't play. For distributable Linux packaging, use
[`packaging/appimage/build.sh`](packaging/appimage/build.sh) (apt-based, copies
the system libmpv and its deps into the AppDir) or the Flatpak manifest —
don't ship the ffmpeg stack by hand.
Playback is a direct FFI binding to libmpv: gapless,
optional exclusive-mode output on desktop, and a format badge showing the
actual stream (e.g. FLAC 24/96). A streaming-quality setting picks original vs.
high/low Opus per session (falls back to original if the server has no ffmpeg). Android decodes losslessly but final output
is OS-managed; true bit-perfect there needs a USB DAC (Android 14+).

Features: album/artist/genre/composer browsing with filters, full-text
search, queue with persistence, playlists (manual + smart rules), hierarchical
tags with bulk ops, per-profile play counts and listening stats, synced
lyrics, metadata editing, radio and new-release shelves. Also opt-in ReplayGain
2.0 loudness normalisation, **off by default** — turning it on applies a digital
gain inside the player, which is DSP: the output is no longer bit-perfect, and
the Now Playing signal path says so.

## API

Full spec: [`server/openapi.yaml`](server/openapi.yaml). Same `/api` paths and
shapes as v1, plus `GET /healthz`, `GET /api/events` (SSE scan/enrich/analyze
progress), `POST /api/analyze` + `GET /api/analyze/status` (the background
loudness measurement that feeds the ReplayGain figures on `GET /api/tracks`;
501 when the server has no ffmpeg), and `limit`/`offset` on `GET /api/tracks`.

`id` = sha1 of the file path relative to `MUSIC_DIR`.
`albumId` = sha1 of `album directory + "\0" + album title` (lowercased) — the
directory being the file's folder with a disc subfolder folded into its parent,
and the album artist standing in for the directory at library root. A disc
subfolder is one named for a disc label and a numeral — `CD1`, `Disc 2`, and the
MusicBrainz medium formats a tagger like Picard writes instead (`Digital Media
01`, `Hybrid SACD 2`, `Vinyl 1`). The numeral is required, so `Vinyl Days` and
`Discography` stay albums of their own.
Identity comes from where the files live, not from what the tags say, so two
identically-tagged concerts in two folders stay two albums.

## Environment variables (server)

| Var                 | Default  | Purpose                                    |
| ------------------- | -------- | ------------------------------------------ |
| `PORT`              | `3000`   | HTTP port                                  |
| `MUSIC_DIR`         | `/music` | library root (read-only is fine)           |
| `DATA_DIR`          | `/data`  | SQLite db + cached art + transcode cache   |
| `FFMPEG_PATH`       | `/ffmpeg`| ffmpeg for Opus tiers and loudness analysis; both skipped if missing |
| `FPCALC_PATH`       | `/fpcalc`| fpcalc for AcoustID fingerprinting; skipped if missing or unrunnable |
| `ACOUSTID_KEY`      | *(none)* | AcoustID lookups; without it fingerprints are computed but never looked up |
| `DISCOGS_TOKEN`     | *(none)* | Discogs genre/style/label/catalogue-number enrichment; skipped entirely if missing |
| `TRANSCODE_CACHE_MB`| `5000`   | on-disk Opus cache budget under `DATA_DIR` |
| `SCAN_INTERVAL`     | `1h`     | how often the library is walked for new/changed files; `0` disables |
| `FULL_SCAN_INTERVAL`| `24h`    | how often the enrich/fingerprint/analysis passes run even when nothing changed; `0` disables |

The two scan cadences do the same walk — the difference is what follows it. The
hourly one only runs the enrichment passes when the walk actually found new or
changed files, so a quiet library costs one directory walk and nothing else. The
daily one runs them regardless, which is what lets already-enriched albums pick
up new metadata: the enricher's own TTLs (discography 7 days, artist popularity
30 days) can only expire on a pass that reaches them. Both accept any
`time.ParseDuration` string (`90m`, `6h`); an unparseable value logs and falls
back to the default rather than silently disabling the scan.

Scanned extensions: flac, mp3, m4a, m4b, ogg, oga, opus, spx, wav, aiff, aif,
aifc, afc, ape, wv, dsf, wma, tta, shn, mpc. Deliberately excluded: dff/dsdiff
(no ffmpeg demuxer exists — taglib can read the tags but nothing can play it),
tracker modules (need libopenmpt), mp4/m4v (video), m4p (DRM).
`lossless` is decided by the codec, not the container, so an ADPCM wav, a
compressed AIFF-C, AAC-in-m4a and lossy WMA all report false.

## Metadata enrichment

After every scan a background pass over free/open APIs caches results in the
database (incremental, nothing re-fetched): **MusicBrainz** (credits,
identification, community-voted genre tags, 1 req/s), **Cover Art Archive /
Deezer** (missing art, similar artists), **Wikipedia** (artist bios and
photos), **Wikidata** (which instruments a person plays, and birth/death dates
where MusicBrainz has none), **ListenBrainz** (similar artists Deezer's
editorial graph misses, and the globally-listened recordings that rank your
daily mix), **Open Opus** (composer portraits, epochs), **LRCLIB** (synced
lyrics, on demand), and — only with a token, see below — **Discogs**
(styles, label, catalogue number). Corrections overlay file tags at read time;
your files are never modified.

### Genres

Your file's `GENRE` tag is never touched. It is *decomposed* into a canonical,
two-level taxonomy for browsing and for smart playlists, and the enrichment
pass adds to that derived list: MusicBrainz's community-voted genre tags for
the release group (only those with at least two votes, so one person's opinion
does not become a genre), plus Discogs' genres and styles when a token is set.

Two things follow. Albums with no `GENRE` tag at all — bandcamp downloads,
classical rips — stop being invisible in genre browse. And an album tagged only
"Rock" can now also appear under Alternative Rock and Art Rock. The taxonomy is
a *closed* set, so no source can ever mint a new top-level genre; anything
unrecognised is folded into its parent genre or dropped.

### Discogs (optional, needs a free token)

Discogs adds what MusicBrainz does not carry: its fine-grained *styles*
(Euro-Disco, Symphonic Rock), and the label and catalogue number of the actual
pressing — which show up on the album page's facts line, and where MusicBrainz
has no label at all, fill that in too.

**Aria ships no key.** Get one free: sign in at <https://www.discogs.com>, go
to Settings → Developers → *Generate new token*, and put the personal access
token in the server environment as `DISCOGS_TOKEN`. No app registration, no
OAuth. With no token the Discogs half of the pass is completely dark and
nothing is logged about it; set it later and the next pass fills in every album
that was already matched, no re-scan needed.

The release is looked up by the Discogs id MusicBrainz already links to, so
nothing is fuzzy-matched against a second database. One caveat worth knowing:
a *mistyped* token does not produce an error — Discogs quietly serves lookups
at the slower anonymous rate instead — so if enrichment seems slow, check the
token.

### Corrections live in the database, not in your files

Every correction — a fixed album title, the real track order, the performer who
should be the album artist instead of the composer — is stored in the database
and layered over the file's own tags when the library is read. `MUSIC_DIR` is
mounted read-only and nothing in Aria writes to it.

The layers, weakest first: **file tags** → **derived** (MusicBrainz and the
other open sources) → **your edits** (the metadata editor). A value you typed
yourself always wins, and survives every later re-identification: nothing you
enter by hand is ever overwritten by an automatic pass. The editor shows where a
value came from, and an album that MusicBrainz gets wrong can be marked "not in
MusicBrainz — use my own tags", which drops the derived data for that album
entirely.

### Why writing tags back to the files will eventually be wanted

The database is Aria's, not yours. Every other player — your car, a phone
plugged into a hire car, foobar2000, Plex, whatever you use in ten years — reads
the files, so a library that is only correct inside Aria is only correct inside
Aria. And `DATA_DIR/aria.db` is not portable: copy the music to another machine
and the corrections do not follow, and rebuilding the database from scratch
loses them unless every one can be re-derived — which the ones you typed by
hand, by definition, cannot.

Writing them back needs four things, none of them small. A writable mount plus a
second explicit opt-in, because the failure mode is corrupting the master copy
of a library that may not be backed up. A per-format tag-vocabulary mapping:
ID3v2.4, Vorbis comments, MP4 atoms and APEv2 all spell the same field
differently, and Picard's mapping table is the standard to follow. A verified
answer to whether the bundled taglib really writes ape, wv and dsf rather than
silently doing nothing. And a journal of each file's previous tags — unlike a
database overlay, a file write destroys the only copy of what was there before,
so undo has to be built rather than inherited.

That is a project of its own with a genuinely destructive failure mode, and its
value depends entirely on the corrections being right first. So the
identification work came first and the writing did not. It is a known gap, not
an oversight.

### Audio fingerprinting (AcoustID)

A separate background pass runs `fpcalc` over each file (~64 ms each) and stores
a Chromaprint fingerprint, then asks **AcoustID** which MusicBrainz recordings
it matches. The fingerprints are useful on their own — they identify duplicates
across different encodes of the same recording — so the local half always runs.

The lookup half needs an application key, which **Aria does not ship**: get one
free at <https://acoustid.org/new-application> (sign in with a MusicBrainz
account) and put it in the server environment as `ACOUSTID_KEY`. With no key the
lookup half is completely dark and nothing is logged about it; set the key later
and the next pass looks up everything already fingerprinted, no re-scan needed.

Fingerprints, decoded-audio MD5s and lookup results all live in the database.
`MUSIC_DIR` is never written to — mount it read-only.

### Album matching

Before it enriches anything, the pass decides *which MusicBrainz release each
album actually is*, rather than trusting the top search hit. Candidates come
from MBIDs already in your tags, from the release groups AcoustID voted for, and
from a text search; each survivor of a track-count prefilter is fetched in full
and scored against your files on title, duration, track order, disc count and
year. The result is a distance from 0 (identical) to 1.

Two independent gates must both pass before a release is applied:

- **quality** — the best candidate's distance is at most `matchMaxDistance`
  (default `0.10`);
- **separation** — the best candidate *in a different release group* is at least
  `matchMinSeparation` worse (default `0.25`).

The second gate is the point. Thirteen nights of one tour all score about the
same, and a threshold on the winner alone happily picks Madrid for a recording
of the Amsterdam show. Deluxe and remastered editions share a release group, so
they never trip it — only the pressing is ambiguous there, not the album.

Every album ends in one of three states, readable at `GET /api/match/review`:

| state     | meaning                                                              |
| --------- | -------------------------------------------------------------------- |
| `matched` | both gates passed; enrichment anchors on this release                 |
| `review`  | plausible but ambiguous or weak; no MBID applied, retried on backoff  |
| `local`   | no MusicBrainz entity; enrichment skips the album entirely            |

Choosing a release yourself (`POST /api/album/{albumId}/reidentify`) *pins* it:
the matcher never argues with it again. Setting `state` or `locked` in the album
edits is likewise permanent — a state you set outranks the one the server
derived. A machine-set `local` is only a conclusion, so it is retried later
(24 h, doubling to 30 days) in case MusicBrainz ingests the release.

Both thresholds are settable via `POST /api/settings` and want calibrating
against your own library before being trusted. Matching a fresh 2,000-album
library costs roughly two hours of wall clock, because MusicBrainz allows one
request per second; the pass is resumable (each decision is stored before the
next album starts) and a decided album costs zero requests on every later pass.
Nothing is written to `MUSIC_DIR` — every correction lives in the database.

### Library health and duplicates

**Settings → Library → Library health** is the honest report on what all of the
above could not settle: unidentified albums, matches where a rival release
scored nearly as well, missing artwork, albums with no MusicBrainz ID, suspect
files, clipping tracks and anything not yet analysed. Every row opens the album
it is about. Pure read — `GET /api/library/health` runs no job and writes
nothing.

The same page lists duplicates (`GET /api/library/duplicates`). **Exact** groups
have byte-identical decoded audio: same master, different tags, different
filename, different container — the MD5 ignores all of it. The other groups
share an AcoustID, which is the same recording through a different encoder (a
FLAC and its MP3), and are not automatically unwanted — one recording
legitimately appears on both an album and a compilation. Nothing is deleted;
Aria shows you the copies and you decide. The near-duplicate half needs
`ACOUSTID_KEY`; without it only exact groups appear.

Both need the analysis pass to have run, which happens automatically after a
scan.

### Smart playlists on measured quality

Alongside the tag-based rules, smart playlists can filter on what the decoder
actually measured: minimum sample rate, minimum bit depth, loudness in LUFS
("louder than −14" finds the loudness-war masters), dynamic range in LU
("over 8 LU" finds the ones that survived it), and suspect files (exclude
transcodes, or list only those).

A track the analysis pass has not reached yet matches **none** of these,
including the "quieter than" and "less than" directions — an unmeasured track is
not a quiet one, and a playlist of "everything below −20 LUFS" must not silently
mean "everything not yet analysed".

## Development

```sh
cd server && go test ./...                  # server: unit + integration
cd app_flutter && flutter test              # app + widget tests
cd app_flutter/packages/aria_api && dart test           # client models
ARIA_E2E_URL=http://localhost:3903 dart test            # live contract tests
```
