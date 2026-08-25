# Aria design system catalogue

Widgetbook over the real widgets in `../lib`. Storybook itself has no Flutter
renderer — it mounts components as DOM in a bundler-served iframe, and Flutter
paints to a canvas — so the Flutter-native equivalent stands in.

```sh
cd app_flutter/widgetbook
flutter pub get
flutter run -d macos      # or -d linux, or a device
flutter test              # stub server, PNG encoder, catalogue coverage, and every use case rendered
flutter test --update-goldens   # refresh test/goldens/*.png
```

### In a browser

```sh
flutter build web
dart run tool/serve.dart          # pass a port to change it from 8080
```

It binds `0.0.0.0` and prints every address it is reachable on, so the one to
type into a phone is on screen:

```
Aria design system catalogue
  http://localhost:8080          (this machine)
  http://10.0.0.146:8080        (ens18)
```

One process serves the catalogue and its stub data on one origin, so there is
no CORS to configure and one URL to open. That is also what makes another
device work with no configuration: `stub_backend_web.dart` asks for
`Uri.base.origin`, so whichever address the phone used to load the page is the
address its API and cover-art requests go back to.

Deep links work — the URL carries the selected use case, e.g.
`http://10.0.0.146:8080/#/?path=components/cards/albumcard/states`.

Everything served is the catalogue and its fixtures. There is no library, no
credentials and no real server behind it, which is why binding every interface
is the default rather than a flag.

It runs fully offline: `web/flutter_bootstrap.js` pins `canvasKitBaseUrl` to the
local `canvaskit/` copy, overriding Flutter's default of fetching CanvasKit from
gstatic.

Web is a catalogue target, not a player — audio is libmpv over FFI and there is
no browser equivalent. See "How the web build works" below.

### On a headless machine

`flutter test` renders every use case through the same pipeline and writes
`test/goldens/*.png`. That is how screenshots get made without a display.

Eight use cases move with the wall clock — play history bucketed against
today, the mixes shelf naming the current month and year, log lines stamped
with the time they were written. Those are rendered but not compared —
`Entry.golden` marks them, and `test/coverage_test.dart` is what keeps the
catalogue itself honest.

## What is on show

**Foundations** — every token in `../lib/core/theme.dart`, read from the
constants rather than transcribed: the `AriaColors` palette with contrast
ratios computed at build time, the `AriaSpace` 4px scale, `AriaRadius`,
`ariaSurface()` against the separators it is not, the type ramp, the
`AriaBreakpoint` bands, and the three Phosphor icon weights.

**Components** — everything in `../lib/widgets`: the art and card widgets, the
track row and its format badge, the shelves, the filter bar and multi-select,
the context menu, tag and playlist sheets, the name dialog, `SelectionHighlight`
with `SelectionBar`, and `EmptyState` — plus the buttons, inputs, toast and
navigation that come from `ThemeData` rather than from a widget file.

**Shell** — the app chrome the features are mounted inside: `AdaptiveShell`
itself, the navigation rail, its items, and the selection/transport bars that
float over every page. The shell story stands up its own `GoRouter` over the
app's own branch list, because a `StatefulNavigationShell` can only come from
go_router resolving a `StatefulShellRoute` — a real shell around real pages,
rather than a faked argument that would catalogue the fake.

**One category per feature** — Home, Library, Listen later, Album, Artist,
Now playing, Playlists, Profiles, Radio, Release, Review, Search, Settings,
Stats and Tags, holding the components that live under `../lib/features`: the
home shelves and listening blocks, the library sections and track table, the
credit and genre cards, the transport bar, seek bar and signal path, the queue
rows, the stats charts, the tag grid, and every editor and confirmation dialog.

**Pages** — every destination in the app, mounted whole, in a `Pages` folder at
the end of its feature's category: the parts, then the thing built out of them.
All 37 of them, from `HomeScreen` down to `EqCurvesScreen`, plus the
`ServerSetupScreen` the app shows *instead* of the shell until a server URL
resolves. Route parameters come from the fixtures rather than from literals
wherever a fixture already names one, so a renamed id fails to compile instead
of quietly rendering an empty page.

Pages are catalogued because half of what can be wrong with one — its padding,
its scroll extent, its empty state, its appbar — is invisible in the components
it is built from. `test/coverage_test.dart` reads `../lib` on every run and
fails if any widget under `../lib/widgets`, `../lib/features` or `../lib/core`
has no use case, destinations included.

Nothing here re-implements a component. The use cases supply arguments and
states; if a widget changes, this catalogue changes with it on hot reload.

## How the wired widgets work without a server

Most of these widgets read Riverpod providers, and `ArtImage` fetches covers
over the network. Rather than mock provider by provider, `lib/fake_server.dart`
runs a loopback `HttpServer` and `main()` points `apiClientProvider` at it.
One socket covers both paths — `Image.network` goes straight to `dart:io` and
would never see an injected `http.Client`.

That leaves three overrides in `main()` and no per-widget mocking:

| provider | why |
| --- | --- |
| `sharedPrefsProvider` | throws by construction until `main()` fills it |
| `appSupportDirProvider` | same; pointed at a temp dir so runs are hermetic |
| `apiClientProvider` | pointed at the stub, which skips the `/setup` redirect |

The audio engine needs nothing at all. `AriaPlayer` only loads libmpv in
`initialize()`, which the catalogue never calls, and every command is guarded
by `if (!isAvailable) return`. So the real `QueueNotifier` runs and queue state
really mutates, while the engine stays silent.

The booklet page hands its URL to `pdfrx`, which renders the PDF itself, so
the stub emits a real one-page PDF with its xref offsets computed at request
time. Serving anything else puts the viewer in an error state whose text is a
stack trace — a golden that only matches the machine that wrote it. `pdfrx`
also asks `path_provider` for a cache directory over a `MethodChannel`, which
`flutter_test` does not implement; the render test registers one handler for it.

Covers are generated per subject rather than shipped as fixture files — a few
repeated images across a 24-tile grid make the layout look wrong in a way the
layout is not. `_encodePng` writes them; `test/fake_server_test.dart` checks
the bytes decode.

## How the web build works

`package:aria` reaches `dart:io` in eleven files, `dart:isolate` in two, and
`dart:ffi` in one — none of which exist in a browser. Rather than rewrite that
code, each library enters through a seam whose native half is the real thing:

| seam | native | web |
| --- | --- | --- |
| `../lib/core/native/native.dart` | re-exports `dart:io` | in-memory File/Directory, inert Platform/Process/HttpClient |
| `../lib/widgets/local_art_io.dart` | `Image.file` for the offline cover | goes straight to the placeholder |
| `../packages/aria_api/lib/src/compute.dart` | `Isolate.run` | runs inline |
| `../packages/aria_player/lib/src/mpv_host_io.dart` | loads libmpv via FFI | throws `PlayerUnavailableException` |

The player seam needs no special handling downstream: `AriaPlayer.initialize`
already catches that exception and reports `isAvailable == false`, after which
every command is a guarded no-op. So the real `QueueNotifier` runs on web too —
queue state mutates, current-track styling is genuine, and nothing plays.

The native halves are `dart:io` and `dart:ffi` re-exported unchanged, so no
native code path was altered to make this work.

## Two things this project has to keep in step with the app

Both are consequences of `widgetbook/` being the root package, and both fail
loudly rather than silently:

- **`dependency_overrides`** — the app's libmpv swap (`../third_party`) only
  applies from the root package, so `pubspec.yaml` here repeats it. Drop it and
  macOS/iOS link the pub.dev builds instead.
- **Fonts** — a dependency's assets are only reachable as
  `packages/<name>/…` when they live under that package's `lib/`, and the app's
  are at `../assets/fonts`. `assets` here is a symlink to `../assets`, so the
  catalogue always uses the files the app ships.

## Adding a use case

Write a `Widget Function(BuildContext)` in `lib/stories/`, then add an `Entry`
to that file's entry list. That one declaration is read by both `lib/main.dart`
(which builds the navigation tree from it) and the render test (which renders
every entry and writes its golden) — they were two lists once, and the moment
there were more than a handful of components they drifted.

A new story file also needs a line in `lib/stories/all.dart`, which is the
map of category name to entries.

Pages are the exception to "beside its story": they all live in
`lib/stories/pages.dart`, one `_page(...)` line each, grouped by feature. One
file is what makes "is every destination catalogued" a question you can answer
by reading a single list.

The annotation flow (`@UseCase` + `widgetbook_generator` + `build_runner`) was
skipped deliberately: it costs three more dependencies and a codegen step
before the catalogue will run, and it would put Widgetbook annotations inside
the shipped app's `lib/`. A list is cheaper.

## Known issue this catalogue surfaced

The type page renders in the platform default font, not Nunito, and that is
faithful — the app does the same. `AriaTheme.light()` sets
`ThemeData(fontFamily: 'Nunito')`, then replaces `titleLarge`, `titleMedium`,
`bodyMedium`, `bodySmall` and `labelMedium` with bare `TextStyle(...)` objects
in a `copyWith`. `ThemeData` applies `fontFamily` at construction and never
again, so those five styles — which is nearly all text in the app — come out
with `fontFamily == null`. The M3 styles that were left alone keep Nunito.

Icons are unaffected: `IconData` carries its family explicitly, which is why
the Phosphor page renders correctly while the type page does not.

Fixing it belongs in `../lib/core/theme.dart`, not here.

## Fixtures

`lib/fixtures.dart` is the whole data set: four albums chosen to cover the
states the widgets branch on, plus play history, library health, duplicates,
a match-review queue, radio stations, unowned releases, enrichment payloads
and an OPRA EQ database. Everything is written as JSON and decoded through the
app's own `fromJson`, and the same maps are what `FakeAriaServer` serves — so
a use case and the stub can never disagree, and a wire-format change shows up
as a decode failure rather than a fixture that quietly lost a column.

The one exception is play history, whose timestamps are relative to now. The
charts bucket against the wall clock, and a frozen date would leave every bar
at zero — a chart with nothing in it says nothing about the chart.
