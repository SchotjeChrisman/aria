# Spec: transcode quality tiers + settings sub-pages

Date: 2026-07-08. Driver for the implementation workflow. Implementers MUST respect the "Established facts" — they were verified by reading the code.

## Decisions (final — do not relitigate)

- Chris redefined the invariant: **the server MAY transcode to lower tiers; "bit-perfect" now means the app faithfully plays whatever the server serves.** The top tier is still the original file, byte-for-byte.
- **Tiers:** `original` (raw passthrough, today's behavior), `high` (Opus ~192k VBR, Ogg), `low` (Opus ~96k VBR, Ogg). One codec (libopus) for both lossy tiers.
- **Per network type** the user picks a tier: `wifi`, `cellular`, and `download` (downloads use their own tier, not the live network). Defaults: wifi=`original`, cellular=`high`, download=`original`. Changeable in Settings.
- **Streaming approach:** transcode-to-disk-cache, then serve the cache file with the SAME `http.ServeContent` call (keeps Range/seek/304/ETag/sendfile). NOT a raw ffmpeg→ResponseWriter pipe (unseekable).
- **Settings** split into a grouped list of 5 tappable tiles that `context.push` detail sub-pages.

## Established facts (verified)

### Server serving (`server/internal/api/stream.go`)
- Sole audio handler: `func init(){ register(registerStream) }`; `registerStream(mux, d)` → `mux.HandleFunc("GET /api/stream/{id}", ...)`. id via `r.PathValue("id")`.
- Handler: `t,_ := d.Tracks.ByID(r.Context(), id)` → `p := filepath.Join(d.Cfg.MusicDir, filepath.FromSlash(t.Path))` → `os.Open(p)` → `f.Stat()` → set Content-Type from `streamMIME` map (by lowercased ext) + `Cache-Control: private, no-cache` + `ETag` (`"%x-%x"` of modTimeUnixNano, size) → `http.ServeContent(w, r, fi.Name(), fi.ModTime(), f)`.
- `notFound(w)` used on all error branches.
- `streamMIME` map covers .flac/.mp3/.m4a/.ogg/.opus/.wav/.aiff/.ape/.wv/.dsf.
- `gzipped()` in `api.go` already bypasses `/api/stream/` (comment: "gzip breaks ServeContent Range"). `statusRecorder.ReadFrom` preserves sendfile. Do NOT change middleware.
- `Deps` (`deps.go`) has `d.Tracks (*repo.Tracks)` and `d.Cfg (config.Config)` with `MusicDir`. Helpers: `writeJSON`, `httpError`, `fail`.

### Server build (`Dockerfile`, `server/internal/config/config.go`, `server/internal/db/`)
- Two-stage: `golang:1.26-alpine` builder → `gcr.io/distroless/static:nonroot`. `CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/aria ./cmd/aria`. Runs as uid 65532 (nonroot). No shell, no ffmpeg today. `mkdir -p /out/empty` trick because distroless can't mkdir at runtime — but aria already writes `aria.db` under `/data`, so `os.MkdirAll(DATA_DIR/tc)` at runtime is fine.
- `config.FromEnv()` uses a `getenv(key, def)` helper; only PORT(3000)/MUSIC_DIR(/music)/DATA_DIR(/data) today.
- Migrations: `//go:embed migrations/*.sql`, applied by filename order (`001_`,`002_`,`003_client_logs`). **No migration needed** for this feature (cache is filesystem-only).
- `/api/status` handler exists (app calls `AriaClient.status()`); find it and add the capability flag there.

### App network + URLs
- `app_flutter/lib/core/data_usage.dart`: `enum NetKind {wifi, cellular, offline, other}`; `networkKindProvider` (StreamProvider<NetKind>); `DataUsage` model with `fromJson/toJson/copyWith` + `allowsStream(kind)/allowsDownload(kind)`, `DataUsageNotifier` (NotifierProvider, prefs key `aria.dataUsage`). This is the exact template for the new quality model.
- `app_flutter/packages/aria_api/lib/src/client.dart`: `streamUrl(String trackId) => '$baseUrl/api/stream/${Uri.encodeComponent(trackId)}'` (line ~49); `download(String trackId) => _download('/api/stream/${Uri.encodeComponent(trackId)}')` (line ~430). `_u(path,[query])` (line ~43) already supports query params. Same endpoint serves both stream + download.
- `app_flutter/lib/core/player_providers.dart`: `QueueNotifier._playCurrent` (~488) and `_syncEngineNext` (~522) build source as `local ?? ref.read(apiClientProvider).streamUrl(t.id)`. Both already compute `kind` (NetKind) for the data-usage gate (~458, ~515). `build()` already `ref.listen`s `networkKindProvider`.
- `app_flutter/lib/core/downloads.dart`: `DownloadsNotifier._downloadOne` (~318/320) calls `apiClient.download(t.id)`. Cellular gating via `dataUsageProvider.allowsDownload(kind)` in `_pump` (~275). Atomic `.part`+rename (~327/342), ETag from `res.headers['etag']` (~349), `extensionFor()` maps format/content-type→extension. `DownloadEntry` model; `build()` listens `networkKindProvider`+`dataUsageProvider`.
- shared_preferences pattern: `aria.<name>` const key; Notifier `build()` reads getString→jsonDecode in try/catch returning clean default; `set()` sets state then jsonEncode+setString.

### App settings (`app_flutter/lib/features/settings/`)
- `settings_page.dart`: `SettingsPage` (ConsumerWidget), route `/settings`. Body = `Center>ConstrainedBox(maxWidth:720)>ListView(padding AriaSpace.s6)` with a titleLarge "Settings" + 8 `_Section(title, child)` blocks. `_Section` = private StatelessWidget {title, child}.
- 8 current sections IN ORDER: (1) **Server** `_ServerUrlField`; (2) **Playback** `_ExclusiveToggle` (only if !Android) + `_EqTile` (pushes `/settings/eq`); (3) **Data usage** `_DataUsageSection` (Wi-Fi + Cellular stream/download SwitchListTiles); (4) **Storage** `_DownloadsTile` (pushes `/settings/downloads`); (5) **Scrobbling** `_ListenBrainzField`; (6) **Library** `_LibraryTools` (Rescan + Enrich); (7) **Profiles** `ProfilesSection` (from `lib/features/profiles/profiles_section.dart`); (8) **Diagnostics** `_LogsTile` (pushes `/settings/logs`).
- `settings/routes.dart`: exports `settingsFeatureEntry = FeatureEntry(destination: AppDestination(path:'/settings',...), routes:[GoRoute(path:'/settings', builder:..SettingsPage, routes:[ eq, logs, downloads child GoRoutes ])])`. Child routes use RELATIVE paths ('eq','logs','downloads'). `core/router.dart` iterates `featureEntries` generically — **no router.dart change needed** to add settings child routes.
- Detail page pattern: ConsumerWidget/ConsumerStatefulWidget returning `Scaffold(appBar: AppBar(title: Text(...)), body: ...)`; go_router adds the back arrow. See `eq_screen.dart`, `logs_screen.dart`, `downloads_screen.dart`.
- Theme tokens: `AriaSpace.sN`, `AriaColors.of(context)` from `lib/core/theme.dart`. Settings ListTiles use `contentPadding: EdgeInsets.zero`.

## Server implementation

1. **`config.go`**: add `FFmpegPath` (env `FFMPEG_PATH`, default `/ffmpeg`) and `TranscodeCacheMB` (env `TRANSCODE_CACHE_MB`, default `5000`) via the existing `getenv` helper (int parse for the MB).
2. **Feature gate**: at startup (`cmd/aria/main.go` wiring, or where Deps is built) do `_, err := exec.LookPath(cfg.FFmpegPath)` or `os.Stat`; store `Deps.CanTranscode bool`.
3. **`stream.go` `registerStream`**: after resolving `p`, read `tier := r.URL.Query().Get("tier")`.
   - `tier == "" || tier == "original"` → EXACT current path (os.Open(p)+ServeContent). Zero change to bit-perfect path.
   - `tier == "high" || tier == "low"`:
     - if `!d.CanTranscode` → `httpError(w, http.StatusNotImplemented, "transcoding unavailable")`.
     - `bitrate := "192k"` (high) / `"96k"` (low).
     - stat original for mtime+size; `cachePath := filepath.Join(d.Cfg.DataDir, "tc", fmt.Sprintf("%s__%s__%x-%x.opus", id, tier, mtimeNano, size))`.
     - if cachePath exists → `os.Open`+`w.Header().Set("Content-Type","audio/ogg")`+`http.ServeContent(w, r, filepath.Base(cachePath), cacheFi.ModTime(), cf)`. Done.
     - else transcode: `os.MkdirAll(dir, 0o755)`; `tmp := cachePath+".part.<rand>"` (rand suffix — derive from mtime/size/pid, no `math/rand` seeding needed; a `os.CreateTemp(dir, base+".*.part")` is cleanest); `ffCtx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)` (NOT r.Context() — finish even if client disconnects); `exec.CommandContext(ffCtx, cfg.FFmpegPath, "-nostdin","-hide_banner","-loglevel","error","-i",p,"-vn","-map_metadata","0","-c:a","libopus","-b:a",bitrate,"-f","ogg",tmp)`; on success `os.Rename(tmp, cachePath)` (atomic); on error remove tmp + `httpError 500`. Then serve cachePath as above.
     - After a successful new transcode, kick the cache sweep (below).
   - any other tier value → treat as original (or 400 — pick original to be lenient).
4. **Cache sweep** (ponytail: simple): after writing a new cache file, if total size of `DATA_DIR/tc/*.opus` > `TranscodeCacheMB*1<<20`, delete oldest-by-ModTime until under. `// ponytail: O(n) dir scan + oldest-first delete; a real LRU only if the cache dir gets huge.` Do it synchronously or in a goroutine; guard against concurrent sweeps is unnecessary (deletes are idempotent).
5. **`/api/status`**: add `"transcode": d.CanTranscode` (bool) to the JSON.
6. **`Dockerfile`**: keep `gcr.io/distroless/static:nonroot`. Add before/after the aria COPY in the runtime stage: `COPY --from=mwader/static-ffmpeg:7.1 /ffmpeg /ffmpeg`. (Pin the tag. Only `/ffmpeg` needed — no ffprobe, duration is in the DB. It's fully static so it runs on distroless/static and is executable by nonroot.)
7. **Do NOT** touch `gzipped()`, `statusRecorder`, or `streamMIME`.

### Server tests (`server/internal/api/`, table/httptest)
- Stub ffmpeg: write a tiny script/binary on a temp PATH (or point `FFmpegPath` at it) that just writes a known blob to the `-f ogg <tmp>` output arg, so no real encoder in CI. Cover: original/empty tier → serves source bytes; high/low → creates cache file with the expected filename, second request serves WITHOUT re-invoking stub (touch a sentinel to detect invocation); Range request on cached file → 206+Content-Range; `CanTranscode=false` + high → 501; `/api/status` reports the flag; source mtime/size change → new cache filename (stale invalidation).

## App implementation

1. **Quality model** — new `app_flutter/lib/core/quality.dart` (sibling of data_usage.dart): `enum QualityTier { original, high, low }` with a `wire` string (`original`/`high`/`low`) and `label`. `class QualityPrefs { QualityTier tierWifi, tierCellular, tierDownload; fromJson/toJson/copyWith; QualityTier streamTierFor(NetKind k) }` (wifi→tierWifi, cellular→tierCellular, offline/other→original). `qualityProvider = NotifierProvider<QualityNotifier, QualityPrefs>` prefs key `aria.quality`, defaults wifi=original/cellular=high/download=original, following `DataUsageNotifier` build()/set() exactly (try/catch → defaults on corrupt).
2. **`client.dart`**: `streamUrl(String trackId, {QualityTier tier = QualityTier.original})` — append `?tier=high|low` ONLY when `tier != original` (keep bare URL for original so caching is unchanged). `download(String trackId, {QualityTier tier = QualityTier.original})` — same. Map enum→wire once. Reuse `_u`/Uri query support. Keep aria_api free of Riverpod (pass the enum in; enum can live in aria_api or be mapped at the boundary — simplest: define `QualityTier` in aria_api client so both layers share it, OR accept a `String? tier`. Pick the one with the smaller diff; a `String? tier` param on the client avoids a cross-package enum). **Prefer `String? tier` on the client methods** and map the enum→wire in the app layer.
3. **`player_providers.dart`**: in `_playCurrent` and `_syncEngineNext`, where `kind` is already computed, `final tier = ref.read(qualityProvider).streamTierFor(kind);` and pass `tier: tier.wire` to `streamUrl(t.id, ...)`. Local-download branch unchanged. Add `ref.listen(qualityProvider, ...)` in `build()` next to the existing networkKindProvider listen so a tier change re-syncs the gapless next.
4. **`downloads.dart`**: in `_downloadOne`, `final tier = ref.read(qualityProvider).tierDownload;` → `apiClient.download(t.id, tier: tier.wire)`. Add a `tier` field to `DownloadEntry` (persist it). Derive extension from response Content-Type: `audio/ogg` → `.opus` (extend `extensionFor`). Content-Length is present (cache file via ServeContent), so short-read + etag capture keep working. `localSourceResolver`: local always wins (a track downloaded low plays low everywhere — intended).
5. **Capability**: if `AriaClient.status()` reports `transcode:false`, the Settings quality selectors show only `original` (disable/hide high+low). Wire a small provider off the status call, or read the existing serverSettings/status provider.

### App tests (`app_flutter/test/`, `dart test` for aria_api)
- QualityPrefs fromJson/toJson/copyWith/streamTierFor + corrupt-prefs→defaults.
- client: streamUrl/download append `?tier=high|low` and OMIT it for original.
- player selects tier by NetKind at _playCurrent/_syncEngineNext; a qualityProvider change re-drives _syncEngineNext (mirror the existing networkKindProvider listen test).
- downloads use tierDownload, store tier + `.opus` extension on DownloadEntry, short-read/etag path still passes.

## Settings sub-pages

Convert the root `/settings` ListView from 8 inline sections into 5 tappable ListTiles (leading icon + title + subtitle) that `context.push('/settings/<slug>')`, mirroring the existing `_EqTile/_DownloadsTile/_LogsTile` pattern. Keep the 720 ConstrainedBox + AriaSpace tokens.

Category buckets (which current section moves where):
1. **Playback** `/settings/playback` ← `_ExclusiveToggle` + `_EqTile` (still pushes `/settings/eq`) + NEW streaming-quality selectors for Wi-Fi and Cellular (a DropdownButton or SegmentedButton per NetKind, bound to `qualityProvider`).
2. **Data & Downloads** `/settings/data` ← `_DataUsageSection` + `_DownloadsTile` (still pushes `/settings/downloads`) + NEW download-quality selector (`qualityProvider.tierDownload`).
3. **Library** `/settings/library` ← `_LibraryTools` (Rescan + Enrich).
4. **Account** `/settings/account` ← `_ServerUrlField` + `_ListenBrainzField` + `ProfilesSection`.
5. **About** `/settings/about` ← `_LogsTile` (pushes `/settings/logs`) + app version/build info (use existing package_info if present, else omit version).

- Each category page: ConsumerWidget → `Scaffold(appBar: AppBar(title: Text(...)), body: ListView(...moved section widgets...))`. Reuse the existing private section widgets verbatim — move them into a shared file or make them non-private so the detail pages can use them. Simplest: move the section widgets into their category screen files.
- `settings/routes.dart`: add 5 sibling `GoRoute(path:'playback'|'data'|'library'|'account'|'about', builder:...)` under the existing `GoRoute('/settings')` `routes:` list. Leave `eq`/`logs`/`downloads` child routes unchanged. No `core/router.dart` change.
- Settings tests: navigation smoke — each of `/settings/playback|data|library|account|about` builds; nested `/settings/eq|logs|downloads` still push.

## Out of scope / ponytail notes
- No DB migration, no new server env beyond FFMPEG_PATH/TRANSCODE_CACHE_MB.
- No single-flight on concurrent first-transcode (last-rename-wins is harmless) — add only if it ever matters.
- Downloaded-tier-wins-everywhere is intended; a "redownload at higher tier" affordance is future work.
