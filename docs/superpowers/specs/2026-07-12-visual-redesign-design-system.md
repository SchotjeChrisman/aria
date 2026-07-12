# Visual Redesign — Design System

Date: 2026-07-12
Status: approved, phased

## Goal

A full look-and-feel redesign layered on the existing (user-built) layout and
structure. Captured as **tokens + shared patterns** so consistency is enforced
by the design system, not by per-widget discipline. Light theme only for now;
dark comes later as a drop-in `AriaColors.dark`.

## Target look (user's brief)

- Plain **pure-white** canvas.
- Now-playing bar **floats** on the canvas: soft shadow + frosted-glass blur.
- Sidebar sits **flat** on the canvas, separated only by a border.
- Almost fully **greyscale**, with an occasional **reddish-pink accent**
  (existing `#D13B58`). Accent marks states only (current/selected/active/live).
- **Rounded, highly legible** font: **Nunito**, bundled offline.
- Icons: **thin-lined + solid, more detail** than current Material set:
  **Phosphor** (`thin` idle / `fill` active).

## Key structural consequence

Pure-white canvas removes fill-based surface separation: today cards/shelves
read as *raised white* (`bgRaised #FFF`) on *off-white* (`bg #FAFAFB`). On a
white canvas that contrast is gone. So surfaces separate by **hairline border +
soft shadow**, not by fill. This is the redesign's real component-level shift
and flows mostly from the central `cardTheme`.

## Where each change lives

Everything except icons flows from a handful of central changes in
`core/theme.dart` (+ shell files). The icon swap is 229 call sites / 100
distinct `Icons.*` — the one genuinely large, un-tokenizable migration.

## Scope boundaries

- Light theme only. Structure tokens so `AriaColors.dark` drops in later with no
  widget changes. Do NOT build dark now — just don't hardcode colors in widgets
  (already the pattern).
- No layout / IA changes — that's the user's domain.
- New deps: `phosphor_flutter`, bundled Nunito ttf assets. Nothing else.

## Phases (each independently shippable; rebuild release + restart `./aria`)

### Phase 1 — Foundation (tokens + font)
- `AriaColors.light`: `bg #FAFAFB → #FFFFFF`. Recast `bgRaised`, `bgHover`,
  `line`, `lineStrong` for a white-canvas world (raised surfaces can no longer
  rely on a fill delta; keep hover/line legible on white).
- Bundle Nunito ttf; set `ThemeData.fontFamily` globally. Verify tabular
  numerals still available for times (Nunito has tnum; else keep the numeric
  feature the transport/seek-bar relies on).
- Files: `core/theme.dart`, `pubspec.yaml`, `assets/fonts/`.
- Check: app-wide font + white bg render; no widget hardcodes a background that
  now clashes.

### Phase 2 — Shell
- Sidebar flat: strip M3 NavigationRail surface tint/elevation so it paints on
  `bg`; keep the 1px `VerticalDivider(line)` as the only separator.
- Floating now-playing bar: today `TransportBar` is docked as a Column child in
  `router.dart`. Move it to a floating overlay — outer margin, rounded corners,
  soft `BoxShadow`, `BackdropFilter` (ImageFilter.blur) frost over a translucent
  white fill. Applies to both wide (rail) and narrow (drawer) shells.
- Files: `core/router.dart`, `features/now_playing/transport_bar.dart`.
- Check: bar floats with visible shadow + frost over scrolling content; content
  isn't occluded (bottom padding accounts for the floating bar); mobile + desktop.

### Phase 3 — Surfaces
- Shift shared surfaces from fill-based to border+shadow: central `cardTheme`
  (hairline `line` border + soft shadow, `bgRaised` fill = white or near-white).
- Audit shared widgets that draw their own surface: `widgets/album_card.dart`,
  `widgets/library_cards.dart`, `widgets/shelf.dart`, `widgets/new_releases_shelf.dart`,
  and any feature card that doesn't route through `Card`/theme.
- Files: `core/theme.dart` + the shared surface widgets above.
- Check: cards/shelves visibly separated on white via border+shadow, not fill;
  no "floating white on white" invisible edges.

### Phase 4 — Icons
- Add `phosphor_flutter`. Migrate 229 `Icons.*` usages → Phosphor.
- Convention: `thin` (or `light`) weight for idle, `fill` for active/selected
  (e.g. NavigationRail `icon` vs `selectedIcon`; play/pause; toggles).
- Done screen-by-screen so the app never sits half-migrated and each batch is
  reviewable. Build a distinct-icon mapping (100 icons) as the migration guide;
  no runtime abstraction layer — direct call-site replacement.
- Files: many, incrementally. `pubspec.yaml` for the dep.
- Check: each migrated screen renders all icons (no missing glyphs); idle/active
  weight convention consistent.

## Testing

Existing widget tests (`test/`) cover transport bar responsiveness, breakpoints,
now-playing layout, format badge, artist avatar. Keep them green through each
phase; extend only where a phase changes tested behavior (e.g. floating transport
placement). No new test framework.
