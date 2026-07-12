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

---

# Implementation Addendum (audit-hardened, 2026-07-12)

Produced by a 6-agent read-only audit of `app_flutter/`. All paths under
`app_flutter/lib/`. Line numbers verified against the tree at audit time — re-grep
before editing, they drift.

**Cross-cutting fact:** the app is fully flat today — zero `BoxShadow` anywhere in
`lib/`, `cardTheme` is dead code (no Material `Card(` widget exists; only custom
classes), `cardTheme.elevation: 0`. Surface separation is currently **100%
fill-delta** (`bgRaised #FFF` on `bg #FAFAFB`) plus a `line #E5E5E8` hairline
that is only ~1.26:1 on white. Moving `bg → #FFFFFF` deletes the fill-delta and
leaves an invisible hairline. Every phase assumes this.

## Surface strategy — DECIDED: border + shadow (Strategy B)

The audit recommended tinting `bgRaised` grey (Strategy A). **Overridden by user
decision:** surfaces stay **pure white**, separated by a `lineStrong` hairline +
a soft shadow. This introduces the app's first shadows and is per-surface work
(the Phase 3 tier list is that worklist), but it matches the brief (flat sidebar
w/ border, floating shadowed now-playing bar).

Token plan (`core/theme.dart`, `AriaColors.light`, lines 35–40 + additions):

| token | line | current | recast to | rationale |
|---|---|---|---|---|
| `bg` | 35 | `#FAFAFB` | `#FFFFFF` | the pure-white canvas |
| `bgRaised` | 36 | `#FFFFFF` | **keep `#FFFFFF`** | surfaces stay white; separation via border+shadow, not fill |
| `bgHover` | 37 | `#ECECEE` | keep (verify on white) | hover delta grows on white — fine |
| `line` | 38 | `#E5E5E8` | keep | decorative hairlines only (dividers inside a surface) |
| `lineStrong` | 40 | `#8D8D96` | keep (3.3:1) | **the load-bearing separator** — card borders + sole dividers |
| `bgFloat` | +new | — | `#FFFFFF` | menus/dialogs/sheets; crisp white + own shadow (see below) |
| `surfaceShadow` | +new | — | see below | shared soft shadow for panels + chrome |

```dart
// core/theme.dart — new shared token on AriaColors (or a top-level const)
static const surfaceShadow = <BoxShadow>[
  BoxShadow(color: Color(0x0F000000), blurRadius: 12, offset: Offset(0, 2)),
];
```
`bgFloat` routes: `theme.dart:227` (popupMenu), dialogs
`album/edit_metadata_dialog.dart:368`, `artist/reidentify_artist_dialog.dart:75`,
`artist/edit_artist_dialog.dart:133`, `album/reidentify_dialog.dart:76`; overlays
`library/library_sort.dart:94`, `library/track_filters.dart:315`,
`library/albums_section.dart:227/280`. (With `bgRaised` staying white, `bgFloat`
is currently the same value — the token exists so floats and inline cards can
diverge later, e.g. under dark theme, without another migration.)

**Hardcoded-color breakers — verified SAFE, do not block Phase 1** (all saturated/
dark with white content): home stat tiles `home_screen.dart:311-314`; genre
duotone map `library/genre_card.dart:19-38`; signal-path grades
`now_playing/signal_path.dart:12-19`; `ColorScheme.error` `theme.dart:181`. **One
check, not a break:** signal-path amber `#D97706` + green `#16A34A` were tuned on
off-white — confirm ≥4.5:1 as text on pure white.

## Phase 1 detail — font

- Single edit: add `fontFamily: 'Nunito',` to `ThemeData(...)` at
  `core/theme.dart:168`. No `fontFamily` exists anywhere in `lib/`; all
  `TextStyle`s are `inherit:true` and set no family → propagates ambiently, no
  per-widget edits.
- Weights used across `lib/`: only w400/w500/w600. Bundle **Regular / Medium /
  SemiBold** only. Skip w300/w700/italics — dead weight.
- `pubspec.yaml` `flutter:` block has no `fonts:`/`assets:` today. Add:
```yaml
  fonts:
    - family: Nunito
      fonts:
        - asset: assets/fonts/Nunito-Regular.ttf
          weight: 400
        - asset: assets/fonts/Nunito-Medium.ttf
          weight: 500
        - asset: assets/fonts/Nunito-SemiBold.ttf
          weight: 600
```

### tnum — gating check (silent failure)
8 sites call `FontFeature.tabularFigures()`; they no-op silently (digits go
proportional, no error) if the bundled Nunito ttf lacks the `tnum` OpenType
feature. **Bundle unmodified official static Nunito and verify each weight:**
`otfinfo -f assets/fonts/Nunito-Regular.ttf | grep -i tnum`. Keep all 8 calls
(Nunito is not tabular by default). Sites: `widgets/track_row.dart:84`,
`:129`, `widgets/format_badge.dart:40`, `now_playing/signal_path.dart:66`,
`now_playing/queue_screen.dart:241`, `now_playing/seek_bar.dart:98`,
`library/tracks_section.dart:329`, `home/home_screen.dart:235`. **Live smoke
test:** `seek_bar.dart:98` ticks every second — visible jitter = tnum missing.
Recommended (not required): add tnum to stats numbers that omit it and will
jitter under Nunito — `stats_page.dart:355` (`_StatTile`), plus `:161/:197`,
`charts.dart:146/:171`.

## Phase 2 detail — shell

**2a. Flat rail:** `theme.dart:263` `navigationRailTheme.backgroundColor:
c.bgRaised → c.bg`; on the `NavigationRail` at `router.dart:193` add
`surfaceTintColor: Colors.transparent, elevation: 0` (kill M3 tint);
`router.dart:236` `VerticalDivider(color: c.line) → c.lineStrong` (sole separator,
invisible at 1.26:1 otherwise).
**2b. Mobile bottom bar:** `theme.dart:279` `navigationBarTheme.backgroundColor:
c.bgRaised` merges into white — give it a `lineStrong` top border or `surfaceShadow`.
**2c. Float transport + selection bars:** both are the last two docked `Column`
children in *both* shell branches (`router.dart:179-185` narrow, `:238-257` wide).
Restructure each to a `Stack` + bottom `Positioned` hosting `[SelectionBar,
TransportBar]`. Wide: the Stack wraps the *content* `Expanded` (right of rail) so
bars align to content, not over the rail. Transport pill (`transport_bar.dart:121`):
replace `Container(color: bgRaised, top border line)` with outer margin +
`BorderRadius` + `surfaceShadow` + `BackdropFilter(ImageFilter.blur)` over
`bgRaised.withValues(alpha:)` (frost). `SizedBox(height: 84)` at `:133` is the
occlusion constant. `SelectionBar` (`selection_bar.dart:34`) floats **stacked
above** the transport when a track plays; keep its accent top-border (`:41`) as an
accent cue.

### 2d. Occlusion — single-point fix + bypass list
Floating removes the bars' layout height, so scroll bodies scroll under them.
Publish bar height as a shared const (`~84 + SafeArea + margin ≈ 108`) and fold
into `ariaPagePadding()` bottom default at `theme.dart:134-142` — covers ~20
helper-driven pages in one change. **Scroll views that BYPASS the helper (need
explicit bottom inset):**

| file:line | why missed |
|---|---|
| `search/search_page.dart:211` | passes `bottom: s3` override |
| `library/tracks_section.dart:191` | `ListView.builder` inside `SingleChildScrollView` |
| `library/genre_screen.dart:179` | `CustomScrollView` trailing `SliverPadding(bottom:0)` |
| `now_playing/queue_screen.dart:87` | `ReorderableListView` hardcoded `bottom: s8` (only if `/queue` renders in-shell) |
| `home/home_screen.dart:344,623` | nested list/scroll — verify clearance |
| `playlists_screen.dart:73`, `radio_page.dart:87` | grid `padding` must include bar inset |

**Open question to resolve per feature before assuming a detail page is safe:**
`TransportBar`/`SelectionBar` mount **only** inside `AdaptiveShell`. A
`context.push`'d detail page is occluded **iff** its `GoRoute` is nested in a
shell branch (renders inside the shell `Expanded`). Check each feature's
`routes.dart` `parentNavigatorKey` usage — root-navigator plainRoutes cover the
whole shell (bars included) and are NOT occluded.

## Phase 3 detail — surface tiers (border+shadow per Strategy B)

Apply `Border.all(color: c.lineStrong)` + `surfaceShadow` to real surfaces; keep
dense art tiles on the hairline alone (shadows on every grid tile look noisy).
Add a shared helper rather than re-inlining:
```dart
BoxDecoration ariaSurface(AriaColors c, {double radius = AriaRadius.md, Color? border}) =>
  BoxDecoration(
    color: c.bgRaised,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: border ?? c.lineStrong),
    boxShadow: AriaColors.surfaceShadow,
  );
```
`cardTheme` (`theme.dart:217`) is dead code — no Material `Card` exists — so this
cannot centralize through `cardTheme`; adopt the helper at each site.

**Tier 3 — white-on-white INVISIBLE (borderless fill-only, highest priority):**
`tags/tag_grid.dart:94-95`, `playlists/playlists_screen.dart:151-152` (both bare
`Container(color: bgRaised)`, no border). Add border+shadow or a distinct
placeholder tint; one shared "empty art placeholder" widget for both.

**Tier 2 — fill vanishes, faint border survives (adopt `ariaSurface`):**
`art_image.dart:74/77` (highest reach — fallback/initials state), `new_releases_shelf.dart:86-89`
(prefer replacing with `ArtImage`), `home_screen.dart:258-261`, `radio_page.dart:130-133`
(keep accent when `isCurrent`), `charts.dart:31-34` & `:125-128`, `stats_page.dart:345-348`,
`multi_select_field.dart:122-124` (radius `sm`, popover — needs shadow most) + its
field surface, `library/tracks_section.dart:184` `Divider → lineStrong`,
`filter_bar.dart:29-31` (unselected chip → `lineStrong`, keep accent when selected),
`signal_path.dart:289` connector, `home_screen.dart:872` inactive page-dots
(`line → lineStrong`), `artist_avatar.dart:50-53` (border → `lineStrong`).

**Tier 1 — chrome bars (directional top shadow, Phase 2):** transport + selection bars.

**Verify:** `charts.dart:48` heatmap `zeroColor: c.bgHover` still reads as empty
grid on white. **No-change (informational):** grid tiles (`album_card`,
`library_cards`, `person_card`/`CreditCard`, `shelf`, `empty_state`) draw no
surface themselves — fixing `art_image` + `artist_avatar` + the two Tier-3
placeholders covers them.

## Phase 4 detail — icons

229 usages · 51 files · **100 distinct**. Add `phosphor_flutter`; apply
`PhosphorIconsThin` (idle) / `PhosphorIconsFill` (active/selected) /
`PhosphorIconsRegular` (default). `router.dart` renders `Icon(d.selectedIcon ??
d.icon)` so each nav pair → thin/fill. Do the context-pair files first:
`router.dart` (nav mechanism), `library_screen.dart` (LibrarySection enum:
album/person/category/piano). Then transport (`transport_bar.dart` skip/stop →
fill; play/pause/repeat/favorite/volume decided at call site), then screen by
screen. Migrate one screen per commit; app never sits half-broken.

**Icons with NO clean Phosphor match — design sign-off on the substitute:**
`queue_play_next→rowsPlusTop`, `lyrics_outlined→microphoneStage`,
`file_download_off_outlined→cloudSlash`, `drive_file_move_outlined→folderSimpleArrowRight`,
`download_done→checkCircle`, `clear_all→broom`, `search_off→magnifyingGlassMinus`,
`mic_external_on→microphoneStage` (collides with `lyrics_outlined` — differentiate
if both ever visible), genre glyphs (decorative approximations in `genre_card.dart`).

### Appendix — full 100-icon mapping

`weight` = context means the call site decides (thin=idle, fill=active/on,
regular=decorative/menu).

| Material | Phosphor | weight | n | note |
|---|---|---|---|---|
| Icons.play_arrow | PhosphorIcons.play | context | 12 | fill in play/pause toggle; regular for Play menu items |
| Icons.close | PhosphorIcons.x | regular | 11 |  |
| Icons.edit_outlined | PhosphorIcons.pencilSimple | regular | 10 |  |
| Icons.album_outlined | PhosphorIcons.vinylRecord | context | 9 | thin as albums-tab idle; regular as art placeholder |
| Icons.sell_outlined | PhosphorIcons.tag | context | 8 | thin as tags-nav idle; regular as tag action |
| Icons.chevron_right | PhosphorIcons.caretRight | regular | 8 |  |
| Icons.cloud_off | PhosphorIcons.cloudSlash | regular | 7 | offline |
| Icons.add | PhosphorIcons.plus | regular | 7 |  |
| Icons.queue_music | PhosphorIcons.queue | context | 6 | fill as playlists-nav selectedIcon |
| Icons.playlist_add | PhosphorIcons.listPlus | regular | 6 |  |
| Icons.person_outline | PhosphorIcons.user | context | 6 | thin as artists-tab idle; regular as avatar/action |
| Icons.check | PhosphorIcons.check | regular | 6 |  |
| Icons.radio | PhosphorIcons.radio | context | 5 | fill as radio-nav selectedIcon; regular decorative |
| Icons.shuffle | PhosphorIcons.shuffle | regular | 4 |  |
| Icons.search | PhosphorIcons.magnifyingGlass | context | 4 | pairs with search_off |
| Icons.playlist_add_check | PhosphorIcons.listChecks | regular | 4 |  |
| Icons.music_note_outlined | PhosphorIcons.musicNote | thin | 4 | idle glyph |
| Icons.library_music_outlined | PhosphorIcons.musicNotes | context | 4 | thin as library-nav idle; regular as leading |
| Icons.auto_awesome | PhosphorIcons.sparkle | regular | 4 | AI/mix |
| Icons.queue_play_next | PhosphorIcons.rowsPlusTop | regular | 3 | NO EXACT - closest rowsPlusTop/listPlus |
| Icons.piano_outlined | PhosphorIcons.pianoKeys | context | 3 | thin as composers-tab idle; regular leading |
| Icons.check_box_outlined | PhosphorIcons.checkSquare | regular | 3 |  |
| Icons.category_outlined | PhosphorIcons.squaresFour | context | 3 | thin as genres-tab idle; regular leading |
| Icons.undo | PhosphorIcons.arrowCounterClockwise | regular | 2 |  |
| Icons.sync | PhosphorIcons.arrowsClockwise | regular | 2 |  |
| Icons.star | PhosphorIcons.star | context | 2 | fill as active favorite; pairs star_border |
| Icons.skip_previous | PhosphorIcons.skipBack | fill | 2 | transport |
| Icons.skip_next | PhosphorIcons.skipForward | fill | 2 | transport |
| Icons.piano | PhosphorIcons.pianoKeys | context | 2 | fill composers-tab active; regular genre_card |
| Icons.pause | PhosphorIcons.pause | context | 2 | fill when playing (active) in toggle |
| Icons.music_note | PhosphorIcons.musicNote | regular | 2 |  |
| Icons.more_horiz | PhosphorIcons.dotsThree | regular | 2 | overflow |
| Icons.menu_book_outlined | PhosphorIcons.bookOpen | regular | 2 | notes/bio |
| Icons.lyrics_outlined | PhosphorIcons.microphoneStage | regular | 2 | NO EXACT - closest microphoneStage/quotes |
| Icons.info_outline | PhosphorIcons.info | regular | 2 |  |
| Icons.favorite | PhosphorIcons.heart | context | 2 | fill active; pairs favorite_border |
| Icons.delete_outline | PhosphorIcons.trash | regular | 2 |  |
| Icons.bar_chart | PhosphorIcons.chartBar | context | 2 | fill stats-nav active; regular decorative |
| Icons.wb_sunny_outlined | PhosphorIcons.sun | regular | 1 | daily-mix accent |
| Icons.wb_sunny | PhosphorIcons.sun | regular | 1 | genre_card |
| Icons.volume_up | PhosphorIcons.speakerHigh | regular | 1 |  |
| Icons.volume_off | PhosphorIcons.speakerSlash | context | 1 | fill when muted; pairs volume_up |
| Icons.tune | PhosphorIcons.faders | regular | 1 |  |
| Icons.theater_comedy | PhosphorIcons.maskHappy | regular | 1 | genre, approx |
| Icons.swap_vert | PhosphorIcons.arrowsDownUp | regular | 1 | sort |
| Icons.stop | PhosphorIcons.stop | fill | 1 | transport |
| Icons.star_border | PhosphorIcons.star | thin | 1 | idle; pairs star |
| Icons.spa | PhosphorIcons.flowerLotus | regular | 1 | genre, approx |
| Icons.settings_outlined | PhosphorIcons.gear | context | 1 | thin settings-nav idle; regular leading |
| Icons.settings | PhosphorIcons.gear | fill | 1 | settings-nav active |
| Icons.sell | PhosphorIcons.tag | fill | 1 | tags-nav active |
| Icons.search_off | PhosphorIcons.magnifyingGlassMinus | regular | 1 | NO EXACT - no-results |
| Icons.schedule_outlined | PhosphorIcons.clock | regular | 1 |  |
| Icons.repeat_one | PhosphorIcons.repeatOnce | context | 1 | fill when loop-one active |
| Icons.repeat | PhosphorIcons.repeat | context | 1 | fill when loop active |
| Icons.remove_circle_outline | PhosphorIcons.minusCircle | regular | 1 |  |
| Icons.refresh | PhosphorIcons.arrowClockwise | regular | 1 |  |
| Icons.radio_outlined | PhosphorIcons.radio | thin | 1 | radio-nav idle |
| Icons.queue_music_outlined | PhosphorIcons.queue | thin | 1 | playlists-nav idle |
| Icons.public | PhosphorIcons.globe | regular | 1 |  |
| Icons.play_circle_outline | PhosphorIcons.playCircle | thin | 1 | idle play affordance |
| Icons.person | PhosphorIcons.user | fill | 1 | artists-tab active |
| Icons.nightlife | PhosphorIcons.martini | regular | 1 | genre, approx |
| Icons.mic_external_on | PhosphorIcons.microphoneStage | regular | 1 | NO EXACT - closest microphoneStage |
| Icons.library_music | PhosphorIcons.musicNotes | fill | 1 | library-nav active |
| Icons.landscape | PhosphorIcons.mountains | regular | 1 | genre |
| Icons.keyboard_arrow_down | PhosphorIcons.caretDown | regular | 1 |  |
| Icons.home_outlined | PhosphorIcons.house | thin | 1 | home-nav idle |
| Icons.home | PhosphorIcons.house | fill | 1 | home-nav active |
| Icons.headphones_outlined | PhosphorIcons.headphones | regular | 1 | eq leading |
| Icons.headphones | PhosphorIcons.headphones | regular | 1 | genre |
| Icons.groups_outlined | PhosphorIcons.users | regular | 1 |  |
| Icons.grid_view_outlined | PhosphorIcons.squaresFour | thin | 1 | commented-out nav idle |
| Icons.grid_view | PhosphorIcons.squaresFour | fill | 1 | commented-out nav active |
| Icons.graphic_eq | PhosphorIcons.waveform | regular | 1 |  |
| Icons.forest | PhosphorIcons.tree | regular | 1 | genre |
| Icons.folder_outlined | PhosphorIcons.folder | regular | 1 |  |
| Icons.file_download_off_outlined | PhosphorIcons.cloudSlash | regular | 1 | NO EXACT - closest cloudSlash/prohibit |
| Icons.favorite_border | PhosphorIcons.heart | thin | 1 | idle; pairs favorite |
| Icons.error_outline | PhosphorIcons.warningCircle | regular | 1 |  |
| Icons.equalizer | PhosphorIcons.equalizer | regular | 1 |  |
| Icons.emoji_events_outlined | PhosphorIcons.trophy | regular | 1 | top-played |
| Icons.edit_note | PhosphorIcons.notePencil | regular | 1 |  |
| Icons.drive_file_move_outlined | PhosphorIcons.folderSimpleArrowRight | regular | 1 | NO EXACT - else folder+fileArrowRight |
| Icons.download_done | PhosphorIcons.checkCircle | regular | 1 | NO EXACT - closest checkCircle |
| Icons.data_usage | PhosphorIcons.chartDonut | regular | 1 | usage |
| Icons.create_new_folder_outlined | PhosphorIcons.folderPlus | regular | 1 |  |
| Icons.clear_all | PhosphorIcons.broom | regular | 1 | NO EXACT - closest broom/eraser |
| Icons.church | PhosphorIcons.church | regular | 1 | genre |
| Icons.celebration | PhosphorIcons.confetti | regular | 1 | genre |
| Icons.category | PhosphorIcons.squaresFour | fill | 1 | genres-tab active |
| Icons.calendar_view_week_outlined | PhosphorIcons.calendarBlank | regular | 1 |  |
| Icons.calendar_month_outlined | PhosphorIcons.calendarDots | regular | 1 |  |
| Icons.bolt | PhosphorIcons.lightning | regular | 1 |  |
| Icons.bar_chart_outlined | PhosphorIcons.chartBar | thin | 1 | stats-nav idle |
| Icons.arrow_back | PhosphorIcons.arrowLeft | regular | 1 | back |
| Icons.album | PhosphorIcons.vinylRecord | fill | 1 | albums-tab active |
| Icons.account_circle_outlined | PhosphorIcons.userCircle | regular | 1 | account row |
| Icons.drag_indicator | PhosphorIcons.dotsSixVertical | regular | 1 | reorder |
| Icons.download_outlined | PhosphorIcons.downloadSimple | regular | 1 |  |
