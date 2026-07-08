# Spec: data-usage settings, offline downloads, usage/debug logging, container auto-update

Date: 2026-07-08. Scope: three features + one deployment fix. Design follows existing
codebase conventions (see "Established facts" at the bottom — implementers must read it).

## 1. Logging (implement FIRST — downloads and settings instrument through it)

### Server

- **Access log middleware**: in `server/internal/api/api.go`, wrap the mux (inside the
  existing gzip wrapper chain) with a request logger: `log.Printf("http: %s %s %d %s", method,
  path, status, duration)` using a small statusRecorder ResponseWriter. Skip `/healthz`.
  For `/api/events` (SSE, lives forever) log on connect instead of completion.
- **Client log ingestion**:
  - Migration `server/internal/db/migrations/003_client_logs.sql`:
    `client_logs(id INTEGER PRIMARY KEY, device TEXT NOT NULL, ts TEXT NOT NULL, level TEXT NOT NULL, tag TEXT NOT NULL, msg TEXT NOT NULL, extra TEXT, receivedAt TEXT NOT NULL)` + index on `ts`.
  - `server/internal/repo/logs.go`: `Logs` repo — `InsertBatch(ctx, device string, entries)`,
    `List(ctx, limit int, level, device string)`, `Prune(ctx)` (delete rows older than 30 days
    AND keep at most 200_000 rows). Repo style: struct{db}, ctx everywhere, `?` placeholders.
  - `server/internal/api/logs.go`: `POST /api/logs` body `{device: string, entries: [{ts, level, tag, msg, extra?}]}`.
    NOTE: the shared readJSON caps bodies at 32KiB — this endpoint needs its own decoder with a
    1MiB `http.MaxBytesReader`. Validate device + non-empty entries; cap 1000 entries/request.
    Insert batch, opportunistically Prune (e.g. every call is fine, it's cheap with the index),
    return `{"stored": n}`. `GET /api/logs?limit=200&level=&device=` returns recent rows
    (default limit 200, max 2000) for debugging. Register via the `init(){register(...)}` pattern.
    Add `Logs` repo to Deps + NewDeps. Update `server/openapi.yaml`.
  - Tests: `logs_test.go` following `eq_test.go` conventions (real sqlite in t.TempDir, httptest).

### App

- New dep: `path_provider` (the one defensible new dep for file storage).
- `lib/core/log.dart`: hand-rolled logger (no logging package). API:
  `Log.d/i/w/e(String tag, String msg, [Object? extra])`. Behavior:
  - In-memory ring buffer of last 500 entries (for the debug screen).
  - Appends NDJSON lines `{ts, level, tag, msg, extra?}` to
    `<app-support>/logs/aria.ndjson` via a serialized write queue (async, never blocks callers).
    Rotate at 2MB: rename to `aria.1.ndjson` (replacing any previous), start fresh.
  - Initialized in `main()` before `runApp` (needs the support dir); before init, entries go to
    the ring buffer only. Wire `FlutterError.onError` and `PlatformDispatcher.instance.onError`
    to `Log.e` (use PlatformDispatcher.onError, NOT runZonedGuarded — avoids zone-mismatch).
  - Device id: persistent random id in prefs key `aria.deviceId`, plus platform label
    (e.g. `linux-a1b2c3`). Never log tokens/PII; track titles are fine, the ListenBrainz token is not.
- **Instrumentation** (comprehensive but not spammy — log state transitions and failures, not
  every frame): app start (version/platform), server URL set/changed, library load
  success(count)/failure, playback track start/stop/error (audioError stream), queue restore,
  scan/enrich SSE events, settings changes, API call failures at provider call sites
  (the existing silent `catch (_)` blocks in core providers get a `Log.w` — touch the core ones
  in player_providers/library_providers/connection, don't chase all 52).
- `lib/core/log_sync.dart`: sync provider (app-lifetime, like enrichRefreshProvider):
  - Cursor = byte offset + file length fingerprint in prefs `aria.logCursor`.
  - Every 5 min (Timer) and on serverStatusProvider success: read new NDJSON lines past cursor
    (cap 500 entries / ~512KB per batch, loop until drained), POST via new
    `AriaClient.uploadLogs(device, entries)`; advance cursor only on 2xx.
  - statusCode 0 (offline) → stay quiet, retry next tick. 404 → server too old, retry later.
    Sync failures must never be written to the log file (memory-only), or it loops.
  - Handles rotation: if file shrank vs fingerprint, reset cursor to 0.
- Debug UI: Settings gets a "Logs" ListTile → `/settings/logs` sub-screen (nested GoRoute like
  'eq'): reversed ring-buffer list, level filter chips, "Sync now" button. Plain and small.
- Tests: rotation + cursor logic unit tests; a widget test for the logs screen per the
  eq_screen_test harness.

## 2. Data usage settings (cellular / wifi)

- New dep: `connectivity_plus` (network type detection; supports Android + Linux).
- `lib/core/data_usage.dart` (core — playback and downloads gate on it; re-export from
  settings_providers.dart per the established rule):
  - `enum NetKind { wifi, cellular, offline, other }` — map connectivity_plus results; ethernet
    counts as wifi (unmetered); on non-Android desktop default to wifi when in doubt.
  - `networkKindProvider`: StreamProvider<NetKind> over `Connectivity().onConnectivityChanged`
    seeded with an initial check.
  - `DataUsage` model (json blob, prefs key `aria.dataUsage`, corrupt→defaults):
    `streamOnWifi=true, downloadOnWifi=true, streamOnCellular=true, downloadOnCellular=false`.
    `DataUsageNotifier` with `set(DataUsage)` following the EqNotifier persistence pattern.
    Helpers: `allowsStream(NetKind)`, `allowsDownload(NetKind)` (offline/other → allow the
    attempt; the request will fail on its own — gating is only about metered-data protection).
- **Playback gate**: in `QueueNotifier._playCurrent`, if the track has no local download and
  `!allowsStream(kind)`, do not start the stream; surface "Streaming disabled on cellular"
  via a SnackBar (reuse the audio-error SnackBar pathway in transport_bar, or a small
  playbackNoticeProvider) and pause. Do NOT auto-skip through the whole queue.
  (Until §3 lands there is no local download — implement the gate reading an optional
  local-path resolver that §3 fills in; a `String? Function(String trackId)` provider
  defaulting to null is enough.)
- **Settings UI**: new `_Section(title: 'Data usage')` on SettingsPage with four
  SwitchListTiles grouped by two small subheaders (Wi-Fi, Cellular): "Stream music",
  "Download music". Subtitle on the section showing current network (watch networkKindProvider).
  On non-Android platforms without cellular this is still shown (harmless) — no platform gate.
- Tests: `test/data_usage_test.dart` — provider persistence + gating logic + settings toggles
  via the eq_screen_test harness.

## 3. Offline downloads

Server: NO changes. `/api/stream/{id}` already serves the exact original bytes with ETag —
a downloaded file is bit-perfect by construction.

- `packages/aria_api`: add `Future<http.StreamedResponse> download(String trackId)` — streamed
  GET of the stream URL, no 15s timeout (large files), throws AriaApiException on non-2xx.
- `lib/core/downloads.dart`: `DownloadsNotifier` (app-lifetime):
  - State: `{index: Map<trackId, DownloadEntry(path, bytes, etag?)>, queue: List<trackId>, active: trackId?, progress: double?}`.
  - Index persisted as JSON at `<app-support>/downloads/index.json` (load in build(), save on change).
  - Files: `<app-support>/downloads/<trackId>.<ext>` — ext from `track.format` lowercased
    (fallback: Content-Type map, then `.bin`). Write to `.part`, verify length vs
    Content-Length, then rename. Store ETag from response.
  - Sequential queue worker; before each item check `allowsDownload(networkKind)` — if blocked,
    pause the queue and resume on network-kind change (listen to networkKindProvider).
  - `localPath(trackId)` lookup — wired into the resolver provider from §2 so
    `_playCurrent`/`_syncEngineNext` prefer local files (this makes gapless work offline too).
  - `remove(trackId)`, `removeAll()`, `downloadTracks(Iterable<Track>)` (dedupes already-downloaded).
  - **Album art**: when queuing tracks, also fetch `artUrl(albumId)` once per album to
    `<app-support>/downloads/art/<albumId>` (any ext); expose `localArt(albumId)` and make
    the ArtImage widget fall back to Image.file when the network image errors / offline.
    Keep this small — art is nice-to-have, audio is the feature.
  - Log through `Log` (download start/done/fail/evict).
- **Offline library**: in `libraryTracksProvider`, on successful fetch ALSO write the raw
  response body to `<app-support>/cache/tracks.json` (fire-and-forget); on fetch failure,
  fall back to decoding the cached file (Isolate.run, same decoder). Log which path was used.
  genreTree/people already degrade to empty. This makes the app start offline with a browsable
  library and playable downloads.
- **Offline plays**: playReporter currently swallows recordPlay failures (user tracks 20k+
  plays/year). On failure append `{trackId, ts}` to prefs JSON list `aria.pendingPlays`
  (cap 5000); flush pending plays whenever the server is reachable (piggyback the log-sync
  tick). Server recordPlay must be checked to accept a client-supplied timestamp — if it
  doesn't, add optional `at` field to the existing endpoint (backward compatible).
- **UI**:
  - "Download" action in the existing track/album context menus (track_actions / album page
    action row), and "Remove download" when downloaded.
  - Small check/download-done indicator on TrackRow when downloaded (watch via
    `select` on the index keyset — do NOT rebuild 100k rows on progress changes).
  - Settings section "Storage" (or reuse an existing fitting section) with a "Downloads"
    ListTile → `/settings/downloads` sub-screen: total size, in-progress item with progress
    bar, list of downloaded albums/tracks with per-item remove, "Remove all".
- Tests: index round-trip, ext mapping, resolver preference (local over URL), cellular gating,
  pending-plays queue flush. Widget test for the downloads screen.

## 4. Container auto-update (the "watchtower" bug)

Finding: watchtower does not exist anywhere (repo or host) — there is nothing to fix, only to
build. Host reality (verified over SSH, admin@10.0.0.10): AlmaLinux 10.1, rootless podman 5.6.0,
podman-compose 1.5.0 from /home/admin/podman/aria/compose.yaml, container `aria`, external
volume, port 3001, lingering enabled, podman-auto-update.timer present but disabled.
`podman auto-update` requires a real systemd unit per container → migrate aria to Quadlet.

Repo deliverables:
- `compose.yaml`: on the aria service add labels
  `io.containers.autoupdate: registry` and `com.centurylinklabs.watchtower.enable: "true"`;
  add a `watchtower` service (image `containrrr/watchtower`, mounts `/var/run/docker.sock`,
  `command: --label-enable --cleanup --interval 3600`, `restart: unless-stopped`) under
  `profiles: ["watchtower"]` so plain `docker compose up` doesn't start it but
  `docker compose --profile watchtower up -d` does. Comment that this is the DOCKER path and
  podman users should use the Quadlet.
- `deploy/aria.container`: Quadlet for the deployment host (unit description, `[Container]`
  Image=ghcr.io/schotjechrisman/aria:latest, ContainerName=aria, AutoUpdate=registry,
  PublishPort=3001:3000, Volume=/mnt/vault/media/music:/music:ro, Volume=<data volume>:/data:z,
  HealthCmd=/aria -healthcheck + interval options, [Service] Restart=always,
  [Install] WantedBy=default.target). NOTE the data volume name must match what the running
  container actually mounts — the applier must `podman inspect aria` first, never guess,
  never recreate the volume (live SQLite DB).
- `deploy/podman-auto-update-override.conf`: timer drop-in with `OnCalendar=` reset +
  `OnCalendar=*:0/15` and `RandomizedDelaySec=2m` ("frequent" per requirement; the pull check
  is a cheap registry HEAD, image only moves on releases).
- README: replace the manual-update instructions with an "Updating" section covering both
  paths (podman/Quadlet + timer, docker/watchtower profile), keeping the manual command as
  fallback. Mention :latest only moves on stable (non-prerelease) releases.

Host application happens in a LATER phase (after code review) — not by the repo implementer.

## Sequencing & conflicts

Order: §1 logging → §2 data usage → §3 downloads (each builds on the previous; all three touch
settings_page.dart, pubspec.yaml, player_providers.dart). §4 is independent (compose/deploy/README).
After each app change: `flutter analyze` + `flutter test` must pass; server changes: `go vet ./...`
+ `go test ./...`.

## Established facts implementers must respect

- Full subsystem notes: `/tmp/claude-1000/-home-chris-Repositories-roon/d81f250e-7069-4a6f-a4b3-0f78dd46f703/tasks/w2ni7o5ua.output` (JSON, keys: app-settings, app-playback, app-api-offline, server-api, deploy-update, app-logging). READ THE KEYS RELEVANT TO YOUR TASK BEFORE CODING.
- Settings persistence: shared_preferences via sharedPrefsProvider, `aria.*` keys, Notifier
  build() reads prefs / setter writes; JSON blobs with corrupt→default try/catch.
- Core-vs-feature rule: state needed by core code lives in lib/core/, re-exported from
  settings_providers.dart.
- Routing: nested GoRoute under /settings in features/settings/routes.dart.
- Server: route files self-register (`init(){register(registerXxx)}`), writeJSON/httpError/fail
  helpers, repos are dumb structs, migrations NNN_name.sql embedded, stdlib log with
  `"prefix: %v"` convention, stdlib-only tests.
- aria_api stays pure Dart (http only); aria_player must not assume initialized engine.
- mpv sources are opaque strings — local paths work as-is; keep _syncEngineNext consistency.
- Bit-perfect invariant: no transcoding anywhere, ever.
- Minimal deps convention: only path_provider + connectivity_plus are approved additions.
- Widget tests: SharedPreferences.setMockInitialValues + ProviderScope overrides +
  containerOf pattern from test/eq_screen_test.dart. path_provider needs a mock
  (PathProviderPlatform stub or override the dir provider) in tests.
- `ponytail:` comments mark deliberate simplifications with their upgrade path.
