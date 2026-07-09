# Home mixes, cross-field filter AND/OR, dropdown-dismiss fix

Date: 2026-07-09

Three independent changes to aria (Go server + Flutter app).

## 1. Home mixes (server-side)

Add daily / weekly / monthly / yearly mixes, shown in one "Your Mixes" shelf on
the home screen. All four are computed **server-side** (consistent with stats /
smart playlists); the client only renders.

### Server: `GET /api/mixes?profileId=…`

New handler (`server/internal/api/mixes.go`) returning four ranked `trackId`
lists:

```json
{ "daily": ["id", …], "weekly": [...], "monthly": [...], "yearly": [...] }
```

| Mix | Query |
|-----|-------|
| daily | distinct artists from this profile's plays in the **last 1 day** → all tracks by those artists → deterministic seeded shuffle → cap 50. If no plays in window: favourites, else random tracks. |
| weekly | same, **last 7 days** |
| monthly | plays since **start of current calendar month** → `GROUP BY trackId ORDER BY COUNT(*) DESC` → cap 50 |
| yearly | plays since **start of current calendar year** → same → **LIMIT 100** |

- Window cutoffs are ISO-string comparisons on `plays.at` (existing pattern in
  `plays.go`). `time.Now()` server-side; year/month start in server local time.
- Seed for daily/weekly shuffle = hash of `date(+week) + profileId` so a mix is
  stable within its period and rotates after. `math/rand` with that seed.
- Route registered next to the existing `/api/stats` route.
- `ponytail:` monthly/yearly recompute per request; cache if it shows up hot.

### Client

- `Mixes` model + `client.mixes(profileId)` in `aria_api` (mirror `stats()`).
- `mixesProvider` (FutureProvider, re-fetched on profile switch like
  `homeStatsProvider`); maps each `trackId` list → `List<Track>` via the library
  cache (`trackByIdProvider`), dropping unknown ids.
- Display titles computed client-side from the local date: "Daily Mix",
  "Weekly Mix", "<Month> Mix", "<Year> Top 100".
- Home: one `Shelf` titled "Your Mixes" with 4 cards (themed gradient + icon +
  title/subtitle), inserted in `_HomeBody` after New Releases. Empty mixes are
  hidden. Tap → `mix_screen`.
- `mix_screen.dart`: title + track list (reuse existing track-row widgets) +
  play-all via `ref.read(queueProvider.notifier).playQueue(tracks, 0)`. New
  go_router route.

## 2. Filters: cross-field AND/OR

Add a `combine` mode to both filter states: `'all'` (default, current — every
active field must pass) and `'any'` (item passes if it matches **any** active
field).

- `TrackFilters`: add `combine`; refactor `trackPassesFilters` to evaluate each
  active field to a bool then combine (all → every, any → some). `isEmpty`
  short-circuit unchanged. UI: a "Match all / Match any" control in the filter
  dialog header, persisted through Apply.
- `AlbumFilters`: add `combine`; thread through `_trackPasses` (combine the
  genre/format/tag/decade predicates). UI: a "Match: All/Any" pill in the album
  filter bar.

## 3. Dropdown stays open after tapping outside

`multi_select_field.dart`: the inline option list shows on
`showList = _focus.hasFocus || q.isNotEmpty` with no tap-outside handler, so
leftover search text pins it open and blocks the next field.

Fix: `showList = _focus.hasFocus` (typing implies focus) **and** add
`onTapOutside: (_) => _focus.unfocus()` to the search `TextField`.

## Verification

- `go build ./...` (server), `flutter analyze` (app).
- Unit checks: seeded-shuffle determinism (same seed → same order), combine-mode
  pass logic (any vs all).
- Run app: mixes shelf renders, mix opens & plays, dropdown dismisses on outside
  tap, album/track filters honor Match Any/All.

## Out of scope

Persisted/editable mixes, cover-art montages, similarity/ML recommendations,
within-field AND/OR on album filters.
