# OPRA EQ: de-duplication, playback-break fix, cleaner browse UI

Date: 2026-07-09

Three defects in the layered OPRA EQ feature (shipped v2.7.0), all diagnosed
against the real OPRA feed (`https://opra.roonlabs.net/database_v1.jsonl`,
19.5k JSONL lines, 12.6 MB, fetched during investigation).

## 1. Duplicate EQ names within one headphone

**Root cause.** OPRA keys multiple `eq` records per headphone. When one author
(almost always `AutoEQ`) has several measurements of the same headphone, the
records differ *only* by a `details` string ("Measured by Harpo", "ANC on/off",
etc.). The server (`enrich/opra.go`) parses `author` + `parameters` and
**discards `details`**; the app renders only `author`. Result: identical-looking
rows ("AutoEQ, AutoEQ, AutoEQ").

Measured impact: **2016 / 6229 headphones** have duplicate-author EQs;
**100%** of those records carry a non-empty `details` that disambiguates them.

**Fix.**
- Server: add `Details string \`json:"details,omitempty"\`` to `OpraEq`, populate
  from `l.Data.Details` (add `Details string \`json:"details"\`` to the line
  struct's `data`).
- Client model (`aria_api/lib/src/models/eq.dart`): add `String? details` to
  `EqProfile` (fromJson/toJson, alongside `author`).
- Browse UI (`eq_browse.dart`): curve row title = author; when `details` is
  present, show it as the subtitle. Curve identity name (`_curveName`, used for
  the persisted headphone/favourite name) = `'<vendor> <product> · <author>'`
  plus `' (<details>)'` when details is present, so favourites/slots are unique.

## 2. Selecting a headphone EQ breaks playback ("all songs run through in seconds")

**Root cause (proven).** The generated `af` string is **valid** — verified by
running a real 20-band curve through both ffmpeg (`-af`) and mpv (startup *and*
runtime `set_property af` over IPC): mpv applies the filter and keeps playing,
no error. The break is an mpv **audio-output reconfigure failure**: applying the
filter forces an ao renegotiation that fails on the user's device, and mpv then
plays every queued file instantly with no sound and EOFs straight through the
playlist. This was reproduced exactly by running mpv with a non-initialisable ao
— it races through a 2-track playlist in well under a second, matching the
report and the user's "like mpv wasn't installed" description.

The app's existing guard (`_handleLogMessage`, matches only `ao`-prefixed error
logs) is too narrow and loses the race against the EOF/START_FILE event burst,
so the queue blows through before it stops.

User is on **Android**, where `audio-exclusive` is a no-op (desktop-only), so the
exact ao trigger is Android-specific and cannot be root-caused headless.

**Fix (device-independent, in `aria_player/lib/src/player.dart`).**
- **Safety net (primary).** Track the max `time-pos` seen since each START_FILE
  (`_maxPosThisFile`). On END_FILE(eof), if the file never actually played
  (`_maxPosThisFile < 0.5`), increment a dead-EOF streak; a real play (pos ≥ 0.5)
  or an explicit `play()`/`stop()` resets it. Two consecutive dead EOFs ⇒ the ao
  is producing no sound: `stop()` and emit on `audioError` ("Audio output
  produced no sound — playback stopped."). This converts the catastrophe (whole
  library skipped) into a single clean stop + notice, on every platform and for
  every cause (broken ao, failed af reconfig, missing codec).
  - ponytail: 0.5 s / 2-in-a-row is a heuristic; real music tracks are never
    sub-0.5 s back-to-back. Tighten only if a false stop is ever observed.
- **Diagnostic log.** When the streak fires, `Log.w` the last mpv error line seen
  (broaden `_handleLogMessage` to *remember* the last error text regardless of
  prefix, without acting on non-`ao` prefixes) so the real Android trigger is
  captured in the NDJSON log for the next iteration.
- **Exclusive reconcile (desktop correctness, no-op on Android).** EQ and
  bit-perfect exclusive output are mutually exclusive by definition. In
  `setAudioFilter`, when `af` is non-empty force `audio-exclusive=no` at the
  engine; when it clears, restore the user's intent (tracked in the player).
  `setAudioExclusive` already no-ops on Android, so this only affects desktop.

The existing `ao`-prefix fast-path guard stays; the max-pos streak is the backstop.

## 3. Browse UI: pin big brands, cap the list, force search

`_SearchList` currently renders an unbounded `ListView` of every match.

**Fix (`eq_browse.dart`).**
- **Pinned brands.** On the Brands screen, when the search box is empty, show a
  pinned section first (exact OPRA vendor strings, all verified present):
  Sennheiser, Sony, Beyerdynamic, Audio-Technica, HIFIMAN, AKG, Apple, Bose,
  Beats, JBL, Audeze, Focal, ZMF — followed by a divider and the full list.
  Pinned brands hide once the user types (search spans everything).
- **Cap + force search.** `_SearchList` caps the rendered rows to a max
  (`_maxRows = 50`). When more matches exist than the cap, drop the overflow and
  append a non-tappable hint row ("＋N more — refine your search") so users search
  instead of scrolling thousands of rows. Applies to brands, headphones, and
  curves.

## Testing

- Go: extend `opra_test.go` — assert `details` is captured and emitted.
- Dart model: `details` round-trips through `EqProfile` JSON.
- Browse UI widget test: duplicate-author curves render distinct subtitles;
  pinned brands appear on empty query and vanish on search; the cap hint appears
  past `_maxRows`.
- Player test: two dead EOFs (START_FILE then END_FILE(eof) with no time-pos
  advance, twice) triggers a stop + `audioError`; a normal play (pos advances)
  does not.

## Out of scope

- The actual Android ao-reconfigure trigger (needs the diagnostic log from the
  device). The safety net makes the current behaviour non-destructive meanwhile.
