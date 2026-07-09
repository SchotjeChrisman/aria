# Opra EQ UI: layered EQ, favourites, drill-down selection

Date: 2026-07-09

## Goal

Rework the Headphone EQ screen so that:

1. **Opra (headphone correction) is a separate layer from custom EQ.** A user can
   apply a headphone correction *and* stack one custom EQ on top; both are active
   simultaneously.
2. **Specific Opra EQ curves can be favourited** and applied in one tap.
3. **Selection is a drill-down: brand → headphone → EQ curve** instead of a flat
   searchable list.

No backend changes. Opra stays server-fetched and read-only; favourites and custom
presets are client-side (SharedPreferences), matching the existing custom-preset
storage.

## Current state (before)

- `eqProvider` holds a single `EqState { bool enabled, EqProfile? profile }`. Opra
  products and custom presets are one mutually-exclusive list; only one profile is
  ever applied.
- `eqToAf(EqProfile)` converts one profile to an mpv `af` lavfi chain. Already clamps
  preamp to ±24 dB and band gain to ±30 dB.
- `customEqPresetsProvider` holds user presets in `aria.eq.custom`.
- `eq_screen.dart` renders: Off / Custom list (+ add/edit/delete) / flat Opra list
  with a top search box and an author-picker dialog for multi-EQ products.

## Design

### 1. Two-layer state (`lib/core/player_providers.dart`, `lib/core/eq.dart`)

`EqState` becomes two independent slots plus a master switch:

```dart
class EqState {
  const EqState({this.enabled = false, this.headphone, this.custom});
  final bool enabled;
  final EqProfile? headphone; // from Opra (or a favourite)
  final EqProfile? custom;    // one selected custom preset
  bool get active => enabled && (headphone != null || custom != null);
}
```

Combining is one function in `eq.dart` (concat bands, sum preamps):

```dart
/// Stack two EQ layers into one chain: bands concatenated, preamps summed.
/// Null when both layers are empty. eqToAf() already clamps the summed preamp.
EqProfile? combineEq(EqProfile? h, EqProfile? c) {
  if (h == null && c == null) return null;
  return EqProfile(
    gainDb: (h?.gainDb ?? 0) + (c?.gainDb ?? 0),
    bands: [...?h?.bands, ...?c?.bands],
  );
}
```

`EqNotifier`:
- `apply()` pushes `eqToAf(combineEq(headphone, custom))` when `enabled` and the
  combined profile is non-null, else `''`.
- `selectHeadphone(EqProfile?)` — sets/clears the headphone slot.
- `selectCustom(EqProfile?)` — sets/clears the custom slot.
- `setEnabled(bool)` — master switch, preserves both slots.
- Selecting into an empty state should enable (so applying a favourite/curve turns
  the EQ on); clearing the last remaining layer is allowed and simply yields silence.
  Rule: `selectHeadphone`/`selectCustom` set `enabled = true` when the resulting
  state has at least one non-null layer, and leave `enabled` untouched otherwise.
- In-place custom edit: when the edited preset's name matches the current `custom`
  slot, replace the `custom` slot with the edited profile (preserve `enabled`) —
  mirrors today's `updateProfile`.

**Persistence (`aria.eq`)** — new shape `{enabled, headphone?, custom?}` where each
layer is `EqProfile.toJson()`. **Migration:** on load, if the stored map has the old
flat shape (`name`/`bands` at top level, no `headphone`/`custom` keys), load it as the
`headphone` layer. One branch, no data loss for existing users. Corrupt entry → clean
default (unchanged behaviour).

### 2. Favourites (`lib/core/player_providers.dart`)

A favourite is a named `EqProfile` (`name` = `"Vendor Product · Author"`), stored in
`aria.eq.favourites` as a JSON array of `EqProfile.toJson()` — identical shape to
`customEqPresetsProvider`. Self-contained, so a favourite applies without the Opra
fetch having completed.

```dart
final favouriteEqProvider =
    NotifierProvider<FavouriteEqNotifier, List<EqProfile>>(FavouriteEqNotifier.new);
```

`FavouriteEqNotifier` mirrors `CustomEqPresetsNotifier`:
- `build()` loads `aria.eq.favourites` (corrupt → `[]`).
- `toggle(EqProfile p)` — add if no entry with `p.name`, else remove; persist.
- `bool contains(String name)`.

Applying a favourite = `selectHeadphone(favourite)`.

### 3. UI

#### Entry screen (`lib/features/settings/eq_screen.dart`, rewritten)

Top-to-bottom:
- **Master on/off** switch (`SwitchListTile`, bound to `enabled`).
- **Two slots**, each a row showing current pick + a clear (×) trailing icon:
  - `Headphone: <name>` / `Headphone: None`
  - `Custom EQ: <name>` / `Custom EQ: None`
  - Clear calls `selectHeadphone(null)` / `selectCustom(null)`.
- **★ Favourites** section (only when non-empty): each starred curve; tap applies as
  the headphone layer, a filled-star trailing button un-favourites. Selected state
  reflects the current headphone slot.
- **Choose headphone →** row that pushes the Brands screen (drill-down).
- **Custom EQ** section: the `customEqPresetsProvider` list; tap selects into the
  custom slot; edit/delete per row (reuse existing `_CustomEqDialog` unchanged);
  "Add custom EQ" row. Deleting the preset that is in the custom slot clears the
  custom slot.

#### Drill-down (`lib/features/settings/eq_browse.dart`, new)

Three pushed screens, each a simple searchable `ListView`; all read `opraProvider`
(moved here or kept in `eq_screen.dart` and imported):

1. **Brands** — distinct `vendor` values from Opra products, sorted, searchable.
   Loading/error states reuse the existing status-row pattern.
2. **Headphones** — products for the chosen vendor.
3. **Curves** — the product's `eqs` (by author). Each row: tap → `selectHeadphone`
   with name `"Vendor Product · Author"` and pop back to the entry screen; trailing
   **★** toggles favourite for that exact curve. A product with a single EQ applies
   immediately from the Headphones screen and skips this screen.

Search that used to live on the flat top-level list now lives on the Brands screen.

### 4. Tests

- `test/eq_af_test.dart` — unchanged (`eqToAf` untouched). Add cases for `combineEq`
  (sum preamp, concat bands, null handling) — either here or a small new test file.
- `test/eq_screen_test.dart` — rewrite for the two-slot entry UI: selecting a
  headphone and a custom preset both apply (combined chain non-empty), clearing each
  slot, master switch, and favourite toggle. Persistence-migration unit test for the
  old flat `aria.eq` shape loading into the `headphone` slot.

## Files touched

- `lib/core/eq.dart` — add `combineEq`.
- `lib/core/player_providers.dart` — two-slot `EqState`/`EqNotifier`, migration,
  `favouriteEqProvider`.
- `lib/features/settings/eq_screen.dart` — rewritten entry screen (keep
  `_CustomEqDialog`).
- `lib/features/settings/eq_browse.dart` — new drill-down screens.
- `test/eq_screen_test.dart`, `test/eq_af_test.dart` (or new combine test) — updated.

## Out of scope

- Server-side / cross-device favourite sync.
- Stacking more than one custom preset.
- Changes to `eqToAf` or the mpv filter pipeline.
