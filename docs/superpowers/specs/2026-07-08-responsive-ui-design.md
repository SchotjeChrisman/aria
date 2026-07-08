# Responsive UI: 3 breakpoints, banded scaling, consistency cleanup

**Date:** 2026-07-08 · **Status:** approved

## Goal

Make the Flutter app (`app_flutter/`) responsive across mobile / tablet /
desktop with layouts that scale proportionally *within* a breakpoint band and
morph only *at* band switches (no web-style continuous reflow). Different
sized phones must render the same layout — structurally identical, sizes
proportional. Plus a consistency cleanup: tokens everywhere, no ad-hoc magic
numbers.

Explicitly rejected during brainstorming: a global canvas scaler
(FittedBox/screenutil pixel-identical rendering) — too literal. No visual
redesign, no new dependencies.

## Breakpoints (single source of truth)

Material 3 canonical values, defined once in `core/theme.dart` next to the
existing tokens:

```dart
enum AriaBreakpoint { mobile, tablet, desktop }
// width < 600            -> mobile
// 600 <= width < 1240    -> tablet
// width >= 1240          -> desktop
```

Plus a lookup (`AriaBreakpoint.of(context)` via `MediaQuery.sizeOf`). All
width checks in the app route through this — `AdaptiveShell`'s private
700/1100 constants are replaced with 600/1240 from the shared enum, and any
per-widget raw width comparisons are migrated.

## Shell morph per band

- **mobile**: AppBar + NavigationDrawer, bottom SelectionBar + TransportBar
  (current narrow layout).
- **tablet**: compact NavigationRail (icons + labels).
- **desktop**: extended NavigationRail.

Same `AdaptiveShell` widget, constants swapped; no structural rewrite.

## Identical phones / in-band scaling

The lever is **fixed layout structure per band**, letting sizes flex:

- Grids and card shelves that today size by `maxCrossAxisExtent` (giving a
  360 px phone 2 columns and a 428 px phone sometimes 3) switch to fixed
  column counts per band: **mobile 2, tablet 4, desktop 6** (dense track/list
  views stay single-column lists). Tiles flex to fill width via
  `crossAxisCount` + `AspectRatio`.
- Hero art, type ramp, paddings keep their current flex behaviour — with
  fixed columns they scale proportionally within a band.
- Horizontal shelves (home "new releases" etc.) size cards as a fraction of
  band-fixed columns rather than a hardcoded px extent, so the same number of
  cards peek on every phone.

## Consistency cleanup (no redesign)

Screen-by-screen sweep of every feature (home, library sections + genre,
album, artist/composer, search, playlists, tags, radio, stats, settings,
now-playing/queue/lyrics/transport, profiles, setup) and shared widgets:

- Magic paddings / gaps → `AriaSpace` tokens.
- Ad-hoc `TextStyle(fontSize: …)` → text-theme styles where an equivalent
  exists (explicit sizes that ARE the design stay).
- Raw width checks / redundant per-widget `LayoutBuilder` hacks → the shared
  breakpoint, or deleted where fixed columns make them redundant.
- Colors must come from `AriaColors` (no inline `Color(0x…)` outside theme).

Verify each screen at ~390, ~800, ~1400 logical px.

## Testing

- Existing suite + `flutter analyze` stay green.
- New widget test: `AdaptiveShell` shows drawer at 599, rail at 600,
  extended rail at 1240; a grid screen yields 2/4/6 columns per band.

## Out of scope

Visual redesign, new dependencies, server changes, the uncommitted
now-playing navigation WIP (left as-is, not reverted).
