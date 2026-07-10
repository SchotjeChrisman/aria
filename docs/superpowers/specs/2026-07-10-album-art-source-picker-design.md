# Album Art Source Picker — Design

Date: 2026-07-10

## Problem

Album art in Aria is a single immutable file per album at
`DATA_DIR/art/{albumId}.jpg`. It is extracted from embedded file tags at scan
time, with an API fallback (Cover Art Archive → Deezer) fetched only when a file
has no embedded cover. There is no way for a user to see the alternatives or
choose which one an album uses, and no way to supply custom art.

This adds a per-album **art source picker** in the edit dialog with three
choices — **File** (embedded), **API** (remote fetch), **Custom** (upload) —
with File as the default so the actual library files lead.

## Non-goals

- Track-level art. Art is album-level in Aria; tracks are unaffected.
- Changing the default resolution behavior for albums with no override.
- Pre-downloading API art for albums the user never touches.
- Migrating existing on-disk art (see "Migration" below — deliberately skipped).

## Data model

Add `artSource` to the album edit group. Allowed values: `file` | `api` |
`custom`. Absent = default resolution (unchanged behavior). Reuses the existing
`edits` table and PATCH flow — **no new table, no schema migration**.

- `server/internal/api/edits.go`: add `"artSource"` to the allowed **album**
  edit fields.

## Disk layout

Split the single ambiguous slot into three source-owned slots per album:

| Slot | Source | Written by |
|------|--------|------------|
| `art/{albumId}.jpg` | file (embedded) | scanner only |
| `art/{albumId}.api.jpg` | api | enrich fallback; or on pick=api |
| `art/{albumId}.custom.jpg` | custom | upload endpoint |

**Behavioral change:** enrich currently writes its API fallback to
`{albumId}.jpg`. It now writes to `{albumId}.api.jpg` instead, so the `.jpg`
slot only ever holds genuine embedded art.

## Serving — `GET /api/art/{albumId}` (`server/internal/api/art.go`)

Extend the handler with an optional `?source=` query param:

- **No `source`** → resolve stored `artSource` for the album:
  - `file` → serve `.jpg`
  - `api` → serve `.api.jpg`
  - `custom` → serve `.custom.jpg`
  - none set → `.jpg` if it exists, else `.api.jpg` (preserves today's visible
    behavior)
- **`?source=file|api|custom`** → serve exactly that slot (used by the dialog
  thumbnails).
- **`?source=api` with no `.api.jpg` on disk** → fetch remote using enrich's
  existing MBID → Cover Art Archive → Deezer logic and **stream the bytes
  without persisting**. This is the live preview; nothing is written until the
  user picks API.

Keep existing caching semantics (ETag by mtime+size, `ServeContent`) for
on-disk slots. The streamed preview is served without the long-lived immutable
cache header (it is transient and may change).

## New endpoints

- **`POST /api/art/{albumId}`** (multipart image upload) → write
  `art/{albumId}.custom.jpg`, set the album `artSource=custom` edit. Validate
  content-type is an image and enforce a sane max size.
- **Picking a source** is an ordinary album edit PATCH setting `artSource`.
  When set to `api`, the backend fetches remote and writes `.api.jpg` (the
  "download when picked" step). When set to `file` or `custom`, no fetch.

## Cache-busting

Art is served `Cache-Control: public, max-age=31536000` (immutable), so a source
switch is invisible to clients that already cached `/api/art/{albumId}`. Add a
version token to the Flutter URL builder:

- `aria_api/lib/src/client.dart`: `artUrl(albumId, {version})` appends
  `?v=<token>`. The token changes whenever the album's art changes
  (source switch or custom re-upload). Source: an art-version value carried on
  the album/track payload — reuse the album edit's `updatedAt`/version if one
  exists, otherwise add a monotonic art counter bumped on any art edit or
  upload. After a save, the frontend invalidates the album/track providers so
  the new token propagates.

## Flutter edit dialog (`app_flutter/lib/features/album/edit_metadata_dialog.dart`)

Add an art-source row (album edits only):

- Three thumbnails — **File / API / Custom** — each an `ArtImage` loading
  `artUrl(albumId, source: …)` (preview URLs, cache-busted per open).
- Tapping a thumbnail selects that source; the selection is saved as the
  `artSource` album edit on dialog save.
- **File** thumbnail is disabled/greyed when the album has no embedded art
  (`.jpg` slot empty).
- **Custom** has an image-picker + upload button; a successful upload posts to
  `POST /api/art/{albumId}`, then selects Custom.

`ArtImage` (`app_flutter/lib/widgets/art_image.dart`) gains an optional
`source`/explicit-URL path so the same widget renders each variant; its existing
fallback chain (network → offline → initials) is preserved.

## Error handling

- API preview fetch fails (no MBID, remote down, rate-limited) → the API
  thumbnail shows the standard `ArtImage` fallback; selecting API is still
  allowed but will retry the fetch on pick and surface a snackbar on failure.
- Upload rejects non-images and oversized files with a 4xx; dialog shows an
  error and keeps the previous selection.
- Selecting `file` when no embedded art exists is prevented in the UI (disabled)
  and rejected server-side for safety.

## Migration (deliberately skipped)

Existing installs have API-fallback images already sitting in the `.jpg` slot
(from before this change). After deploy, those albums will show that existing
image under **File** until the album is rescanned (rescan re-extracts embedded
art into `.jpg` and, finding none, enrich writes API art to `.api.jpg`). This is
an accepted cosmetic quirk for already-enriched albums, not a correctness bug —
no migration script. Documented here so it is not a surprise.

## Testing

- Backend: unit-test source resolution in `art.go` (each `artSource` value + the
  none-set fallback + missing-slot preview branch). Test the upload endpoint
  (valid image writes slot + sets edit; non-image/oversized rejected). Test that
  enrich writes to `.api.jpg`, not `.jpg`.
- Frontend: widget test that the dialog renders three thumbnails, disables File
  when embedded art is absent, and saves the chosen `artSource`.

## Files touched

Backend:
- `server/internal/api/art.go` — `?source=` resolution + preview streaming
- `server/internal/api/edits.go` — allow `artSource` album field
- `server/internal/api/*` (routing) — register `POST /api/art/{albumId}`
- `server/internal/enrich/enrich.go` — write API art to `.api.jpg` slot
- art-version token plumbing on the album/track payload

Frontend:
- `app_flutter/packages/aria_api/lib/src/client.dart` — `artUrl` source +
  version params, upload call
- `app_flutter/lib/widgets/art_image.dart` — per-source rendering
- `app_flutter/lib/features/album/edit_metadata_dialog.dart` — art-source row
