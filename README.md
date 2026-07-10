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
flutter run -d linux      # or: macos, or an Android device
flutter build linux --release
```

Point it at your server URL on first launch (default `http://localhost:3000`;
the bundled container publishes on `:3001`).

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
actual stream (e.g. FLAC 24/96). A streaming-quality setting picks original vs.
high/low Opus per session (falls back to original if the server has no ffmpeg). Android decodes losslessly but final output
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

| Var                 | Default  | Purpose                                    |
| ------------------- | -------- | ------------------------------------------ |
| `PORT`              | `3000`   | HTTP port                                  |
| `MUSIC_DIR`         | `/music` | library root (read-only is fine)           |
| `DATA_DIR`          | `/data`  | SQLite db + cached art + transcode cache   |
| `FFMPEG_PATH`       | `/ffmpeg`| ffmpeg for Opus tiers; skipped if missing  |
| `TRANSCODE_CACHE_MB`| `5000`   | on-disk Opus cache budget under `DATA_DIR` |

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
