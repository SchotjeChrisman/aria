# Match review: giving the review queue a face

Date: 2026-07-30 · Status: approved, implementing · Scope: client-only

## The problem

Aria's matcher classifies every album into `matched`, `review` or `local`. On the
live library that is 535 / 28 / 41. The 69 non-matched albums are the ones the
matcher deliberately declined to decide — a weak match, or two candidate
releases it could not separate.

**Nothing in any client shows them.** `GET /api/match/review` has zero callers.
So do `GET /api/albums/{id}/match` and `POST /api/albums/{id}/match`, which
return the scored candidates. The review half of the feature was built
server-side in 3.5.0 and never given a UI.

What exists client-side is `reidentifyAlbum(albumId, mbid)` — reachable from the
album page — which pins a release **if you already know which one you want**.
There is no surface that says: here are the uncertain albums, here is why each
one is uncertain, here are the candidates the matcher scored, pick one.

Secondary problem: the library health report *does* exist
(`/settings/health`) but sits three taps deep behind a tile that says only
"Library health". The owner of the library did not know it was there.

## What is being built

A review queue in the Flutter app, next to the health screen. No server changes.

### Why client-side and not a server web UI

The request that started this was for a server-rendered admin UI. Investigation
changed the answer: the gap was not the platform, it was that the feature had no
client at all. Building it in the app that already has the health screen, the
API client, the theming and the navigation costs a fraction of standing up an
HTML surface on a server that today serves no HTML whatsoever — and avoids a
second UI that would drift from the first.

## Components

### 1. `aria_api` — two models, three methods

`MatchDecision`: albumId, album, albumArtist, state, reason, releaseMbid,
releaseGroupMbid, disambiguation, `distance: double?`, `separation: double?`,
pinned, attempts, decidedAt, candidates.

`MatchCandidate`: mbid, rgMbid, title, artist, date, country, tracks, media,
source, `distance: double?`, `why: Map<String, double>`.

`MatchCandidate` is deliberately **not** a reuse of the existing
`AlbumCandidate`. That model serves `/api/identify/album/{id}` and carries
`score` — MusicBrainz search relevance, where **higher is better**. This one
carries `distance` — matcher distance, where **lower is better**. One model
holding both fields is how a future change sorts the list backwards. They are
different payloads from different endpoints with opposite orderings; they stay
separate.

New client methods: `matchReview()`, `albumMatch(id)` (404 → null),
`rematchAlbum(id)`. Reused unchanged: `reidentifyAlbum(id, mbid:)` and
`patchAlbum(id, {'state': 'local'})`.

### 2. `lib/features/review/`

- `review_providers.dart` — the queue, and a per-album decision family.
- `review_screen.dart` — sectioned list: "Needs review" (`state == review`)
  then "No match found" (`state == local`). Each row: album, artist, a reason
  chip, the distance.
- `review_detail.dart` — candidates as selectable cards, each expanding to the
  `why` breakdown, above an action bar.

#### The two sections need different affordances

Measured against the live library, the split is not cosmetic:

| state | reason | n | candidates |
| --- | --- | --- | --- |
| `review` | `weak-match` | 16 | 1–2 |
| `review` | `low-separation` | 12 | 2–12 |
| `local` | `no-candidates` | **40** | **0** |
| `local` | `no-plausible-candidate` | 1 | 3 |

**58% of the queue has no candidates at all.** MusicBrainz returned nothing for
those albums, so a candidate picker renders an empty list and the screen has
nothing to say. The dominant case cannot be the edge case.

So the detail view branches on `candidates.isEmpty`, not on state:

- **With candidates** — the picker, the `why` breakdown, Accept.
- **Without** — no picker. State plainly that MusicBrainz returned no
  candidates, and offer the two actions that can actually help: *Try again*
  (`rematchAlbum`), and *Search MusicBrainz* — which opens the **existing**
  `reidentify_dialog`, already backed by `identifyAlbum(albumId)` for a manual
  title search. That flow is built; the review screen routes to it rather than
  reimplementing a search box.

"Use my tags" is hidden for albums already in `state == local`, where it is a
no-op.

`retryAfter` is surfaced on these rows ("retries automatically on …"). Every
one of the 40 carries a real timestamp, and knowing the server will try again
on its own is usually the answer to "do I need to do something about this?"

### 3. Discoverability

Route `/settings/review` alongside `health`, and **counts on both Library
tiles**. This is the actual fix for the screen nobody found: a tile reading
"69 albums need review" advertises itself, one reading "Library health" does
not.

## Data flow

Opening the queue costs one local query. The candidates were scored during the
enrichment pass and persisted in `match_decisions.candidates`, so the screen
reaches no external service to render.

| Action | Call | Effect |
| --- | --- | --- |
| Accept a candidate | `reidentifyAlbum(id, mbid:)` | Pinned in `match_decisions`; `PendingAlbums` excludes it permanently |
| Re-queue | `reidentifyAlbum(id, mbid: null)` | Unpins, fresh search next pass |
| Use my tags | `patchAlbum(id, {'state':'local'})` | Drops the derived MusicBrainz layer |
| Try again | `rematchAlbum(id)` | Re-scores synchronously, ~13 s |

Every action invalidates the queue, the health report and the merged tracks
view.

## Error handling

- **An empty queue is the success state**, not an error: "Nothing needs review."
- `rematchAlbum` is synchronous and can take ~13 s. The button carries the
  progress; its two real failures (`502 matching unavailable` when the enricher
  is not a matcher, `502 matching failed`) surface rather than reading as a
  no-op.
- **`distance` and `separation` are nullable and must render as "—", never
  `0.0`.** This is the same bug class that bit the smart-playlist numeric
  predicates, where `toNum(nil)` returning `0` made every unanalysed track the
  quietest in the library. A null distance means "not scored", and a UI that
  prints `0.00` claims the opposite of the truth — a perfect match.
- **`separation` can arrive as a JSON integer.** Go marshals a float64 `0` as
  `0`, not `0.0`, and the live library contains exactly one such decision. In
  Dart `j['separation'] as double` **throws** on that value, taking the whole
  screen down over one album in sixty-nine. Every numeric field on both models
  parses through `(j[k] as num?)?.toDouble()`. `tracks` and `media` are ints and
  parse as `num?` → `toInt()` for the same reason in reverse.
- `releaseMbid` and `releaseGroupMbid` are null on **every** row in the live
  queue — unsurprising, since these are the albums with no accepted release. No
  UI element may assume they are present.

## Testing

Model parsing and the queue counting logic. The app does widget-test some
screens (`library_page_scroll_test.dart`), but these are cheaper as unit tests
and the widget harness here needs the player stubbed out to avoid tripping the
pending-timer invariant.

The parsing tests are written against **the real payload**, not invented
fixtures. Required cases, each drawn from something the live server actually
returns:

- `separation: 0` as a bare JSON integer (one real decision)
- `distance: null` and `separation: null` (40 and 55 real decisions)
- `candidates: []` (40 real decisions)
- a `why` object with keys missing, and with an unknown key added — the server
  is free to add a distance component without a client release
- `releaseMbid: null` / `releaseGroupMbid: null` (every real decision)

## Not building

- **Bulk accept.** Considered and declined. Accepting matches nobody looked at
  is how a library fills with confident wrong answers, and the `review` state
  exists precisely because the matcher already refused to auto-accept these.
- **A server web UI.** Superseded, see above.
- **A deep link from the album page into review.** Natural follow-up, out of
  scope here.
- **Auth.** The server has none: 74 routes, all open on the LAN. Every endpoint
  this screen calls is already reachable by anything on the network, so this
  adds no exposure. It does not reduce any either, and a new admin-shaped
  surface should not be read as implying the API is protected.
