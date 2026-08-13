# Aria HTTP API Reference

The contract a full-featured client (TUI, mobile, web) is built against. Every
statement here was verified against the Go source under
`server/internal/api/` at commit `05caf70`.

---

## 0. Ground rules

Read this section first. Everything else assumes it.

### No authentication

There is none. `api.New()` (`api.go:52`) wires exactly two middlewares — gzip
and access logging — and a `GET /healthz`. No token, no cookie, no
`Authorization` header, no session, no auth check in any handler. Every route is
open to anything that can reach the port. **Do not build a credential flow.**

Corollary: `GET /api/settings` returns `listenbrainzToken` in plaintext to any
caller. Mask it in your UI.

### Three different error body shapes

Never blindly `json.Unmarshal` a non-2xx body.

| Helper | Content-Type | Body | Used by |
| --- | --- | --- | --- |
| `httpError` (`api.go:177`) | `application/json` | `{"error":"<msg>"}` | all 400 / 409 / 413 / 500 / 501 / 502 |
| `notFound` (`tags.go:17`) | `text/plain; charset=utf-8` | `Not Found` — **no trailing newline** | most 404s: stream, art, people/img, lyrics, album info, artist, composer, extalbum, booklets, tags, playlists, favourite, radio delete |
| `http.Error` | `text/plain; charset=utf-8` | `Not Found\n` — **with newline** | profiles, edits (`PATCH /api/tracks|/api/albums`, `GET /api/edits`), stats, plays/counts, mixes, `/api/albums/{id}/match` |

Practical rule: **branch on status code first**; only parse JSON for 4xx/5xx
that are not 404, and treat any 404 body as opaque text.

Success is always `200`. There is no `201` and no `204` anywhere.

### Request body caps

* `32 KiB` (`maxBodyBytes`) for every JSON endpoint.
* `1 MiB` for `POST /api/logs` only.
* `10 MiB` for `POST /api/art/{albumId}` (multipart).

An absent or empty JSON body decodes as `{}` rather than erroring
(`readJSON` swallows `io.EOF`). This is why `PUT .../favourite` with no body
means `favourite:false`, and why `PATCH` handlers report "nothing to change"
instead of a parse error. Exceeding the cap surfaces as `400 invalid json` /
`invalid body`, **not** `413` (except art upload, which does return `413`).

### Timestamps

Every timestamp the server writes or accepts is exactly:

```
2006-01-02T15:04:05.000Z
```

UTC, literal `Z`, **exactly three** fractional-second digits — i.e. JavaScript
`new Date().toISOString()`. Window cutoffs in stats/mixes/plays are
**lexicographic string comparisons** on that column, so any other layout is
either rejected (`POST /api/plays`) or would sort wrongly forever.

One exception: the seeded default profile's `createdAt` is written as plain
RFC3339 without milliseconds. **Parse profile `createdAt` leniently.**

### gzip

The middleware (`api.go:146`) gzips any response when the request sends
`Accept-Encoding: gzip`, **except**:

* `/api/events`
* `/api/stream/*`
* `/api/art/*`
* `/api/people/img/*`
* any path containing `/booklet`

`GET /api/tracks` additionally short-circuits to a **pre-gzipped cached buffer**
with its own `Content-Encoding: gzip` and an explicit `Content-Length`, which the
middleware passes through untouched. A standard HTTP client handles all of this
transparently; a hand-rolled socket client must decompress.

### `albumId`

A 40-character lowercase hex SHA-1. `/api/art/{albumId}` and both booklet routes
enforce `^[0-9a-f]{40}$` before doing anything else and 404 immediately
otherwise.

### There is no search endpoint

Verified against the complete route table: there is no `/api/search`, no
filter/query params on `/api/tracks` beyond `limit`/`offset`, and no
`GET /api/albums` or `GET /api/artists` list route. See
[§3 Search](#3-search).

---

## 1. Status & capabilities

### `GET /api/status`

The startup handshake. Poll once before deciding which features to expose.

* Query: none. Body: none.
* `200`:

```json
{
  "tracks": 12043,
  "musicDir": "/music",
  "version": "3.7.0+17",
  "transcode": true,
  "analyze": true,
  "fingerprint": false
}
```

| Field | Meaning |
| --- | --- |
| `tracks` | row count in `tracks`; **this is your total-count source**, since no list endpoint sends a count header |
| `musicDir` | server-side absolute library root |
| `version` | ldflag-injected binary version; `"dev"` for an unstamped build |
| `transcode` | ffmpeg found at boot. **`false` ⇒ `?tier=high\|low` returns 501; clamp your UI to the original tier** |
| `analyze` | loudness/ReplayGain analyzer wired (implied by ffmpeg). Gates `POST /api/analyze`, `GET /api/analyze/status`, and the `analyze` SSE event |
| `fingerprint` | `fpcalc -version` probed OK. Gates `POST /api/fingerprint`, `GET /api/fingerprint/status`, and the `fingerprint` SSE event |

Errors: `500 {"error":"db error"}`.

### `GET /healthz`

Returns the literal body `ok` (text, not JSON, not access-logged). Nothing else.

---

## 2. Library browsing

### `GET /api/tracks` — the primary data source

The whole library as one merged array: file tags + enrichment credits + album
and track edits + derived `releaseType` / `genres` / `tags` / ReplayGain.
**Albums, artists and genres are all client-side groupings of this array.**

* Query:
  * `limit` — int, optional. Must be `>= 1` or `400 {"error":"invalid limit"}`. Default `-1` (no limit).
  * `offset` — int, optional. Must be `>= 0` or `400 {"error":"invalid offset"}`. Default `0`.
* Slicing happens **after** the whole-library merge (`releaseType` needs whole
  albums), so paging saves bandwidth, not server work.
* Fast path: when `limit` is absent **and** `offset == 0` **and** the request
  sends `Accept-Encoding: gzip`, the server writes a pre-gzipped cached body.
  This is the intended call.
* `200`: a JSON array of objects. `path` is deliberately omitted.

**Keys always present** (built in `library.go:450-486`):

| Key | Type |
| --- | --- |
| `id` | string |
| `addedAt` | string (ISO ms Z) |
| `title`, `artist`, `albumArtist`, `album` | string |
| `albumId` | string (40-hex) |
| `trackNo`, `discNo`, `year` | int \| null |
| `genre` | string \| null — **RAW single file-tag string** |
| `composer`, `conductor`, `work`, `movement` | string \| null |
| `mbAlbumId`, `mbRecordingId`, `mbAlbumArtistId` | string \| null |
| `duration` | float \| null — **seconds** |
| `format` | string |
| `sampleRate`, `bitsPerSample`, `channels` | int \| null |
| `lossless`, `hasArt`, `favourite` | bool |
| `trackGainDb`, `albumGainDb`, `trackPeak`, `albumPeak` | float \| null |
| `loudnessLufs`, `dynamicRangeLu` | float \| null |
| `suspect` | bool — never null; `false` is the default |
| `releaseType` | string — one of `Album`, `EP`, `Single`, `Live`, `Compilation` |
| `genres` | array of string — **derived canonical taxonomy**, not the raw `genre` |
| `tags` | array of string — user tag names including every ancestor folder name |

**Keys conditionally present** (absent entirely, not null):

| Key | Type | When |
| --- | --- | --- |
| `orchestra` | string | from the enrich-cache `track` blob |
| `performers` | array of `{"name":string,"role":string}` | from the enrich-cache `track` blob |
| `albumArtists` | array of string | classical album-header credit line; only when the MB credit split into composers+performers **and** `classicalDisplayArtist != "0"`. **Deleted whenever an album edit sets `albumArtist`** |
| `artVersion` | int | fanned from the album edit row; bumped by art changes. Use as an art cache-buster |

**Field precedence inside a merged track** (`library.go:487-536`, later wins):

```
file tags
  → enrich_cache "track" blob
  → enrich_cache album corrections (album/albumArtist/year)
  → classical display policy (albumArtist/composer/albumArtists)
  → album edits (album, albumArtist, genre, year, artVersion)
  → track edits
```

Errors: `500 {"error":"db error"}`.

### `PUT /api/tracks/{id}/favourite`

Sets (does **not** toggle) the independent favourite flag. Survives rescans; not
written to the file.

* Body: `{"favourite": <bool>}`.
* **Gotcha**: the handler does `body["favourite"].(bool)` with the failure
  ignored. A missing key, `null`, a number, or the *string* `"true"` all coerce
  to `false` and will silently un-favourite the track. Always send a real JSON
  boolean.
* `200 {"favourite": <stored bool>}`.
* Errors: `404` text/plain (unknown id); `400 {"error":"invalid body"}`;
  `500 {"error":"internal error"}`.
* Side effect: invalidates the cached merged view, so the next `GET /api/tracks`
  is fresh.

### `GET /api/genres`

The closed taxonomy the `genres` array indexes into.

* `200 {"tree": {"<Canonical Genre>": "<Parent>"|null, ...}}` — a flat
  `map[string]*string`; `null` means top-level. E.g. `"Blues": null`,
  `"Blues Rock": "Blues"`, `"Punk": "Rock"`, `"Symphony": "Classical"`.

### `GET /api/album/{albumId}/info`

Album detail card. **On-demand**: the first call for an unknown album hits
MusicBrainz + Wikipedia (seconds) and caches forever, including misses.

* `200`: a JSON object. Every key is optional — the blob carries only what a
  source produced: `label`, `date` (MB release date, e.g. `"1975-09-12"`),
  `country`, `mbType` (`Album|Single|EP|Broadcast|Other`), `mbSecondary`
  (array of string, e.g. `["Compilation"]`), `catno` (Discogs catalogue number),
  `blurb` (Wikipedia extract), `url` (Wikipedia page URL).
* Five album-edit fields then overwrite the blob: `label`, `date`, `country`,
  `catno`, `blurb` (`library.go:951`).
* `404` text/plain when the album has no tracks, the lookup errored, or the
  result has no truthy value (empty arrays **do** count as content here).

### `GET /api/artist/{name}`

Artist/person hero card. **On-demand**, ~3–6 s on a cold name, serialised to 4
concurrent requests.

* The path segment is the **Latin display name** — exactly as `/api/tracks`
  served it. The server resolves it back to the raw stored name.
* `200`: the enrich-cache `artist` blob with the DB artist-edit row spread over
  the top. All fields `omitempty`, so treat every one as optional: `type`,
  `area`, `born`, `died`, `members[]`, `bands[]`, `bio`, `url`, `image`
  (external portrait URL — prefer proxying via `/api/people/img/{name}`),
  `imgSrc` (`wikipedia|deezer`), `similar[] {name, image|null}`,
  `discography[] {title, cover|null, date|null, type, deezerId?}`,
  `discographyAt`, `imgCheckedAt`, `bioCheckedAt`, `mbid`, `nameLatin`,
  `nameLatinSource`, `qid`, `instruments[]`, `wdCheckedAt`.
* Editable overlay fields (`edits.go:109`): `type`, `area`, `born`, `died`,
  `image`, `bio`.
* `404` text/plain when nothing is known. Empty arrays (`similar`, `members`,
  `bands`) do **not** count as content here.

### `GET /api/composer/{name}`

Classical composer hero card. **Cache-only — never hits the network**, so a cold
entry is simply a 404 and the call never blocks.

* `200`: the raw cached blob served verbatim. All fields `omitempty`:
  `fullName`, `epoch`, `portrait` (URL), `born` (year only), `died` (year only),
  `bio`, `url`.
* `404` text/plain when absent or when the cached blob is the literal `null`
  (a cached miss). No edit overlay on this route.

### `GET /api/people`

Bulk portrait map. Memoized 60 s server-side.

* `200`: a flat `{"<person name>": "<external image URL>"}` — no wrapper key, no
  nulls. Keys are **raw stored names** for entries written before Latinisation
  and the artist-edit key otherwise, so they do not always match the spellings
  `/api/tracks` served. Fetch the picture via `/api/people/img/{name}` using the
  same key.

### `GET /api/people/img/{name}`

Portrait proxy: fetches the `/api/people` URL once, caches under
`DATA_DIR/people/`, serves from the LAN.

* Binary image bytes (`image/jpeg|png|webp`), `Cache-Control: public,
  max-age=31536000`, `ETag`, Range / `If-None-Match` supported. **Not JSON.**
* `404` text/plain when the name is empty, `> 200` runes, unknown to the people
  map, or the CDN fetch fails — fall back to initials.

### `GET /api/art/{albumId}`

Album cover image.

* Query: `source` — optional, one of:
  * `""` (default) — resolve the album's stored `artSource`
  * `"file"` — embedded/scanner slot
  * `"api"` — enriched slot, falling back to an uncached **live remote preview**
  * `"custom"` — uploaded slot
  * anything else ⇒ `400 {"error":"invalid source"}`
* Binary `image/jpeg`. **Not JSON.** On-disk slots get
  `Cache-Control: public, max-age=31536000` + `ETag` + Range via
  `http.ServeContent`. The live remote preview is `Cache-Control: no-store`.
* `404` text/plain when the id is malformed or no slot resolves.
* Excluded from gzip.
* **Because of the one-year max-age, append the track's `artVersion` as a
  cache-busting query token.** The server ignores unknown params.

### `POST /api/art/{albumId}`

Upload custom cover art. Writes the `.custom.jpg` slot, sets `artSource=custom`,
bumps `artVersion`.

* Body: `multipart/form-data`, file field named `image`, ≤ 10 MiB, sniffed
  content type must start with `image/`.
* `200`: the album's **current full edit-overrides object**, including
  `"artSource":"custom"` and `"artVersion":<int>`.
* Errors: `404` text/plain (bad id / no such album);
  `413 {"error":"image too large"}`; `400 {"error":"not an image"}`;
  `500 {"error":"internal error"}`.

### `GET /api/lyrics/{id}`

Lyrics for one track id. **On-demand** LRCLIB search, duration-matched, cached
forever including misses.

* `200`: the raw cached blob, verbatim: `{"synced": string|null, "plain": string|null}`.
  `synced` is LRC text with `[mm:ss.xx]` timestamps.
* `404` text/plain when the track is unknown, the blob is null/undecodable, or
  **both** fields are null-or-empty.

### `GET /api/albums/{albumId}/booklets`

* `200 {"booklets": ["booklet.pdf", ...]}` — PDF **basenames**, ordered: names
  containing `booklet` first, then size descending, then name ascending.
  `[]` when the album exists but has no PDFs.
* `404` text/plain when `albumId` is not 40-hex or the album has no tracks.

### `GET /api/albums/{albumId}/booklet/{name}`

* `{name}` must **exactly** equal a basename from `/booklets`. User input is
  never joined into a filesystem path, so traversal attempts simply miss.
* `application/pdf` bytes; `Cache-Control: private, no-cache`; `ETag`;
  Range / `If-None-Match` / HEAD supported. Excluded from gzip.
* `404` text/plain for an unknown album or a name not in the candidate list.

### `GET /api/extalbum` — discovery lookup

Detail page for an album **not** in the library. Walks Deezer → UPC →
MusicBrainz; 30-day cache; **never caches a failure**. This is the closest thing
to a search endpoint: a lookup by artist + title.

* Query: `artist` (**required**), `title` (**required**) — either missing ⇒
  `400 {"error":"artist and title required"}`; `deezerId` (int64 string,
  optional, `0`/absent = resolve by name search).
* `200`:

```json
{
  "id": "rg:<release-group-mbid>",
  "rgMbid": "...", "upc": "...", "deezerId": 123456,
  "artist": "...", "title": "...",
  "cover": "https://…" ,
  "date": "1975-09-12", "type": "album",
  "label": "...", "link": "...",
  "tracks": [{"title":"...","duration":312,"disc":1,"number":3}],
  "releases": ["<mb release mbid>", "..."]
}
```

`id` is `"rg:<mbid>"` or `"dz:<deezer id>"`. `cover` is `string|null`.
`rgMbid`, `upc`, `deezerId`, `label`, `link`, `releases` are `omitempty`.
`tracks` is always an array; `duration` is **seconds**.

* Errors: `404` text/plain when Deezer has never heard of it;
  `502 {"error":"lookup failed: ..."}`.

### `GET /api/extalbum/img`

Cover proxy for external art. No identity resolution — pass the cover URL you
already hold.

* Query: `u` (**required**) — must be an `https` URL whose host is or ends in
  one of `cdn-images.dzcdn.net`, `e-cdns-images.dzcdn.net`, `api.deezer.com`,
  `coverartarchive.org`, `archive.org`. Anything else 404s.
* Binary image bytes, `Cache-Control: public, max-age=2592000`, `ETag`; serves
  stale on CDN failure. **Not JSON.**

### `GET /api/eq/opra`

The OPRA headphone-EQ dataset, cached 7 days in `enrich_cache`. Served verbatim
as JSON. A refetch failure serves whatever stale copy exists; with no copy at
all it is `502 {"error":"opra fetch failed: ..."}`.

---

## 3. Search

**There is no search endpoint.** Verified against the complete route table.

The intended model:

1. Fetch `GET /api/tracks` once at startup (gzip-cached server-side, multi-MB).
2. Group, search and filter **entirely client-side**. Album lists, artist lists
   and genre browse are all reductions of that array keyed on `albumId`,
   `albumArtist` and `genres`.
3. The only lookup-by-name routes are `/api/artist/{name}`,
   `/api/composer/{name}`, and `/api/extalbum?artist=&title=`.

For server-side *filtering* the closest facility is a **smart playlist**
(`POST /api/playlists` with `type:"smart"` then
`GET /api/playlists/{id}/tracks`) — but it caps at 500 results.

---

## 4. Streaming & playback

### `GET /api/stream/{id}`

The one audio endpoint. `HEAD` also matches (Go `ServeMux` `GET` pattern).
`id` is the track id from `/api/tracks`; the client **never** supplies a path —
it is resolved from the DB and joined under `MUSIC_DIR`.

* Query: `tier` — optional. The switch at `stream.go:53` is exhaustive and
  **case-sensitive**:

| `tier` value | Result |
| --- | --- |
| `high` | Opus VBR `-b:a 192k` |
| `low` | Opus VBR `-b:a 96k` |
| absent, `""`, `original`, `HIGH`, anything else | **bit-perfect original passthrough** |

There are no other query params, and `/api/stream/*` takes **no `profileId`** —
playback carries no identity.

**Original tier.** `Content-Type` from an extension → MIME table
(`stream.go:20`, lowercased ext):

```
.flac audio/flac   .mp3 audio/mpeg   .m4a/.m4b audio/mp4
.ogg/.opus/.oga/.spx audio/ogg       .wav audio/wav
.aiff/.aif/.aifc/.afc audio/aiff     .ape audio/x-ape
.wv audio/x-wavpack .dsf audio/x-dsf .wma audio/x-ms-wma
.tta audio/x-tta    .shn audio/x-shorten .mpc audio/x-musepack
```

An unknown extension gets **no** `Content-Type` from the handler
(`ServeContent` then sniffs).

**Transcoded tiers.** `Content-Type` is always `audio/ogg`, regardless of
source format.

Both paths set `Cache-Control: private, no-cache` and a strong
`ETag: "<mtime-nanos-hex>-<size-hex>"` (original: of the source file;
transcoded: of the **cache** file), then delegate to `http.ServeContent`, which
supplies `Accept-Ranges: bytes`, `Content-Length`, `Last-Modified`, and full
Range / `If-Range` / `If-None-Match` / `If-Modified-Since` handling → `200`,
`206` (with `Content-Range: bytes a-b/total`), `304`, or `416`. Multi-range
requests get a `multipart/byteranges` body.

Errors:

* `404` text/plain — unknown track id, DB error, file vanished since the scan,
  or the path is a directory.
* `501 {"error":"transcoding unavailable"}` — `tier=high|low` and the server has
  no ffmpeg. **Check `/api/status.transcode` first.**
* `500 {"error":"transcode failed"}` — any encode or cache-IO failure.

Responses on `/api/stream/*` are **never gzipped**, so Range/`ServeContent`
stays intact.

#### Transcode-tier timing and caching — plan for this

Cache key:

```
DATA_DIR/tc/{trackId}__{tier}__{srcMtimeNanosHex}-{srcSizeHex}.opus
```

* On a cache **miss** the request **blocks for the entire ffmpeg encode of the
  whole file**. There is no chunked/streaming transcode, no partial output, and
  no progress signal — the first byte arrives only after the full encode.
  ffmpeg args: `-nostdin -hide_banner -loglevel error -i SRC -vn -map_metadata 0
  -c:a libopus -b:a {192k|96k} -f ogg -y TMP`, then an atomic rename into place.
* **The encode runs on a 5-minute background context, not the request
  context.** A client disconnect does not abort it, so a re-request after your
  own timeout usually hits a warm cache. A naive 15 s HTTP timeout will fire on
  a long FLAC — budget accordingly and retry.
* Retagging or rewriting the source changes mtime/size ⇒ new cache key ⇒ fresh
  transcode; the old entry ages out.
* After a successful encode the cache dir is swept oldest-first (by mtime) down
  to `TRANSCODE_CACHE_MB` (default 5000 MB), never evicting the file about to be
  served.
* Range/seek works normally on the second and later requests, because the served
  entity is the cache file. A Range request on a cold cache still waits for the
  full encode first.
* `ETag`/`Last-Modified` are the **cache file's**, so they change if the entry is
  re-encoded. Treat them as opaque and re-validate.

#### Practical tier policy for a client

1. On startup read `GET /api/status`.
2. If `transcode == false`, hide/disable the high and low tiers entirely —
   otherwise every tiered request is a `501`.
3. For gapless bit-perfect playback, send **no `tier` param** and rely on Range.
   This keeps the URL byte-identical to the historic path (good for caches).
   `tier=original` is equivalent.
4. Seeking within a transcoded tier is byte-offset seeking into the cached Ogg,
   so a byte-fraction → time mapping is only approximate for VBR Opus. The
   original tier has the same caveat for VBR sources.
5. There is **no separate download endpoint** — downloads use this same URL.
   Derive the saved extension from `Content-Type` (`audio/ogg` → `.opus`) for
   tiered fetches, and from the track's own `format` for original.

---

## 5. Scrobbling (play reporting)

### `POST /api/plays`

Record one play. **The one endpoint where `profileId` is mandatory.**

* Body (32 KiB cap). Fields are decoded as `json.RawMessage` then required to be
  JSON **strings** — a number, `null`, or an absent key all count as missing:

```json
{"trackId": "…", "profileId": "…", "at": "2026-08-13T10:22:31.004Z"}
```

| Field | Rule |
| --- | --- |
| `trackId` | required, non-empty, must exist |
| `profileId` | required, non-empty, must exist |
| `at` | optional. **Exactly** `2006-01-02T15:04:05.000Z`. Arbitrarily far in the **past** is fine (offline replay); more than **5 minutes in the future** ⇒ 400. Absent ⇒ server stamps its own UTC now |

* `200 {"ok": true}`.
* Errors, all `application/json {"error": …}`: `400 "invalid json"`,
  `400 "trackId and profileId required"`, `400 "invalid at"`,
  `400 "unknown profile"`, `400 "unknown track"`, `500 "internal error"`.

#### When to report a play

The reference rule: **exactly once per track-play, when playback position first
reaches `min(30s, duration/2)`.** A duration of 0 or absent is treated as 60 s,
so the threshold becomes 30 s. The latch re-arms on every track change, so a
repeat/replay of the same track reports again.

`at` should be **the moment the threshold was crossed**, not the flush time.
Offline clients queue `{trackId, profileId, at}` and replay later with the
**original** timestamp.

#### Dedup

The insert is `INSERT … SELECT … WHERE NOT EXISTS` on the exact
`(trackId, profileId, at)` triple (`repo/plays.go:23-29`). A replayed queued
play the server already committed is silently ignored and **still returns
`200 {"ok":true}`** — the response cannot tell you whether a row was inserted.
Because `at` has millisecond precision, two genuine plays can only collide
inside the same millisecond.

#### ListenBrainz side effects

When a `listenbrainzToken` setting exists, a submit-listens call fires in a
goroutine **after** the insert, **unconditionally** — including when the dedup
suppressed the row. Consequences:

1. Replaying a queued offline play does **not** create a duplicate local play but
   **does** send a second listen to ListenBrainz.
2. The submitted `listened_at` is `time.Now().Unix()` at scrobble time, **not**
   the `at` you sent, so replayed offline plays land at the wrong time upstream.
3. Fire-and-forget: no retry queue, never affects the HTTP status.
4. Play history is never trimmed — all-time stats are genuinely all-time.

### `GET /api/stats`

All listening statistics in one SQL-side aggregate.

* Query:
  * `profileId` — optional. **Absent/empty means aggregate across ALL
    profiles**, not an error. A non-empty unknown id ⇒ `404` text/plain.
  * `counts` — optional. The literal value `"1"` adds `playCounts`; anything
    else omits it.
* `200`:

```json
{
  "profileId": "default",
  "history":  [{"id":"…","at":"…"}],
  "totalPlays": 4210,
  "totalSeconds": 981234,
  "week":  {"plays": 88, "seconds": 20114},
  "month": {"plays": 402, "seconds": 91002, "topArtist": {"name":"…","count":31}},
  "uniqueTracks": 1902,
  "topTracks":  [{"id":"…","count":12,"lastAt":"…"}],
  "topAlbums":  [{"albumId":"…","count":40}],
  "topArtists": [{"name":"…","count":90}],
  "recent":     [{"id":"…","at":"…"}],
  "playCounts": {"<trackId>": 3}
}
```

* `profileId` is `null` when the query param was absent/empty.
* `history` is the raw 30-day play list of **known** tracks, ordered oldest-first
  by play id — the client buckets it in its own timezone.
* `month.plays` / `month.seconds` are **inline keys**, not nested under a
  `window` object (embedded Go struct).
* `month.topArtist` is `null` when there is none.
* `topTracks` / `topAlbums` / `topArtists` / `recent` are capped at **50** and
  are `[]` rather than `null` when empty.
* `playCounts` (only with `counts=1`) covers **all** history and includes stale
  track ids.

### `GET /api/plays/counts`

Per-track counts over a rolling window — cheaper than `/api/stats?counts=1` and
period-scoped.

* Query:
  * `profileId` — optional; empty/absent = all profiles; non-empty unknown ⇒
    `404` text/plain.
  * `period` — `week` (7d) | `month` (30d) | `year` (365d) | `all` | `""`
    (default = all, no cutoff). Anything else ⇒ `400 {"error":"invalid period"}`.
* `200 {"counts": {"<trackId>": <int>}}` — always wrapped in `counts`; `{}` when
  nothing played, never `null`.
* Counts rows in `plays` with **no join to `tracks`**, so ids of deleted/moved
  files still appear.

#### Deleted-file skew

`/api/plays/counts` and `/api/stats`'s `totalPlays` / `week` / `month` count rows
referencing track ids no longer in `tracks`. `/api/stats`'s `topTracks`,
`topAlbums`, `topArtists`, `recent`, `history` and `/api/mixes` monthly/yearly
**join `tracks` and exclude them**. Cross-referencing the two will show counts
that do not add up. Resolve ids against `/api/tracks` and drop misses.

---

## 6. Playlists

### `GET /api/playlists`

* Query: `profileId` — optional. **Empty/absent returns ALL playlists of ALL
  profiles**, mixed together, with no error and no profile-existence check.
  Ordered by `createdAt`, then `id`.
* `200`: a JSON array (never `null`; `[]` when empty).

Manual element:

```json
{"id":"…","profileId":"…","type":"manual","name":"…",
 "createdAt":"…","updatedAt":"…","trackIds":["…"]}
```

Smart element:

```json
{"id":"…","profileId":"…","type":"smart","name":"…",
 "createdAt":"…","updatedAt":"…","rules":{ … }}
```

**A manual playlist never has `rules`; a smart one never has `trackIds`.**
`trackIds` is always present for manual (`[]` when none), preserves duplicates,
and is ordered by `pos`.

### `POST /api/playlists`

* Body:
  * `name` — required, non-blank after trim, ≤ 200 runes measured untrimmed,
    **stored untrimmed**.
  * `profileId` — required, must exist.
  * `type` — optional, defaults to `"manual"` when the key is **absent**. If
    present it must be exactly `"manual"` or `"smart"` (`null`, a number, or
    `""` ⇒ 400).
  * `rules` — required **and only allowed** when `type == "smart"`.
* Rules schema: `{"match":"all"|"any","rules":[{"field":…,"op":…,"value":…}]}`
  with ≤ 24 rule entries.

Legal field/op pairs (`playlists.go:19-41`):

| Fields | Ops |
| --- | --- |
| `title`, `artist`, `albumArtist`, `album`, `genre`, `composer`, `format`, `credited` | `is`, `isNot`, `contains`, `anyOf`, `allOf` |
| `year`, `playCount`, `loudness`, `dynamicRange`, `sampleRate`, `bitsPerSample` | `is`, `gt`, `lt` |
| `lossless`, `suspect` | `is` |
| `releaseType` | `is`, `isNot` |
| `addedDays` | `within` |
| `tag` | `is`, `isNot`, `anyOf`, `allOf` |

For `anyOf`/`allOf`, `value` must be a non-empty array of non-empty strings,
length ≤ 30. For every other op the `value` key must be **present** (any JSON
type, including `null`).

Numeric fields map onto merged-track keys (`year`, `loudnessLufs`,
`dynamicRangeLu`, `sampleRate`, `bitsPerSample`) and a **null value fails every
operator including `lt`** — "not measured" is not "quiet".

* `200`: the created playlist object.
* Errors: `400 {"error":"invalid name"|"unknown profile"|"invalid type"|"invalid rules"|"invalid body"}`;
  `500 {"error":"internal error"}`.

### `PATCH /api/playlists/{id}`

* Body: `{"name": string?, "rules": object?}` — both optional, presence-checked.
  An **empty body is legal** and still bumps `updatedAt`. `rules` on a manual
  playlist ⇒ 400. `rules` is **replaced wholesale**, not merged. `profileId`,
  `type` and `trackIds` in the body are silently ignored — a playlist's type and
  owner are fixed at creation.
* `200`: the full playlist object.
* Errors: `404` text/plain; `400 {"error":"invalid name"|"rules only valid on smart playlists"|"invalid rules"|"invalid body"}`.

### `DELETE /api/playlists/{id}`

`200 {"ok":true}`. Its `playlist_tracks` rows go with it. `404` text/plain for an
unknown id.

### `GET /api/playlists/{id}/tracks`

Resolve a playlist to actual track objects.

* Query: **none.** `profileId` is not accepted — smart `playCount` rules evaluate
  against the playlist's **own** `profileId`.
* `200`: a JSON array of full merged-track objects — the **exact same shape**
  `/api/tracks` serves, optional keys and all.
* **Manual**: exact stored order (by `pos`), duplicates repeated, ids no longer
  in the library silently skipped, **no cap**.
* **Smart**: rules evaluated live against the current library. An empty rules
  array ⇒ `[]`. Results are sorted by artist, album, `discNo`, `trackNo`
  (case-insensitive string compare; null disc/track sort as 0) and then
  **truncated to the first 500** — no paging, no total count.

### `POST /api/playlists/{id}/tracks`

Append **one** track to the end of a manual playlist.

* Body: `{"trackId": string}` — required, must name an existing track. There is
  no bulk add. **Duplicates are allowed** and appended again
  (`pos = COALESCE(MAX(pos),0)+1`).
* `200`: the full playlist object with updated `trackIds` and bumped
  `updatedAt` — no follow-up GET needed.
* Errors: `404` text/plain; `400 {"error":"cannot add tracks to a smart playlist"|"unknown track"|"invalid body"}`.

### `DELETE /api/playlists/{id}/tracks/{trackId}`

* **Removes ALL occurrences** of `trackId`, not just the first. An unknown or
  absent id is a silent no-op that still bumps `updatedAt`.
* `{trackId}` must be URL-escaped.
* `200`: the full playlist object.
* Errors: `404` text/plain; `400 {"error":"cannot remove tracks from a smart playlist"}`.

### Reorder: does not exist

There is **no reorder endpoint** at any position — no `PUT`/`PATCH` on
`/api/playlists/{id}/tracks`, no positional index in add or remove, and
`PATCH /api/playlists/{id}` accepts only `name` and `rules`. Ordering is strictly
append-only.

To reorder, a client must DELETE every track and re-POST them in the desired
order. Note that DELETE removes **all** copies of an id, so a list containing
duplicates cannot be rebuilt incrementally — it needs a full teardown.

---

## 7. Listen-later

### `GET /api/listenlater`

One profile's saved-for-later albums. **Self-cleaning**: entries whose album has
since arrived in the library are hard-deleted server-side during this GET and
omitted from the response.

* Query: `profileId`. Not optional in effect — the SQL is
  `WHERE profileId = ?`, so an **absent/empty `profileId` returns `[]`**
  silently (unlike `/api/playlists`, where empty means all). No 400, no
  existence check.
* `200`: a JSON array (`[]` when empty), newest first (`addedAt` DESC, then id):

```json
{"id":"rg:…","profileId":"…","artist":"…","title":"…","titleKey":"…",
 "upc":null,"deezerId":null,"cover":null,"date":null,"type":"album",
 "releases":["…"],"addedAt":"…"}
```

`releases` is **omitted entirely** when unset; `upc`, `deezerId`, `cover`,
`date` are present-but-null.

### `POST /api/listenlater`

Save an album by name; the server resolves it upstream to a universal id and
stores the denormalized card.

* Body: `profileId` (required, must exist — checked **before** the upstream
  lookup), `artist` (required, non-empty, **stored verbatim as sent**, not as
  Deezer spells it), `title` (required, non-empty), `deezerId` (optional int64;
  0/absent = resolve by name).
* `200`: the stored entry, same shape as a GET element. `title`, `type`,
  `cover`, `date`, `upc`, `releases` come from the **resolved upstream** album,
  while `artist` is the caller's spelling.
* Idempotent upsert: re-saving refreshes fields, and an earlier row for the same
  `deezerId` under a different id is deleted first.
* Errors: `400 {"error":"artist and title required"|"unknown profile"}`;
  `502 {"error":"lookup failed: <detail>"}`; `404` text/plain when the album
  resolves to nothing; `500 {"error":"internal error"}`.
* **Gotcha (verified at `listenlater.go:109`)**: a malformed JSON body causes the
  handler to `return` **without writing anything** — the client sees `200` with
  an empty body, not a 400. Validate client-side.

### `DELETE /api/listenlater/{id}`

* Query: `profileId` — **required in practice.** The delete is
  `WHERE profileId = ? AND id = ?`; omitting it deletes nothing and **still
  returns `200 {"ok":true}`**. There is no 404 path — any mismatch is a silent
  no-op.
* `{id}` must be URL-escaped (it contains a colon, e.g. `rg:abc-123`).

---

## 8. Tags

User tags and folders. Tag names also appear denormalised on each track's `tags`
array in `/api/tracks`, including every ancestor folder name.

### `GET /api/tags`

`200`: a JSON array (never `null`; `[]` when empty), ordered by `createdAt` then
`id`:

```json
{"id":"<uuid v4>","name":"…","parent":null,"folder":false,
 "items":[{"kind":"track","key":"…"}],"createdAt":"…"}
```

* `parent` — folder id, `null` when unfoldered. **One level only.**
* `items` — always an array, never `null`. `kind` is `track` | `album` |
  `artist`; `key` is a track id, an `albumId`, or a free-form artist name.

### `POST /api/tags`

* Body: `name` (required, non-blank after trim, ≤ 60 runes); `folder` (bool,
  optional, default false); `parent` (string|null, optional; must be the id of an
  existing **top-level folder**).
* `200`: the created tag object (`items` is `[]`).
* Errors, all `400 {"error":…}`: `invalid name`, `tag exists`
  (case-insensitive name clash), `invalid folder` (parent not a string /
  unknown / not a folder / itself), `folders cannot be foldered`
  (`folder:true` together with a `parent`), `invalid body`.

### `PATCH /api/tags/{id}`

* Body: `{"name": string?, "parent": string|null?}` — at least one key must be
  **present** or `400 {"error":"nothing to change"}`. `parent: null` un-folders.
* `200`: the full updated tag object, with `items` populated.
* Errors: `404` text/plain; `400 {"error":"nothing to change"|"invalid name"|"tag exists"|"invalid folder"|"folders cannot be foldered"}`.

### `DELETE /api/tags/{id}`

`200 {"ok":true}`. Children are **promoted to the deleted tag's parent**.
`404` text/plain for an unknown id.

### `PUT /api/tags/{id}/items`

Add one membership. Idempotent (`INSERT OR IGNORE`).

* Body: `{"kind":"track"|"album"|"artist", "key": string}` — `key` required,
  non-empty, ≤ 300 runes. `kind=track` validates the track exists; `kind=album`
  validates the album has tracks; `kind=artist` accepts **any** free-form name.
* `200`: the full refreshed tag object.
* Errors: `404` text/plain; `400 {"error":"cannot tag into a folder"|"invalid item"|"unknown track"|"unknown album"|"invalid body"}`.

### `DELETE /api/tags/{id}/items`

Remove one membership. **Legacy oddity: a DELETE that carries a JSON body.**

* Body: `{"kind": string, "key": string}` — **no validation.** Absent or
  mistyped fields simply match no row and the call still succeeds.
* `200`: the full refreshed tag object. `404` text/plain for an unknown tag id.

---

## 9. Radio & mixes

### `GET /api/radio`

* `200`: a JSON **array** (not an object), never `null`. The 30 hard-coded
  built-ins come **first**, in fixed source order, then the user's own, ordered
  by (`createdAt`, `id`).

Built-in element:

```json
{"id":"rp-main","name":"Radio Paradise Main (FLAC)",
 "url":"https://stream.radioparadise.com/flacm","genre":"Eclectic","builtin":true}
```

User element:

```json
{"id":"<uuid v4>","name":"…","url":"…","genre":null,"createdAt":"…"}
```

**Field-presence asymmetry:** built-ins carry `builtin:true` and **no**
`createdAt`; user stations carry `createdAt` and **no `builtin` key at all**
(absence, not `false`). So `builtin === true` identifies a built-in; anything
else is user-owned and deletable. `genre` is a plain `string` on built-ins but
`string|null` on user stations.

Built-in ids are a closed set: `rp-main`, `rp-mellow`, `rp-rock`, `rp-global`,
`soma-gs`, `soma-drone`, `soma-dso`, `soma-fluid`, `soma-sa`, `soma-lush`,
`soma-su`, `soma-ipr`, `soma-u80s`, `soma-boot`, `soma-trip`, `kexp`, `fip`,
`fip-jazz`, `fip-rock`, `fip-electro`, `fip-monde`, `naim`, `naim-jazz`,
`naim-class`, `swiss-class`, `swiss-jazz`, `swiss-pop`, `jazz24`, `nightride`,
`asp`.

The `url` is an **external stream URL the client plays directly** — aria does not
proxy it.

### `POST /api/radio`

* Body: `name` (required, non-blank after trim, ≤ 200 runes, **stored
  untrimmed**); `url` (required, ≤ 2048 chars, must match `(?i)^https?://` and
  parse with a non-empty host); `genre` (`string|null`, optional; explicit null
  or omitted ⇒ stored `null`; if present it is trimmed and must be non-empty and
  ≤ 40 runes). Non-string values are rejected as missing.
* `200` (**not 201**): the created station.
* Errors: `400 {"error":"invalid json"|"invalid name"|"invalid url"|"invalid genre"}`;
  `500 {"error":"internal error"}`.

### `DELETE /api/radio/{id}`

* `200 {"ok":true}`.
* `400 {"error":"builtin"}` when `id` is a built-in — checked **before** the DB,
  so it wins over any not-found. Built-ins cannot be removed or hidden
  server-side.
* `404` text/plain when no such user station exists.

### `GET /api/mixes`

Four ranked **track-id lists** for a home screen. The server returns ids only;
resolve them against your `/api/tracks` cache.

* Query: `profileId` — optional; empty/absent = all profiles; non-empty unknown
  ⇒ `404` text/plain.
* `200 {"daily": […], "weekly": […], "monthly": […], "yearly": […]}` — every
  value is an array, never `null`, possibly empty.

| Mix | Derivation | Cap |
| --- | --- | --- |
| `daily` | distinct artists played in the last 24 h → every in-library track by those artists → deterministic shuffle seeded by `YYYY-MM-DD + profileId` → globally-popular recordings stable-partitioned to the front | 50 |
| `weekly` | same with a 7-day window, seeded by `"<year>W<week>" + profileId` | 50 |
| `monthly` | plays since the start of the current calendar month → `GROUP BY trackId ORDER BY COUNT(*) DESC, MIN(plays.id)` | 50 |
| `yearly` | same from the start of the calendar year | 100 |

`daily`/`weekly` fall back to all favourites, then to all tracks, when the window
has no plays — so they are non-empty on a fresh library, and their ids are always
resolvable (drawn from `tracks`). `monthly`/`yearly` join `tracks`, so ids of
vanished files are excluded.

Stability: `daily` is stable for a calendar day and rotates; `weekly` is stable
for an ISO week. `/api/mixes` is recomputed per request and runs several
full-table queries — **do not poll it in a render loop.**

### `GET /api/newreleases`

"New releases you don't own" — recent releases by artists in your library, drawn
**only** from the local Deezer-discography enrichment cache. No network call is
made on this request.

* `200`: a JSON array, never `null`, ≤ 60 items:

```json
{"artist":"…","title":"…","cover":null,"date":"2026-05-01","type":"album","deezerId":123}
```

`artist` is the library `albumArtist` it was matched under. `cover` is
`string|null` (an empty string is normalised to `null`). `type` defaults to
`"album"`. **`deezerId` is omitted entirely when 0** (`omitempty`).

Selection: cached artists that are also library album artists; dates in the last
180 days and not in the future; titles already owned (edition-tolerant
normalisation) dropped; titles deduped globally; max 3 per artist; sorted by date
descending (stable); capped at 60. `[]` on a cold cache or empty library.

**Memoized 60 s server-wide** — polling faster is pointless.

---

## 10. Profiles & settings

### What a profile is

A **local listener identity** — like a TV or console user slot. It partitions
play history, playlists and listen-later lists. It is multi-user only in the
"household members share one server" sense.

**It is NOT authentication.** There is no login, no session, no header, no token,
and any client may name any profile id on any request.

### How the profile id is threaded

Never a header, never a cookie. It travels as an explicit `profileId`, and the
**form differs per endpoint**:

| Form | Endpoints |
| --- | --- |
| Query param `?profileId=` | `GET /api/playlists`, `GET /api/listenlater`, `DELETE /api/listenlater/{id}`, `GET /api/stats`, `GET /api/plays/counts`, `GET /api/mixes` |
| JSON body field | `POST /api/playlists`, `POST /api/listenlater`, `POST /api/plays` |
| Implicit (from the stored row — do not send) | `GET /api/playlists/{id}/tracks` — smart `playCount` rules evaluate against the playlist's own `profileId` |
| Not profile-aware at all | `GET /api/stream/{id}`, `/api/tracks`, `/api/art`, `PATCH /api/tracks\|albums\|artists`, `/api/settings`, tags, `/api/library/health`, `/api/library/duplicates`, `/api/logs`, `/api/radio`, favourites |

### Empty-vs-absent `profileId` is inconsistent — the single biggest footgun

| Call | Missing `profileId` does… |
| --- | --- |
| `GET /api/playlists` | returns **ALL profiles'** playlists mixed together, no error |
| `GET /api/stats`, `/api/plays/counts`, `/api/mixes` | aggregates over **ALL** profiles (empty string is a legal "all" scope); a non-empty **unknown** id ⇒ 404 |
| `GET /api/listenlater` | returns **`[]`** silently (SQL is `WHERE profileId = ''`) |
| `DELETE /api/listenlater/{id}` | deletes **nothing** and still returns `200 {"ok":true}` |
| `POST /api/playlists`, `POST /api/listenlater` | `400 {"error":"unknown profile"}` |
| `POST /api/plays` | `400 {"error":"trackId and profileId required"}` |

**Practical rule for a client:** hold a currently-selected profile id in client
state, initialise it from `GET /api/profiles` (the server guarantees at least
one; the seeded one is id `"default"`), and send it on **every** endpoint in the
first two rows of the threading table. **Never rely on a default.**

### `GET /api/profiles`

`200`: a JSON array (`[]`, never `null`), ordered by `createdAt`, `id`:

```json
{"id":"default","name":"Listener","color":"#6d3fd2","createdAt":"…"}
```

The server seeds one profile when the table is empty (`default` / `Listener` /
`#6d3fd2`), so the list is never empty in practice.

### `POST /api/profiles`

* Body: `name` (required, must be a JSON string, non-blank after trim, ≤ 60
  runes, **stored untrimmed**); `color` (required, must match
  `^#[0-9a-fA-F]{6}$` exactly — 3-digit hex and named colors are rejected).
* `200`: `{"id":"<uuid v4>","name":…,"color":…,"createdAt":…}`.
* Errors: `400 {"error":"invalid json"|"invalid name"|"invalid color"}`.

### `PATCH /api/profiles/{id}`

* Body: `{"name": string?, "color": string?}` — both optional and independently
  presence-checked (a JSON `null` counts as present and then fails validation).
  An empty body is legal and is a no-op that still returns the profile.
* `200`: the updated profile object.
* Errors: `404` text/plain **with trailing newline**;
  `400 {"error":"invalid json"|"invalid name"|"invalid color"}`.

### `DELETE /api/profiles/{id}`

* `200 {"ok":true}`. **Cascades**: its playlists (and their track rows), its
  plays, and its listen-later entries go with it.
* `400 {"error":"cannot delete last profile"}` when it is the only one left — so
  a client can always assume ≥ 1 profile exists.
* `404` text/plain with trailing newline for an unknown id.

### `GET /api/settings`

Settings are **global**, not per-profile.

```json
{"listenbrainzToken":"", "classicalDisplayArtist":true,
 "matchMaxDistance":0.10, "matchMinSeparation":0.25}
```

* `listenbrainzToken` is `""` when unset and is returned **in plaintext**.
* `classicalDisplayArtist` is the stored value `!= "0"`; unset ⇒ `true`.
* The two thresholds are read through the matcher's own reader, so an
  unparseable or out-of-range stored value is reported as the **default**, not as
  stored.

### `POST /api/settings`

Partial update. There is no `PATCH` — `POST` is the writer.

* Body, all four keys optional; absent keys untouched:
  * `listenbrainzToken` — string, ≤ 200 runes. A value that is **empty after
    trim DELETES** the stored token. The stored value is trimmed.
  * `classicalDisplayArtist` — bool. Also invalidates the cached merged
    `/api/tracks` view.
  * `matchMaxDistance` — number, must satisfy `0 < v <= 1`.
  * `matchMinSeparation` — number, must satisfy `0 < v <= 1`.
* `200 {"ok":true}` — it does **not** echo the settings; re-GET to read them back.
* Errors: `400 {"error":"invalid json"|"invalid token"|"invalid matchMaxDistance"|"invalid matchMinSeparation"}`.
* **Partial application is possible**: fields are written in order token →
  classicalDisplayArtist → matchMaxDistance → matchMinSeparation, so a later
  validation failure leaves earlier fields already saved.
* Changing the thresholds deliberately does **not** trigger re-matching — use
  `POST /api/match {"force":true}`.

---

## 11. Events (SSE)

### `GET /api/events`

The **only** push channel. There are no WebSocket endpoints.

* `200 text/event-stream`. Headers: `Content-Type: text/event-stream`,
  `Cache-Control: no-cache`, `Connection: keep-alive`,
  `X-Accel-Buffering: no`. **Never gzipped.**
* On connect the server writes the comment line `: connected\n\n`; every 25 s of
  idleness it writes `: ping\n\n`. **Comment lines start with `:` and must be
  skipped by your parser.** If you see nothing for > 25 s the connection is dead,
  not idle.
* Frames are always `event: <name>\ndata: <compact JSON>\n\n`.
* **No `id:` field and no `retry:` field are ever sent** — there is no
  `Last-Event-ID` replay. On disconnect, reconnect and re-read current state from
  the REST status endpoints.
* Slow subscribers **silently drop frames** (16-frame buffer, non-blocking send).
  Treat every frame as a **full snapshot, never a delta**; `done` can jump.
* On server shutdown the hub closes subscriber channels and the stream ends
  cleanly (EOF) — treat that as "reconnect", not "error".
* `500 {"error":"streaming unsupported"}` if the writer is not a `http.Flusher`
  (never in practice).
* Access-logged only at connect time.

### Exactly four event names

Verified against every `Hub.Publish` call site (`server/cmd/aria/main.go:85, 89,
97, 111`):

| `event:` | `data:` payload | Notes |
| --- | --- | --- |
| `scan` | `{"done": int, "total": int}` | **no `running` flag** — `POST /api/scan` is synchronous, so its HTTP response is the completion signal |
| `enrich` | `{"phase": string, "done": int, "total": int, "running": bool}` | always emitted |
| `analyze` | `{"phase": string, "done": int, "total": int, "running": bool}` | only when `status.analyze == true` |
| `fingerprint` | `{"phase": string, "done": int, "total": int, "running": bool}` | only when `status.fingerprint == true` |

Phase vocabularies:

* `enrich`: `idle`, `albums`, `sources`, `artists`, `discographies`,
  `popularity`, `composers`, `people`, `names`, `wikidata`, `faces`, and
  `matching` (matching is a phase of the enrichment pass — this is why there is
  deliberately no `/api/match/status`).
* `analyze`: `idle`, `loudness`.
* `fingerprint`: `idle`, `fingerprint`, `lookup`.

**Lifecycle for the three job events:** one frame with `running:true` on start; a
frame per phase change (`done` reset to 0, `total` set) and per completed item;
and a final frame with `running:false, phase:"idle"`. **That idle frame is the
documented signal to refetch `/api/tracks` and everything derived from it.**

Nothing else pushes events. Edits, settings changes, tag mutations and favourite
toggles are **not** announced — refetch after mutating.

---

## 12. Admin, jobs & health

### Jobs

All three job pairs share a shape: a `GET …/status` read and a fire-and-forget
`POST` kick that returns the status immediately. All statuses are
`{"phase": string, "done": int, "total": int, "running": bool}`.

| Route | Notes |
| --- | --- |
| `POST /api/scan` | **Synchronous.** `200 {"tracks": <int>}`. `409 {"error":"scan already running"}`; `500 {"error":"scan failed"}`. Runs on an app-lifetime context (a client disconnect does not abort it) and chains the enrichment passes afterwards |
| `GET /api/enrich/status` · `POST /api/enrich` | `500 {"error":"internal error"}` when no enricher is wired |
| `GET /api/analyze/status` · `POST /api/analyze` | `501 {"error":"audio analysis unavailable"}` when `status.analyze == false` |
| `GET /api/fingerprint/status` · `POST /api/fingerprint` | `501 {"error":"fingerprinting unavailable"}` when `status.fingerprint == false`. A missing `ACOUSTID_KEY` is deliberately **not** a 501 — fingerprints are still computed, only the lookup half stays dark |

### `POST /api/enrich/people`

Warm faces and bios for names currently on screen.

* Body: `{"names": [string, …]}` — a non-array reads as `[]`; entries must be
  strings of `< 200` runes; **capped at the first 50**.
* `200 {"queued": <int>}`.

### Matching

| Route | Behaviour |
| --- | --- |
| `GET /api/match/review` | `200`: array of `repo.Decision` for every non-matched album (`[]`, never null) |
| `GET /api/albums/{albumId}/match` | The stored decision. Read-only, no network. `404` text/plain (with newline) when no decision row exists |
| `POST /api/albums/{albumId}/match` | **Synchronous** re-decide (~13 s worst case) returning the fresh decision with candidates. `404` text/plain when the album has no tracks; `502 {"error":"matching unavailable"\|"matching failed"}` |
| `POST /api/match` | Library-wide kick. Body `{"force": bool}` — an absent/undecodable body is fine. `force:true` drops every **unpinned** decision so the whole library is re-decided; pins survive. `200`: the enricher status object |

`repo.Decision` (`repo/matches.go:13-31`):

```json
{"albumId":"…","album":"…","albumArtist":"…",
 "state":"matched|review|local","reason":"…",
 "releaseMbid":null,"releaseGroupMbid":null,"disambiguation":"",
 "distance":null,"separation":null,"pinned":false,"attempts":0,
 "decidedAt":"…","retryAfter":"…","candidates":null}
```

`album` and `albumArtist` are `omitempty`. `candidates` is raw JSON: an array of
`{"mbid":…,"title":…,…}` or `null`.

### Re-identification

| Route | Behaviour |
| --- | --- |
| `GET /api/identify/artist/{name}` | `200`: array of MB artist candidates (`[]` when none); `502 {"error":"musicbrainz unavailable"}` |
| `POST /api/artist/{name}/reidentify` | Body `{"mbid": string\|null}` — `null`/absent means "unpin"; any other value must match the MBID regex or `400 {"error":"invalid mbid"}`. `200`: the refreshed blob, or `{}` when the result is nullish. `502 {"error":"reidentify failed"}` |
| `GET /api/identify/album/{albumId}` | `200`: array of MB album candidates (`[]`); `404` text/plain when the album has no tracks; `502` |
| `POST /api/album/{albumId}/reidentify` | Same body rule. Invalidates the merged `/api/tracks` view. `200`: refreshed blob or `{}` |

### Edits

Edits are **global** — shared by every profile — and beat file tags **and**
enrichment in every view. Nothing is ever written back to the audio files.

#### `PATCH /api/tracks/{id}`

* Allowed keys (any other key rejects the **whole** patch): `title`, `artist`,
  `album`, `albumArtist`, `genre`, `year`, `trackNo`, `discNo`, `composer`,
  `work`, `movement`, `conductor`, `orchestra`.
* Value rules: `year`/`trackNo`/`discNo` ⇒ integer-valued number, `0..3000`
  inclusive; every other field ⇒ string, non-blank after trim, ≤ 300 runes,
  **stored trimmed**. A JSON `null` **clears** that override. An empty object or
  empty body is rejected as `invalid edits`.
* The patch **merges** over the stored overrides — unmentioned keys survive.
* `200`: the **full merged override map** for this track — *not* the track. E.g.
  `{"title":"Real Title","year":1975}`. `{}` when the last override was cleared
  (the storage row is deleted).
* Errors: `404` text/plain with newline; `400 {"error":"invalid edits"}` for bad
  JSON, an unknown key, **or any bad value — all-or-nothing, no partial
  application**; `500 {"error":"internal error"}`.
* Invalidates the cached `/api/tracks` view.

#### `PATCH /api/albums/{albumId}`

* Allowed keys: `album`, `albumArtist`, `genre`, `year`, `releaseType`, `label`,
  `date`, `country`, `catno`, `blurb`, `artSource`, `state`, `disambiguation`,
  `locked`.
* Value rules: `year` ⇒ integer `0..3000`; `locked` ⇒ bool; `releaseType` ⇒ one
  of `Album`, `EP`, `Single`, `Live`, `Compilation`; `state` ⇒ one of `matched`,
  `review`, `local`; `blurb` ⇒ string ≤ 4000 runes; `artSource` ⇒ `file` | `api`
  | `custom` (validated separately, **after** the generic pass); every other
  string field ⇒ non-blank after trim, ≤ 300 runes, stored trimmed. `null`
  clears.
* **`artVersion` is NOT an accepted client key** — sending it yields
  `400 invalid edits`. *(Verified at `edits.go:104-110`; one source map claimed
  otherwise.)* The server **injects** it into the patch whenever `artSource` is
  present.
* `200`: the full merged override map for the album. When `artSource` was in the
  patch the response additionally contains `"artVersion": <previous+1>`.
* Fan-out: `album`, `albumArtist`, `genre`, `year`, `artVersion` appear on
  **every track** of the album in `/api/tracks`; the rest surface through
  `/api/album/{albumId}/info`.
* Errors: `404` text/plain with newline when the album has no tracks;
  `400 {"error":"invalid edits"|"invalid artSource"|"no embedded art"}`
  (`artSource:"file"` with no embedded art);
  `502 {"error":"art fetch failed"}` (`artSource:"api"` and the fetch failed);
  `500 {"error":"art write failed"|"internal error"}`.
* Side effects: setting `state` takes effect **immediately** — `local` drops the
  album's derived MusicBrainz layer and marks it settled; any other value drops
  the derived layer and re-arms re-derivation. `artSource:"api"` may fetch and
  write the art slot. Always invalidates the merged view.

#### `PATCH /api/artists/{name}`

* Allowed keys: `type`, `area`, `born`, `died`, `image`, `bio`. `bio` ≤ 4000
  runes; the other five ≤ 300 runes, non-blank after trim, stored trimmed.
  `null` clears. An empty object is rejected.
* Keyed by **name, not id**, and the name need not exist in the library — **no
  404**; an unknown name simply creates the row.
* The row is stored under the **raw (original-script)** name, resolved
  server-side from the possibly-Latinised display name in the path. PATCHing
  `"Ryuichi Sakamoto"` and PATCHing the original-script spelling hit the same
  row. URL-escape the segment.
* `200`: the full merged override map. `400 {"error":"invalid name"}` when the
  path name exceeds 200 runes; `400 {"error":"invalid edits"}`.

#### `GET /api/edits/{kind}/{key}`

Editor support: the pre-override values plus current overrides, so a client can
offer "reset to original".

* `{kind}` must be `track` | `album` | `artist` — anything else ⇒ `404`
  text/plain with newline.
* `200 {"original": {…}, "overrides": {…}, "source": {…}|null}`.
  **`source` is present for `track` and `album` and absent entirely for
  `artist`** (verified at `edits.go:409, 475, 492`).
* `original` is file tags + enrichment **only**, never edits. Derived
  MusicBrainz corrections count as `original`, so ↺ reverts to the corrected
  value rather than to the wrong file tag.
* `track` original keys: `title`, `artist`, `album`, `albumArtist`, `genre`,
  `year`, `trackNo`, `discNo`, `composer`, `work`, `movement`, `conductor`,
  `orchestra`.
* `album` original keys: `album`, `albumArtist`, `genre`, `year`, `releaseType`,
  `label`, `date`, `country`, `blurb`, `state`, `disambiguation`, `locked`.
* `artist` original keys: `type`, `area`, `born`, `died`, `image`, `bio`.
* `source` shape when non-null:
  `{"kind":"musicbrainz","releaseMbid":…,"releaseTitle":…,"distance":num|null,"separation":num|null,"decidedAt":…,"pinned":bool,"recordingMbid":…}`.
  `releaseTitle` is `""` for a pinned decision; `recordingMbid` is track-only and
  omitted when empty.
* For `kind=artist` the key is raw-name-resolved exactly as PATCH does.
* `404` text/plain with newline for an unknown track id or an album with no
  tracks.

### `GET /api/library/health`

Read-only diagnostics. No job is started.

```json
{"counts":{"tracks":0,"albums":0,"analysed":0,"fingerprinted":0,"identified":0},
 "issues":[{"kind":"unmatched","count":0,"items":[]}, …]}
```

`issues` is **always a 7-element array in this fixed order**: `unmatched`,
`lowSeparation`, `missingArt`, `missingMbid`, `suspect`, `clipping`,
`unanalysed`.

Item shape: `{"albumId":…,"trackId":…?,"title":…,"subtitle":…?,"detail":…?}` —
`trackId`, `subtitle` and `detail` are **omitted when empty**. For album-level
items `title` = album and `subtitle` = albumArtist; for track-level items
`title` = track title and `subtitle` = track artist.

`count` is the **true total**; `items` is capped at **100** (`[]`, never null),
so `count > items.length` is normal and there is **no way to fetch the rest**.

Detail text by kind: `unmatched` → `"<state> · <reason>"`; `lowSeparation` →
`"<reason> · runner-up 0.31 away"`; `missingArt`/`missingMbid` → no detail
(album-level, no `trackId`); `suspect` → `"tagged flac, decodes as mp3"`;
`clipping` → `"true peak +1.3 dBFS"`; `unanalysed` → `"not analysed yet"`.

### `GET /api/library/duplicates`

Groups of tracks the library holds more than one copy of. Read-only — nothing is
deleted, and **no file path is returned by design**.

```json
{"key":"<md5 or acoustid>","exact":true,
 "tracks":[{"id":…,"albumId":…,"title":…,"artist":…,"album":…,
            "format":…,"duration":null,"sampleRate":null,
            "bitsPerSample":null,"lossless":false}]}
```

`exact: true` = byte-identical decoded audio (MD5); `false` = same recording
(AcoustID). All exact groups come first. An AcoustID group is **suppressed** when
every one of its tracks already appeared in an exact group. Tracks within a group
sort by id ascending; groups that fall below 2 surviving tracks are dropped
entirely. `[]` when there are none.

### Client logs

#### `POST /api/logs`

Batch-upload buffered client log lines. Opportunistically prunes the table
(30-day cutoff, then a 200k-row cap) on every call.

* Body cap is **1 MiB**, not the usual 32 KiB.
* `{"device": string (required, non-blank after trim),
   "entries": [{"ts":…,"level":…,"tag":…,"msg":…,"extra": <any JSON>}]}` —
  1..1000 entries.
* Over-long fields are **truncated, never rejected**: `device`/`ts`/`level`/`tag`
  to 256 bytes, `msg` to 8192 bytes, re-serialized `extra` to 8192 bytes. A JSON
  `null` `extra` is stored as absent. No validation of `ts` format or `level`
  vocabulary.
* `200 {"stored": <int>}` — always equals `len(entries)`.
* Errors: `400 {"error":"invalid json"}` (includes exceeding the 1 MiB cap),
  `400 {"error":"device required"|"entries required"|"too many entries"}`.

#### `GET /api/logs`

* Query: `limit` (default 200, clamped to max 2000; non-numeric or `<= 0` falls
  back to 200); `level` (exact match, empty = no filter); `device` (exact match).
  **No offset, no cursor.**
* `200`: a JSON array (`[]`, never null), **newest first** (`ORDER BY id DESC`):
  `{"id":int64,"device":…,"ts":…,"level":…,"tag":…,"msg":…,"extra":…?,"receivedAt":…}`.
* **`extra` is omitted when null, and when present it is the original JSON
  re-encoded AS A STRING — the client must JSON-parse it a second time.**

---

## 13. Paging rules — the complete picture

| Endpoint | Paging |
| --- | --- |
| `GET /api/tracks` | `limit` (≥ 1) + `offset` (≥ 0), applied **after** the whole-library merge. No total-count header — use `/api/status.tracks` |
| `GET /api/logs` | `limit` only, default 200, max 2000. No offset, no cursor |
| `GET /api/library/health` | `items` hard-capped at 100 per issue, `count` reports the truth. **No way to fetch the rest** |
| `GET /api/playlists/{id}/tracks` (smart) | truncated to the first **500**, no paging, no total count |
| `GET /api/playlists/{id}/tracks` (manual) | uncapped |
| `GET /api/stats` `top*`/`recent` | fixed `LIMIT 50` |
| `GET /api/mixes` | 50 / 50 / 50 / 100 |
| `GET /api/newreleases` | capped at 60 |
| Everything else | returns **everything**: `/api/playlists`, `/api/listenlater`, `/api/profiles`, `/api/tags`, `/api/radio`, `/api/library/duplicates`, `/api/plays/counts`, `/api/stats?counts=1` |

Watch out: `/api/plays/counts` and `/api/stats?counts=1` return the **full**
per-track map with no cap, which is large on a 100k-track library.

---

## Client implementation notes

Concrete gotchas, in rough order of how much damage they cause.

### Streaming

1. **Read `/api/status.transcode` before offering high/low tiers.** If it is
   `false`, every `?tier=high|low` request is a `501` — clamp to original.
2. `tier` matching is **case-sensitive** and lenient: `HIGH`, `bogus`,
   `original`, `""` and an absent param all mean bit-perfect passthrough. Only
   the exact strings `high` and `low` transcode.
3. **A cold-cache transcode blocks for a full-file ffmpeg encode** with no
   progress signal and no partial output. A 15 s HTTP timeout will fire on a long
   FLAC. Set a generous timeout, and know that a retry after a timeout usually
   hits a warm cache because the encode continues on a 5-minute background
   context regardless of your disconnect.
4. Original-tier `Content-Type` is absent for unknown extensions. Transcoded
   tiers are always `audio/ogg` regardless of source format.
5. `/api/stream/*` is never gzipped and always goes through `ServeContent` — you
   get real Range/206/304/416 semantics. Use them.
6. `/api/stream/{id}` takes **no `profileId`**. Playback carries no identity;
   report the play separately.

### Play reporting

7. Report **once** per track-play at `min(30s, duration/2)`; treat a
   missing/zero duration as 60 s. Re-arm the latch on every track change.
8. Send `at` as the moment the threshold was crossed, not the flush time — and
   in **exactly** `2006-01-02T15:04:05.000Z`. Anything else is a `400`.
9. `at` may be arbitrarily old (offline replay) but not more than 5 minutes in
   the future.
10. The dedup on `(trackId, profileId, at)` means a replayed play returns
    `200 {"ok":true}` whether or not a row was written. **You cannot detect a
    duplicate from the response.**
11. But the ListenBrainz submit fires anyway on a deduped replay, and uses
    `time.Now()` rather than your `at`. Expect upstream duplicates and skewed
    timestamps from offline replay.

### Profiles

12. **Thread `profileId` explicitly on every profile-aware call.** There is no
    header, cookie or session. The form differs: query param on the GETs, body
    field on the POSTs.
13. Omitting it is *not* uniformly an error — it means "all profiles" on
    stats/counts/mixes/playlists, `[]` on listen-later, and a **silent no-op that
    returns `{"ok":true}`** on `DELETE /api/listenlater/{id}`. Never rely on a
    default.
14. Initialise from `GET /api/profiles`; the server guarantees ≥ 1 (it refuses to
    delete the last one) and seeds `"default"`.
15. Deleting a profile cascades to its playlists, plays and listen-later rows.

### Error handling

16. **Never `json.Unmarshal` a 404 body.** Two of the three error shapes are
    plain text, and they differ by a trailing newline depending on which helper
    the handler used.
17. Success is always `200` — no `201`, no `204`. Do not branch on those.
18. Body caps surface as `400 invalid json`/`invalid body`, not `413` (the one
    exception is art upload, which does return `413`).
19. `POST /api/listenlater` with a malformed body returns **`200` with an empty
    body**, not a `400` — the handler returns without writing. Validate before
    sending.

### Data model traps

20. **Latinisation.** `/api/tracks` serves **Latin display names** for `artist`,
    `albumArtist`, `composer`, `conductor`, `orchestra` and `performers[].name`.
    The enrich cache, edit rows and tag items are keyed by the **raw
    original-script** name. `/api/artist/{name}`, `/api/composer/{name}` and
    `PATCH /api/artists/{name}` resolve the Latin name back for you — so pass
    names exactly as `/api/tracks` served them. But `/api/people` returns a
    **mix** of raw and Latin keys, so its keys will not always match. Artist tag
    matching is done against both spellings server-side.
21. **`genre` vs `genres`.** `genre` is the untouched raw file-tag string (may be
    null, may be a multi-value mess) — **display** it. `genres` is the derived
    canonical array (file tag split through the closed taxonomy, unioned with
    MusicBrainz/Discogs genres and styles) — **browse and filter** on it.
22. **Null analysis fields must stay null.** `trackGainDb`, `albumGainDb`,
    `trackPeak`, `albumPeak`, `loudnessLufs`, `dynamicRangeLu` are null when the
    track has not been analysed. Coercing null to 0 means applying DSP on no
    evidence, and a smart rule must **fail** `> -14 LUFS` rather than pass it.
    `suspect` is the one non-null default: `false` means "nothing has contradicted
    the container", not "verified genuine".
23. **Optional keys are absent, not null.** `orchestra`, `performers`,
    `albumArtists`, `artVersion` on tracks; `releases` on listen-later; `extra`
    on logs; `trackId`/`subtitle`/`detail` on health items; `builtin` vs
    `createdAt` on radio stations; `deezerId` on new releases. Decode into maps
    or use pointer/optional types — naive struct decoding will silently
    misrepresent these.
24. **Playlists carry either `trackIds` (manual) or `rules` (smart), never
    both.**
25. Setting an album edit's `albumArtist` **deletes** the `albumArtists` array
    from every track of that album.
26. `albumId` must be 40-char lowercase hex for art and booklet routes, which
    validate before doing anything else.

### Mutation semantics

27. **Playlist reorder does not exist.** Add appends one id; remove deletes
    **all** occurrences of an id. Rebuilding a list containing duplicates
    requires a full teardown.
28. Every playlist mutation (including an empty `PATCH`) returns the whole
    playlist object and bumps `updatedAt` — you never need a follow-up GET.
29. **Edits are all-or-nothing and merge-based.** One unknown key or one bad
    value rejects the entire patch with `400 invalid edits` and writes nothing.
    A successful patch returns the **merged override map, not the entity** — keep
    the entity and its overrides as separate client state and use
    `GET /api/edits/{kind}/{key}` to render "original vs override".
30. Sending `null` is the **only** way to clear a field; sending `""` is rejected
    as blank.
31. `PUT /api/tracks/{id}/favourite` has absolute semantics and coerces anything
    non-boolean to `false`. Read the current value from the track's `favourite`
    field first, then send a real JSON boolean.
32. `POST /api/settings` applies fields in order and stops at the first
    validation failure, leaving earlier fields already saved.
33. `DELETE /api/tags/{id}/items` performs **no validation** — a typo'd `kind` or
    `key` matches no row and still returns `200` with the unchanged tag.

### Caching & freshness

34. **There are no `ETag`/`Last-Modified` headers on any JSON route** — a client
    cannot cheaply detect staleness and must refetch after any mutation.
35. `/api/tracks` is cached server-side until an explicit invalidation. Any tag
    mutation, favourite toggle, edit, scan, or enrichment run invalidates it, so
    a mutation followed immediately by a refetch **does** see fresh data.
36. `/api/people` and `/api/newreleases` are memoized **60 s** server-side —
    polling faster is pointless.
37. `/api/mixes` and `/api/plays/counts` are recomputed per request, and mixes
    runs several full-table queries. **Do not poll them in a render loop.**
38. Album art and portraits are `max-age=31536000` with an `ETag`. **You must
    append the track's `artVersion` as a query token to bust that cache** after
    an art change. External covers are `max-age=2592000`; booklets are `private,
    no-cache`.

### SSE

39. Exactly four event names: `scan`, `enrich`, `analyze`, `fingerprint`.
40. Skip comment frames (`: connected`, `: ping` every 25 s). No frames for
    > 25 s means the connection is dead.
41. No `id:` and no `retry:` — there is **no `Last-Event-ID` resume**. On
    reconnect, re-read `GET /api/status`, `/api/enrich/status`,
    `/api/analyze/status`, `/api/fingerprint/status`.
42. Frames are **dropped** for slow consumers. Treat each frame as a snapshot,
    never a delta; `done` can jump.
43. Use the `running:false, phase:"idle"` frame as your refresh trigger instead
    of polling. `scan` has no `running` flag — `POST /api/scan` is synchronous,
    so its HTTP response is the completion signal.
44. Edits, settings, tags and favourites are **not** announced over SSE. Refetch
    after mutating.
45. Reverse proxies must not buffer the stream (the handler sets
    `X-Accel-Buffering: no`).

### Miscellaneous

46. **No search endpoint exists.** Fetch `/api/tracks` once and do all grouping,
    searching and filtering client-side.
47. Reachability equals full access. `GET /api/settings` leaks
    `listenbrainzToken` in plaintext — mask it in your settings view.
48. `GET /api/logs`'s `extra` needs a **second** JSON parse.
49. URL-escape path segments that can contain arbitrary text or punctuation:
    artist names, composer names, playlist track ids, and listen-later ids
    (which contain a colon, e.g. `rg:abc-123`).
50. `GET /api/health` does not exist — the diagnostics route is
    `GET /api/library/health`, and the container probe is `GET /healthz`
    (body `ok`, plain text).

---

## Appendix: complete route table

Verified from every `mux.HandleFunc` registration in `server/internal/api/`.

```
GET    /healthz

GET    /api/status
POST   /api/scan
GET    /api/tracks
PUT    /api/tracks/{id}/favourite
GET    /api/genres
GET    /api/album/{albumId}/info
GET    /api/artist/{name}
GET    /api/composer/{name}
GET    /api/lyrics/{id}

GET    /api/art/{albumId}
POST   /api/art/{albumId}
GET    /api/albums/{albumId}/booklets
GET    /api/albums/{albumId}/booklet/{name}

GET    /api/stream/{id}

POST   /api/plays
GET    /api/stats
GET    /api/plays/counts
GET    /api/newreleases
GET    /api/mixes

GET    /api/playlists
POST   /api/playlists
PATCH  /api/playlists/{id}
DELETE /api/playlists/{id}
GET    /api/playlists/{id}/tracks
POST   /api/playlists/{id}/tracks
DELETE /api/playlists/{id}/tracks/{trackId}

GET    /api/listenlater
POST   /api/listenlater
DELETE /api/listenlater/{id}

GET    /api/tags
POST   /api/tags
PATCH  /api/tags/{id}
DELETE /api/tags/{id}
PUT    /api/tags/{id}/items
DELETE /api/tags/{id}/items

GET    /api/radio
POST   /api/radio
DELETE /api/radio/{id}

GET    /api/profiles
POST   /api/profiles
PATCH  /api/profiles/{id}
DELETE /api/profiles/{id}

GET    /api/settings
POST   /api/settings

GET    /api/events

GET    /api/enrich/status
POST   /api/enrich
POST   /api/enrich/people
GET    /api/people
GET    /api/people/img/{name}
GET    /api/analyze/status
POST   /api/analyze
GET    /api/fingerprint/status
POST   /api/fingerprint

GET    /api/match/review
GET    /api/albums/{albumId}/match
POST   /api/albums/{albumId}/match
POST   /api/match
GET    /api/identify/artist/{name}
POST   /api/artist/{name}/reidentify
GET    /api/identify/album/{albumId}
POST   /api/album/{albumId}/reidentify

PATCH  /api/tracks/{id}
PATCH  /api/albums/{albumId}
PATCH  /api/artists/{name}
GET    /api/edits/{kind}/{key}

GET    /api/library/health
GET    /api/library/duplicates
GET    /api/logs
POST   /api/logs

GET    /api/extalbum
GET    /api/extalbum/img
GET    /api/eq/opra
```

There is no `/api/search`, no `GET /api/albums`, no `GET /api/artists`, no
`/api/match/status`, and no WebSocket endpoint.
