# Aria

A self-hosted, Roon-style music system. One Go server in a container, one
Flutter app for macOS, Linux, and Android. The server indexes your library
into SQLite and streams the **original, untouched files** — no transcoding,
ever. The app plays through **libmpv** — native, gapless, bit-perfect; audio
never touches a browser engine.

## Server (container)

```sh
mkdir -p music        # or point it at your library
podman-compose up -d  # docker-compose works too
```

Up at `http://localhost:3001`. First boot scans `./music` into SQLite on the
`aria-data` volume; later boots rescan incrementally (only changed files are
re-read). Volume mounts use `:z` SELinux labels for Fedora-style hosts.

Updating to a new release:
`podman-compose pull && podman-compose up -d --force-recreate aria`
(library data lives on the `aria-data` volume and survives recreates).
Local dev builds: `docker compose up --build`.

- ~24 MB distroless image, static Go binary, non-root.
- Healthcheck built in (`/aria -healthcheck`); graceful shutdown on SIGTERM.
- Database: SQLite (WAL) at `/data/aria.db`; FTS5 powers search.

**Migrating from v1 (JSON index):** run the importer once against your old
data volume — `go run ./server/cmd/migrate-json` with `DATA_DIR` pointing at
the legacy files. Track/album IDs are unchanged (sha1, see below).

## App (Flutter)

```sh
cd app_flutter
flutter run -d linux      # or: macos, or an Android device
flutter build linux --release
```

Point it at your server URL on first launch (default `http://localhost:3000`).

Playback engine: libmpv is bundled inside the app on **macOS and Android**.
On **Linux**, bundle it into the build output with
`linux/bundle_libmpv.sh` (rootless — extracts distro RPMs into `bundle/lib`;
re-run after each `flutter build linux`; needs `patchelf`, or point
`PATCHELF=` at one). Alternatively install system libmpv
(`dnf install mpv-libs` / `apt install libmpv2`). Without either, the app
runs and says so, but won't play. For distributable Linux packaging, use
Flatpak rather than shipping the ffmpeg stack yourself.
Playback is a direct FFI binding to libmpv: gapless,
optional exclusive-mode output on desktop, and a format badge showing the
actual stream (e.g. FLAC 24/96). Android decodes losslessly but final output
is OS-managed; true bit-perfect there needs a USB DAC (Android 14+).

Features: album/artist/genre/composer browsing with filters, full-text
search, queue with persistence, playlists (manual + smart rules), hierarchical
tags with bulk ops, per-profile play counts and listening stats, synced
lyrics, metadata editing, radio and new-release shelves.

## API

Full spec: [`server/openapi.yaml`](server/openapi.yaml). Same `/api` paths and
shapes as v1, plus `GET /healthz`, `GET /api/events` (SSE scan/enrich
progress), and `limit`/`offset` on `GET /api/tracks`.

`id` = sha1 of the file path relative to `MUSIC_DIR`.
`albumId` = sha1 of `albumArtist + "\0" + album` (lowercased).

## Environment variables (server)

| Var         | Default  | Purpose                          |
| ----------- | -------- | -------------------------------- |
| `PORT`      | `3000`   | HTTP port                        |
| `MUSIC_DIR` | `/music` | library root (read-only is fine) |
| `DATA_DIR`  | `/data`  | SQLite db + cached art           |

Scanned extensions: flac, mp3, m4a, ogg, opus, wav, aiff, ape, wv, dsf.

## Metadata enrichment

After every scan a background pass over free/open APIs caches results in the
database (incremental, nothing re-fetched): **MusicBrainz** (credits,
identification, 1 req/s), **Cover Art Archive / Deezer** (missing art,
similar artists), **Wikipedia/Wikidata** (artist bios, photos, dates),
**Open Opus** (composer portraits, epochs), **LRCLIB** (synced lyrics, on
demand). No API keys. Corrections overlay file tags at read time; your files
are never modified.

## Development

```sh
cd server && go test ./...                  # server: unit + integration
cd app_flutter && flutter test              # app + widget tests
cd app_flutter/packages/aria_api && dart test           # client models
ARIA_E2E_URL=http://localhost:3903 dart test            # live contract tests
```
