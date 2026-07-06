# Aria v2 — Rebuild Plan (full rewrite)

## Current-state analysis

**Server** (`server/`, Node/Express): one 885-line `server.js` with ~50 routes covering
library, streaming, art, tags, playlists, profiles, edits, enrichment, stats, radio,
settings. All persistence is JSON files via a 15-line store (`index.json`,
`enrich.json`, tags/playlists/profiles/plays/settings). Scanner + enricher
(MusicBrainz, Wikipedia, Deezer, Open Opus, LRCLIB) are decent modules; the scanner is
single-threaded. Formats: flac, mp3, m4a, ogg, opus, wav, aiff, ape, wv, dsf.

**App** (`app/`, Electron): `ui/app.js` is a 3,565-line god file — the knowledge graph
confirms it: top god nodes (`$()`, `esc()`, `disp()`, `render()`) and four
low-cohesion communities (0.11–0.14) all live there. The one cohesive module is
`player.js` (mpv JSON-IPC engine, ffmpeg→aplay fallback) — bit-perfect native
playback, never the browser engine. That property is non-negotiable in v2.

**What breaks at scale:** JSON stores rewrite the whole file per mutation and load the
whole library into memory; `/api/tracks` returns everything unpaginated; no input
validation; single-threaded scanning; the UI is unsplittable.

## Decisions

Both ends are rewritten, so choices are greenfield-best, not migration-cheapest.

| Decision | Choice | Why |
|---|---|---|
| Server language | **Go** (1.24+) | Domain-proven for self-hosted media (Navidrome, gonic). Static binary, distroless ~30MB image, goroutine-pool scanner parses tags across all cores — the one *material* big-library win. Rust re-checked: no advantage for file I/O + SQLite workload. |
| HTTP layer | **Go stdlib `net/http`** | 1.22+ method routing kills the framework question; `http.ServeContent` gives correct Range/ETag streaming for free. |
| Database | **SQLite** via `modernc.org/sqlite` (pure Go, WAL, FTS5) | Real ACID DB in the container, no second container. One writer (scanner) + WAL readers is SQLite's sweet spot; Postgres pays off only with multiple writers/nodes. Plain SQL, embedded migrations, ~30-line migrator. |
| Tag parsing | **`sentriz/go-taglib`** (TagLib→WASM via wazero) | Full coverage of all 10 current formats incl. ape/wv/dsf, zero cgo, keeps the static binary. |
| API | **Clean v2, OpenAPI-first** + SSE for scan/enrich progress | No v1 compat burden since both ends are rewritten. Spec generates the Dart client — one source of truth. |
| App | **Flutter** (macOS, Linux, Android) | Mandated. |
| Playback | **Direct libmpv FFI binding** (~300 lines), binaries from `media_kit_libs_*` packages | Same engine as today's best path: native, gapless, `--audio-exclusive`, bit-perfect, format info for the UI badge. Owns the core competency; avoids media_kit's one-maintainer Dart layer while reusing its solved binary packaging. |
| State / routing | **Riverpod** + **go_router** | Current consensus; re-checked, no stronger alternative. |
| Monorepo tooling | Path-dependency packages, no melos | Three packages don't need a workspace manager. |

**Android bit-perfect caveat:** libmpv gives lossless decode everywhere, but Android's
mixer may resample at the OS layer. True bit-perfect on Android needs a USB DAC +
Android 14's bit-perfect USB path. Desktop is fully bit-perfect; Android is "lossless
decode, OS-managed output". OS ceiling, not an app choice.

## Target structure

```
server/                     # Go module
  cmd/aria/main.go          # boot: config, db open+migrate, scan-on-first-run, serve, graceful shutdown
  internal/
    api/                    # one file per route group: library.go, stream.go, art.go,
                            # tags.go, playlists.go, profiles.go, enrich.go, stats.go,
                            # radio.go, settings.go, events.go (SSE)
    db/                     # open, migrator; migrations/*.sql embedded via go:embed
    repo/                   # tracks.go, albums.go, tags.go, playlists.go, plays.go, ...
    scanner/                # concurrent walk + go-taglib parse, incremental (mtime skip),
                            # batched transactional inserts
    enrich/                 # musicbrainz.go, wikipedia.go, deezer.go, openopus.go, lrclib.go
    genres/
  openapi.yaml              # API source of truth
  migrate-json/             # one-shot: import legacy /data/*.json into SQLite

app_flutter/
  packages/
    aria_api/               # generated from openapi.yaml + thin hand-written wrapper
    aria_player/            # libmpv FFI: play/pause/seek/queue/gapless, engine+format info
  lib/
    core/                   # go_router, theme, server-connection provider
    widgets/                # shared components: AlbumCard, TrackRow, ArtistAvatar,
                            # FormatBadge, ContextMenu, FilterBar, Shelf/Grid — features
                            # compose these; no feature imports another feature's widgets
    features/
      library/              # albums, artists, genres, composers browse
      album/  artist/       # detail pages
      now_playing/          # transport, queue, lyrics
      playlists/            # incl. smart playlists/filters
      tags/  search/  stats/  profiles/  settings/
  linux/ macos/ android/
```

**Schema sketch:** `tracks`, `albums`, `artists`, `tags` + `tag_items`, `playlists` +
`playlist_tracks`, `plays`, `profiles`, `edits`, `enrich_cache(kind,key,json)`,
`settings(key,value)`, `radio`, plus FTS5 over track/album/artist names.
Track/album IDs stay sha1-based so existing enrichment data imports cleanly.

**Container:** multi-stage build → static binary in distroless/static. `/music:ro,z`
and `/data:z` volumes unchanged. Healthcheck on `/healthz`.

## Phases

1. **Go core** — module scaffold, SQLite + migrations + repos, concurrent incremental
   scanner, `openapi.yaml`, library/stream/art endpoints, `migrate-json` importer,
   Dockerfile (distroless). Verifiable: scan real library, stream a track with Range.
2. **Full API** — tags, playlists, profiles, plays/stats, radio, settings, edits,
   enrichment ports (all five sources), SSE progress, validation on every write,
   pagination, tests per route group.
3. **Flutter foundation** — scaffold app + `aria_api` (generated) + `aria_player`
   (libmpv FFI); server URL setup; album grid; tap-to-play. End-to-end spike proving
   bit-perfect playback on Linux/macOS/Android.
4. **Feature parity, in slices** — now-playing + queue → playlists + tags →
   smart filters + search (FTS5) → stats/profiles/enrichment UI → lyrics/radio.
   Each slice ships usable.
5. **Retire legacy** — delete `app/` (Electron) and Node server, README rewrite.

## Explicitly skipped

- Postgres / separate DB container — pays off only with concurrent writers or multiple app nodes; this system has neither. Ceiling: millions of tracks.
- Auth — LAN, single household, as today. Add a token check if it ever leaves the LAN.
- iOS/Windows/web targets — not requested; Flutter keeps the door open.
- Transcoding — antithetical to the product. Original bits only.
