# Graph Report - transport-bar-responsive  (2026-07-06)

## Corpus Check
- 221 files · ~112,288 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 2030 nodes · 4535 edges · 54 communities detected
- Extraction: 96% EXTRACTED · 4% INFERRED · 0% AMBIGUOUS · INFERRED: 177 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 25|Community 25]]
- [[_COMMUNITY_Community 26|Community 26]]
- [[_COMMUNITY_Community 27|Community 27]]
- [[_COMMUNITY_Community 28|Community 28]]
- [[_COMMUNITY_Community 29|Community 29]]
- [[_COMMUNITY_Community 30|Community 30]]
- [[_COMMUNITY_Community 31|Community 31]]
- [[_COMMUNITY_Community 32|Community 32]]
- [[_COMMUNITY_Community 33|Community 33]]
- [[_COMMUNITY_Community 34|Community 34]]
- [[_COMMUNITY_Community 35|Community 35]]
- [[_COMMUNITY_Community 36|Community 36]]
- [[_COMMUNITY_Community 37|Community 37]]
- [[_COMMUNITY_Community 38|Community 38]]
- [[_COMMUNITY_Community 39|Community 39]]
- [[_COMMUNITY_Community 40|Community 40]]
- [[_COMMUNITY_Community 41|Community 41]]
- [[_COMMUNITY_Community 42|Community 42]]
- [[_COMMUNITY_Community 43|Community 43]]
- [[_COMMUNITY_Community 44|Community 44]]
- [[_COMMUNITY_Community 45|Community 45]]
- [[_COMMUNITY_Community 46|Community 46]]
- [[_COMMUNITY_Community 47|Community 47]]
- [[_COMMUNITY_Community 48|Community 48]]
- [[_COMMUNITY_Community 49|Community 49]]
- [[_COMMUNITY_Community 50|Community 50]]
- [[_COMMUNITY_Community 51|Community 51]]
- [[_COMMUNITY_Community 52|Community 52]]
- [[_COMMUNITY_Community 53|Community 53]]

## God Nodes (most connected - your core abstractions)
1. `package:flutter/material.dart` - 146 edges
2. `package:flutter_riverpod/flutter_riverpod.dart` - 130 edges
3. `package:aria_api/aria_api.dart` - 122 edges
4. `../core/theme.dart` - 113 edges
5. `package:go_router/go_router.dart` - 63 edges
6. `../core/connection.dart` - 54 edges
7. `../../widgets/empty_state.dart` - 45 edges
8. `$()` - 41 edges
9. `providers.dart` - 40 edges
10. `../core/player_providers.dart` - 37 edges

## Surprising Connections (you probably didn't know these)
- `mk()` --calls--> `api()`  [INFERRED]
  server/test.js → app/ui/app.js
- `tile` --calls--> `renderHome()`  [INFERRED]
  /home/chris/Repositories/roon/app_flutter/lib/features/home/home_screen.dart → app/ui/app.js
- `one` --calls--> `evalRule()`  [INFERRED]
  /home/chris/Repositories/roon/app_flutter/lib/features/library/track_filters.dart → server/server.js
- `dayKey` --calls--> `buildListening()`  [INFERRED]
  /home/chris/Repositories/roon/app_flutter/lib/features/stats/stats_page.dart → app/ui/app.js
- `Row` --calls--> `buildFilterRows()`  [INFERRED]
  /home/chris/Repositories/roon/app_flutter/lib/widgets/filter_bar.dart → app/ui/app.js

## Communities

### Community 0 - "Community 0"
Cohesion: 0.02
Nodes (154): connection.dart, context_menu.dart, ../core/connection.dart, ../../core/library_providers.dart, ../core/player_providers.dart, ../core/playlists_providers.dart, ../../core/profiles_providers.dart, ../core/selection.dart (+146 more)

### Community 1 - "Community 1"
Cohesion: 0.02
Nodes (161): artist_discography.dart, artist_info_tab.dart, artist_overview.dart, charts.dart, ../core/formats.dart, ../core/theme.dart, dart:collection, edit_artist_dialog.dart (+153 more)

### Community 2 - "Community 2"
Cohesion: 0.04
Nodes (160): $(), activeFilterCount(), addTrackTo(), albumCard(), albumCtx(), albumPassesFilters(), albumType(), api() (+152 more)

### Community 3 - "Community 3"
Cohesion: 0.03
Nodes (70): albumCache, AlbumCandidate, ArtistCandidate, ArtistDiscography, ArtistEntry, Composer, ComposerEntry, Deezer (+62 more)

### Community 4 - "Community 4"
Cohesion: 0.04
Nodes (84): httpError(), New(), NewHub(), readJSON(), register(), requireFields(), writeJSON(), init() (+76 more)

### Community 5 - "Community 5"
Cohesion: 0.03
Nodes (71): album_page.dart, art_image.dart, ../../core/router.dart, format_badge.dart, genre_screen.dart, AriaColors, copyWith, dark (+63 more)

### Community 6 - "Community 6"
Cohesion: 0.03
Nodes (38): Deps, NewDeps(), Enricher, Scanner, Edits, NewEdits(), Enrich, NewEnrich() (+30 more)

### Community 7 - "Community 7"
Cohesion: 0.06
Nodes (60): album_filters.dart, albums_section.dart, artists_section.dart, composers_section.dart, genres_section.dart, AlbumFilters, AlbumFiltersNotifier, albumPassesFilters (+52 more)

### Community 8 - "Community 8"
Cohesion: 0.04
Nodes (60): dart:ffi, dart:io, command, create, _dirname, FfiMpvRaw, _forceNumericLocaleC, Function (+52 more)

### Community 9 - "Community 9"
Cohesion: 0.06
Nodes (54): AudioFormat, command, create, FakeMpvRaw, initialize, main, observeProperty, PlayerUnavailableException (+46 more)

### Community 10 - "Community 10"
Cohesion: 0.05
Nodes (57): artist_page.dart, artist_util.dart, composer_page.dart, external_link.dart, ArtistInfoTab, _Bio, build, Column (+49 more)

### Community 11 - "Community 11"
Cohesion: 0.08
Nodes (35): dart:convert, exceptions.dart, AriaApiException, AriaClient, artUrl, close, _get, jsonDecode (+27 more)

### Community 12 - "Community 12"
Cohesion: 0.07
Nodes (31): AlbumCandidate, AlbumInfo, ArtistCandidate, ArtistInfo, ComposerInfo, DiscographyItem, EnrichStatus, Lyrics (+23 more)

### Community 13 - "Community 13"
Cohesion: 0.08
Nodes (38): ../features/album/routes.dart, ../features/artist/routes.dart, ../features/home/routes.dart, ../features/library/routes.dart, ../features/now_playing/routes.dart, ../features/playlists/routes.dart, ../features/radio/routes.dart, ../features/search/routes.dart (+30 more)

### Community 14 - "Community 14"
Cohesion: 0.09
Nodes (32): build, CreditCard, InkWell, SizedBox, build, InkWell, PersonCard, SizedBox (+24 more)

### Community 15 - "Community 15"
Cohesion: 0.09
Nodes (20): main(), Config, FromEnv(), getenv(), migrate(), Open(), TestOpenMigratesAndIsIdempotent(), main() (+12 more)

### Community 16 - "Community 16"
Cohesion: 0.11
Nodes (17): Playlist, Playlists, NewPlaylists(), nullRaw(), scanPlaylist(), fileEntry, Scanner, durPtr() (+9 more)

### Community 17 - "Community 17"
Cohesion: 0.08
Nodes (20): createEnricher(), get(), mb(), sleep(), genreMatches(), splitGenres(), loadIndex(), scan() (+12 more)

### Community 18 - "Community 18"
Cohesion: 0.12
Nodes (30): AudioExclusiveNotifier, build, clear, clearForRadio, copyWith, move, next, _onEnded (+22 more)

### Community 19 - "Community 19"
Cohesion: 0.15
Nodes (24): AlertDialog, apply, build, _changed, clear, Column, dispose, dropdown (+16 more)

### Community 20 - "Community 20"
Cohesion: 0.14
Nodes (22): build, _changed, Column, dispose, initState, InkWell, MultiSelectField, _MultiSelectFieldState (+14 more)

### Community 21 - "Community 21"
Cohesion: 0.15
Nodes (21): AlertDialog, build, ConstrainedBox, Container, dispose, _hex, InkWell, MenuAnchor (+13 more)

### Community 22 - "Community 22"
Cohesion: 0.15
Nodes (23): AlbumCard, _AlbumShelf, AsyncData, AsyncError, build, _ChartBox, Container, dayKey (+15 more)

### Community 23 - "Community 23"
Cohesion: 0.17
Nodes (21): build, cell, _Cells, Column, Function, GestureDetector, _HeaderRow, InkWell (+13 more)

### Community 24 - "Community 24"
Cohesion: 0.18
Nodes (19): build, Column, dispose, _ExclusiveToggle, _LibraryTools, _ListenBrainzField, _ListenBrainzFieldState, Padding (+11 more)

### Community 25 - "Community 25"
Cohesion: 0.22
Nodes (15): AlertDialog, build, _clearAll, dispose, _EditorDialog, _EditorDialogState, _Field, _fieldRow (+7 more)

### Community 26 - "Community 26"
Cohesion: 0.22
Nodes (15): build, Column, dispose, InkWell, _RadioCard, RadioPage, _RadioPageState, Scaffold (+7 more)

### Community 27 - "Community 27"
Cohesion: 0.18
Nodes (11): fl_register_plugins(), main(), first_frame_cb(), my_application_activate(), my_application_class_init(), my_application_dispose(), my_application_init(), my_application_local_command_line() (+3 more)

### Community 28 - "Community 28"
Cohesion: 0.26
Nodes (12): command, create, initialize, MpvEventData, MpvRaw, observeProperty, PlayerUnavailableException, setOptionString (+4 more)

### Community 29 - "Community 29"
Cohesion: 0.26
Nodes (12): AlertDialog, _ArtistEditorDialog, _ArtistEditorDialogState, build, dispose, _fieldRow, fig, _imagePreview (+4 more)

### Community 30 - "Community 30"
Cohesion: 0.39
Nodes (7): AlertDialog, build, _candidateRow, initState, InkWell, _ReidentifyDialog, _ReidentifyDialogState

### Community 31 - "Community 31"
Cohesion: 0.36
Nodes (7): buildAplayArgs(), buildFfmpegArgs(), createPlayer(), detectEngine(), ffmpegEngine(), mpvEngine(), pcmFormats()

### Community 32 - "Community 32"
Cohesion: 0.25
Nodes (3): RegisterGeneratedPlugins(), NSWindow, MainFlutterWindow

### Community 33 - "Community 33"
Cohesion: 0.48
Nodes (5): formatBadgeText, formatDuration, formatListenTime, initials, isHiRes

### Community 34 - "Community 34"
Cohesion: 0.33
Nodes (2): FlutterAppDelegate, AppDelegate

### Community 35 - "Community 35"
Cohesion: 0.4
Nodes (2): RunnerTests, XCTestCase

### Community 36 - "Community 36"
Cohesion: 0.6
Nodes (3): Album, _or, track.dart

### Community 37 - "Community 37"
Cohesion: 0.6
Nodes (3): cfgPath(), loadConfig(), saveConfig()

### Community 38 - "Community 38"
Cohesion: 0.6
Nodes (3): currentLrcIndex, LoadedLyrics, LrcLine

### Community 39 - "Community 39"
Cohesion: 0.5
Nodes (1): GeneratedPluginRegistrant

### Community 40 - "Community 40"
Cohesion: 0.67
Nodes (2): AriaApiException, toString

### Community 41 - "Community 41"
Cohesion: 0.67
Nodes (1): MainActivity

### Community 42 - "Community 42"
Cohesion: 0.67
Nodes (1): matchesQuery

### Community 43 - "Community 43"
Cohesion: 0.67
Nodes (1): G_DECLARE_DERIVABLE_TYPE()

### Community 44 - "Community 44"
Cohesion: 0.67
Nodes (1): G_DECLARE_DERIVABLE_TYPE()

### Community 45 - "Community 45"
Cohesion: 0.67
Nodes (1): G_DECLARE_DERIVABLE_TYPE()

### Community 46 - "Community 46"
Cohesion: 0.67
Nodes (1): G_DECLARE_DERIVABLE_TYPE()

### Community 47 - "Community 47"
Cohesion: 0.67
Nodes (1): G_DECLARE_INTERFACE()

### Community 48 - "Community 48"
Cohesion: 0.67
Nodes (1): G_DECLARE_INTERFACE()

### Community 49 - "Community 49"
Cohesion: 0.67
Nodes (1): G_DECLARE_DERIVABLE_TYPE()

### Community 50 - "Community 50"
Cohesion: 0.67
Nodes (1): G_DECLARE_INTERFACE()

### Community 51 - "Community 51"
Cohesion: 0.67
Nodes (1): G_DECLARE_DERIVABLE_TYPE()

### Community 52 - "Community 52"
Cohesion: 0.67
Nodes (1): G_DECLARE_INTERFACE()

### Community 53 - "Community 53"
Cohesion: 0.67
Nodes (1): asBool

## Knowledge Gaps
- **110 isolated node(s):** `AppDestination`, `FeatureEntry`, `AdaptiveShell`, `GoRouter`, `build` (+105 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Community 34`** (6 nodes): `AppDelegate.swift`, `FlutterAppDelegate`, `AppDelegate.swift`, `AppDelegate`, `.applicationShouldTerminateAfterLastWindowClosed()`, `.applicationSupportsSecureRestorableState()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 35`** (5 nodes): `RunnerTests.swift`, `RunnerTests.swift`, `RunnerTests`, `.testExample()`, `XCTestCase`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 39`** (4 nodes): `GeneratedPluginRegistrant.java`, `GeneratedPluginRegistrant.java`, `GeneratedPluginRegistrant`, `.registerWith()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 40`** (4 nodes): `exceptions.dart`, `exceptions.dart`, `AriaApiException`, `toString`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 41`** (3 nodes): `MainActivity.kt`, `MainActivity`, `MainActivity.kt`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 42`** (3 nodes): `translit.dart`, `translit.dart`, `matchesQuery`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 43`** (3 nodes): `fl_message_codec.h`, `G_DECLARE_DERIVABLE_TYPE()`, `fl_message_codec.h`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 44`** (3 nodes): `fl_method_codec.h`, `G_DECLARE_DERIVABLE_TYPE()`, `fl_method_codec.h`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 45`** (3 nodes): `fl_method_response.h`, `G_DECLARE_DERIVABLE_TYPE()`, `fl_method_response.h`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 46`** (3 nodes): `fl_pixel_buffer_texture.h`, `G_DECLARE_DERIVABLE_TYPE()`, `fl_pixel_buffer_texture.h`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 47`** (3 nodes): `fl_plugin_registrar.h`, `G_DECLARE_INTERFACE()`, `fl_plugin_registrar.h`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 48`** (3 nodes): `fl_plugin_registry.h`, `G_DECLARE_INTERFACE()`, `fl_plugin_registry.h`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 49`** (3 nodes): `fl_standard_message_codec.h`, `G_DECLARE_DERIVABLE_TYPE()`, `fl_standard_message_codec.h`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 50`** (3 nodes): `fl_texture.h`, `G_DECLARE_INTERFACE()`, `fl_texture.h`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 51`** (3 nodes): `fl_texture_gl.h`, `G_DECLARE_DERIVABLE_TYPE()`, `fl_texture_gl.h`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 52`** (3 nodes): `fl_texture_registrar.h`, `G_DECLARE_INTERFACE()`, `fl_texture_registrar.h`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 53`** (3 nodes): `json.dart`, `json.dart`, `asBool`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `package:aria_api/aria_api.dart` connect `Community 0` to `Community 1`, `Community 3`, `Community 7`, `Community 9`, `Community 10`, `Community 11`, `Community 13`, `Community 14`, `Community 18`, `Community 19`, `Community 20`, `Community 21`, `Community 22`, `Community 23`, `Community 24`, `Community 25`, `Community 26`, `Community 29`, `Community 30`?**
  _High betweenness centrality (0.226) - this node is a cross-community bridge._
- **Why does `package:flutter_riverpod/flutter_riverpod.dart` connect `Community 0` to `Community 1`, `Community 3`, `Community 5`, `Community 7`, `Community 9`, `Community 10`, `Community 13`, `Community 14`, `Community 18`, `Community 19`, `Community 20`, `Community 21`, `Community 22`, `Community 23`, `Community 24`, `Community 25`, `Community 26`, `Community 29`, `Community 30`?**
  _High betweenness centrality (0.221) - this node is a cross-community bridge._
- **Why does `package:flutter/material.dart` connect `Community 5` to `Community 0`, `Community 1`, `Community 7`, `Community 9`, `Community 10`, `Community 13`, `Community 14`, `Community 19`, `Community 20`, `Community 21`, `Community 22`, `Community 23`, `Community 24`, `Community 25`, `Community 26`, `Community 29`, `Community 30`?**
  _High betweenness centrality (0.129) - this node is a cross-community bridge._
- **What connects `AppDestination`, `FeatureEntry`, `AdaptiveShell` to the rest of the system?**
  _110 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.02 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.02 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.04 - nodes in this community are weakly interconnected._