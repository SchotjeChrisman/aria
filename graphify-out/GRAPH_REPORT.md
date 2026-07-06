# Graph Report - transport-bar-responsive  (2026-07-06)

## Corpus Check
- 195 files · ~98,842 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1996 nodes · 4517 edges · 43 communities detected
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
- `renderHome()` --calls--> `tile`  [INFERRED]
  app/ui/app.js → /home/chris/Repositories/roon/app_flutter/lib/features/home/home_screen.dart
- `evalRule()` --calls--> `one`  [INFERRED]
  server/server.js → /home/chris/Repositories/roon/app_flutter/lib/features/library/track_filters.dart
- `buildListening()` --calls--> `dayKey`  [INFERRED]
  app/ui/app.js → /home/chris/Repositories/roon/app_flutter/lib/features/stats/stats_page.dart
- `buildFilterRows()` --calls--> `Row`  [INFERRED]
  app/ui/app.js → /home/chris/Repositories/roon/app_flutter/lib/widgets/filter_bar.dart

## Communities

### Community 0 - "Community 0"
Cohesion: 0.02
Nodes (169): charts.dart, ../core/formats.dart, ../core/player_providers.dart, ../core/theme.dart, edit_metadata_dialog.dart, format_badge.dart, _AlbumBody, AlbumPage (+161 more)

### Community 1 - "Community 1"
Cohesion: 0.03
Nodes (113): connection.dart, ../core/connection.dart, ../../core/library_providers.dart, ../../core/profiles_providers.dart, ../core/tag_tree.dart, ../core/tags_providers.dart, dart:async, dart:convert (+105 more)

### Community 2 - "Community 2"
Cohesion: 0.04
Nodes (160): $(), activeFilterCount(), addTrackTo(), albumCard(), albumCtx(), albumPassesFilters(), albumType(), api() (+152 more)

### Community 3 - "Community 3"
Cohesion: 0.03
Nodes (57): albumCache, AlbumCandidate, ArtistCandidate, ArtistDiscography, ArtistEntry, Composer, ComposerEntry, Deezer (+49 more)

### Community 4 - "Community 4"
Cohesion: 0.04
Nodes (88): httpError(), New(), NewHub(), readJSON(), register(), requireFields(), writeJSON(), init() (+80 more)

### Community 5 - "Community 5"
Cohesion: 0.03
Nodes (77): album_page.dart, art_image.dart, artist_discography.dart, artist_info_tab.dart, artist_overview.dart, ../../core/router.dart, edit_artist_dialog.dart, genre_screen.dart (+69 more)

### Community 6 - "Community 6"
Cohesion: 0.04
Nodes (97): album_filters.dart, albums_section.dart, artists_section.dart, composers_section.dart, dart:collection, genre_card.dart, genres_section.dart, _addedMs (+89 more)

### Community 7 - "Community 7"
Cohesion: 0.03
Nodes (38): Deps, NewDeps(), Enricher, Scanner, Edits, NewEdits(), Enrich, NewEnrich() (+30 more)

### Community 8 - "Community 8"
Cohesion: 0.04
Nodes (72): dart:ffi, dart:io, AlbumFilters, AlbumFiltersNotifier, albumPassesFilters, build, clear, copyWith (+64 more)

### Community 9 - "Community 9"
Cohesion: 0.04
Nodes (69): artist_page.dart, artist_util.dart, composer_page.dart, external_link.dart, ArtistInfoTab, _Bio, build, Column (+61 more)

### Community 10 - "Community 10"
Cohesion: 0.05
Nodes (62): AlertDialog, build, _clearAll, dispose, _EditorDialog, _EditorDialogState, _Field, _fieldRow (+54 more)

### Community 11 - "Community 11"
Cohesion: 0.05
Nodes (51): exceptions.dart, AriaApiException, AriaClient, artUrl, close, _get, jsonDecode, _post (+43 more)

### Community 12 - "Community 12"
Cohesion: 0.06
Nodes (54): AudioFormat, command, create, FakeMpvRaw, initialize, main, observeProperty, PlayerUnavailableException (+46 more)

### Community 13 - "Community 13"
Cohesion: 0.06
Nodes (25): Playlist, Playlists, NewPlaylists(), nullRaw(), scanPlaylist(), createEnricher(), get(), mb() (+17 more)

### Community 14 - "Community 14"
Cohesion: 0.11
Nodes (30): ../features/album/routes.dart, ../features/artist/routes.dart, ../features/home/routes.dart, ../features/library/routes.dart, ../features/now_playing/routes.dart, ../features/playlists/routes.dart, ../features/radio/routes.dart, ../features/search/routes.dart (+22 more)

### Community 15 - "Community 15"
Cohesion: 0.12
Nodes (19): Album, Albums, NewAlbums(), fileEntry, Scanner, durPtr(), first(), intPtr() (+11 more)

### Community 16 - "Community 16"
Cohesion: 0.12
Nodes (30): AudioExclusiveNotifier, build, clear, clearForRadio, copyWith, move, next, _onEnded (+22 more)

### Community 17 - "Community 17"
Cohesion: 0.12
Nodes (18): main(), Config, FromEnv(), getenv(), build, enter, exit, SelectionItem (+10 more)

### Community 18 - "Community 18"
Cohesion: 0.15
Nodes (23): AlbumCard, _AlbumShelf, AsyncData, AsyncError, build, _ChartBox, Container, dayKey (+15 more)

### Community 19 - "Community 19"
Cohesion: 0.15
Nodes (21): AlertDialog, build, ConstrainedBox, Container, dispose, _hex, InkWell, MenuAnchor (+13 more)

### Community 20 - "Community 20"
Cohesion: 0.18
Nodes (19): build, Column, dispose, _ExclusiveToggle, _LibraryTools, _ListenBrainzField, _ListenBrainzFieldState, Padding (+11 more)

### Community 21 - "Community 21"
Cohesion: 0.18
Nodes (17): context_menu.dart, ../core/playlists_providers.dart, ../core/selection.dart, act, build, Container, SelectionBar, SizedBox (+9 more)

### Community 22 - "Community 22"
Cohesion: 0.22
Nodes (15): build, Column, dispose, InkWell, _RadioCard, RadioPage, _RadioPageState, Scaffold (+7 more)

### Community 23 - "Community 23"
Cohesion: 0.18
Nodes (11): fl_register_plugins(), main(), first_frame_cb(), my_application_activate(), my_application_class_init(), my_application_dispose(), my_application_init(), my_application_local_command_line() (+3 more)

### Community 24 - "Community 24"
Cohesion: 0.26
Nodes (12): AlertDialog, _ArtistEditorDialog, _ArtistEditorDialogState, build, dispose, _fieldRow, fig, _imagePreview (+4 more)

### Community 25 - "Community 25"
Cohesion: 0.26
Nodes (12): command, create, initialize, MpvEventData, MpvRaw, observeProperty, PlayerUnavailableException, setOptionString (+4 more)

### Community 26 - "Community 26"
Cohesion: 0.3
Nodes (10): BarChart, _BarsPainter, build, ChartPoint, Container, MiniList, MiniListRow, paint (+2 more)

### Community 27 - "Community 27"
Cohesion: 0.36
Nodes (7): buildAplayArgs(), buildFfmpegArgs(), createPlayer(), detectEngine(), ffmpegEngine(), mpvEngine(), pcmFormats()

### Community 28 - "Community 28"
Cohesion: 0.43
Nodes (6): albumPath, artistPath, BioBlock, composerPath, decodeArtistRouteParam, normTitle

### Community 29 - "Community 29"
Cohesion: 0.43
Nodes (6): build, countLabel, Function, GestureDetector, PersonCard, SizedBox

### Community 30 - "Community 30"
Cohesion: 0.25
Nodes (3): RegisterGeneratedPlugins(), NSWindow, MainFlutterWindow

### Community 31 - "Community 31"
Cohesion: 0.48
Nodes (5): formatBadgeText, formatDuration, formatListenTime, initials, isHiRes

### Community 32 - "Community 32"
Cohesion: 0.67
Nodes (5): dzServer(), TestAlbumCoverURL(), TestDiscography(), TestSearchArtist(), TestSimilar()

### Community 33 - "Community 33"
Cohesion: 0.33
Nodes (2): FlutterAppDelegate, AppDelegate

### Community 34 - "Community 34"
Cohesion: 0.4
Nodes (2): RunnerTests, XCTestCase

### Community 35 - "Community 35"
Cohesion: 0.6
Nodes (3): Album, _or, track.dart

### Community 36 - "Community 36"
Cohesion: 0.6
Nodes (3): cfgPath(), loadConfig(), saveConfig()

### Community 37 - "Community 37"
Cohesion: 0.6
Nodes (3): currentLrcIndex, LoadedLyrics, LrcLine

### Community 38 - "Community 38"
Cohesion: 0.5
Nodes (1): GeneratedPluginRegistrant

### Community 39 - "Community 39"
Cohesion: 0.67
Nodes (2): AriaApiException, toString

### Community 40 - "Community 40"
Cohesion: 0.67
Nodes (1): MainActivity

### Community 41 - "Community 41"
Cohesion: 0.67
Nodes (1): matchesQuery

### Community 42 - "Community 42"
Cohesion: 0.67
Nodes (1): asBool

## Knowledge Gaps
- **102 isolated node(s):** `TransportBar`, `_TransportBarState`, `build`, `Column`, `Row` (+97 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Community 33`** (6 nodes): `AppDelegate.swift`, `FlutterAppDelegate`, `AppDelegate.swift`, `AppDelegate`, `.applicationShouldTerminateAfterLastWindowClosed()`, `.applicationSupportsSecureRestorableState()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 34`** (5 nodes): `RunnerTests.swift`, `RunnerTests.swift`, `RunnerTests`, `.testExample()`, `XCTestCase`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 38`** (4 nodes): `GeneratedPluginRegistrant.java`, `GeneratedPluginRegistrant.java`, `GeneratedPluginRegistrant`, `.registerWith()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 39`** (4 nodes): `exceptions.dart`, `exceptions.dart`, `AriaApiException`, `toString`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 40`** (3 nodes): `MainActivity.kt`, `MainActivity`, `MainActivity.kt`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 41`** (3 nodes): `translit.dart`, `translit.dart`, `matchesQuery`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 42`** (3 nodes): `json.dart`, `json.dart`, `asBool`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `package:flutter_riverpod/flutter_riverpod.dart` connect `Community 1` to `Community 0`, `Community 5`, `Community 6`, `Community 8`, `Community 9`, `Community 10`, `Community 12`, `Community 14`, `Community 16`, `Community 17`, `Community 18`, `Community 19`, `Community 20`, `Community 21`, `Community 22`, `Community 24`?**
  _High betweenness centrality (0.227) - this node is a cross-community bridge._
- **Why does `package:aria_api/aria_api.dart` connect `Community 1` to `Community 0`, `Community 5`, `Community 6`, `Community 8`, `Community 9`, `Community 10`, `Community 12`, `Community 14`, `Community 16`, `Community 17`, `Community 18`, `Community 19`, `Community 20`, `Community 21`, `Community 22`, `Community 24`, `Community 28`?**
  _High betweenness centrality (0.212) - this node is a cross-community bridge._
- **Why does `package:flutter/material.dart` connect `Community 5` to `Community 0`, `Community 1`, `Community 6`, `Community 9`, `Community 10`, `Community 12`, `Community 14`, `Community 18`, `Community 19`, `Community 20`, `Community 21`, `Community 22`, `Community 24`, `Community 26`, `Community 29`?**
  _High betweenness centrality (0.128) - this node is a cross-community bridge._
- **What connects `TransportBar`, `_TransportBarState`, `build` to the rest of the system?**
  _102 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.02 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.03 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.04 - nodes in this community are weakly interconnected._