# Graph Report - roon  (2026-07-06)

## Corpus Check
- 222 files · ~115,098 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1790 nodes · 2864 edges · 40 communities detected
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 177 edges (avg confidence: 0.8)
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
- [[_COMMUNITY_Community 49|Community 49]]

## God Nodes (most connected - your core abstractions)
1. `package:flutter/material.dart` - 76 edges
2. `package:flutter_riverpod/flutter_riverpod.dart` - 68 edges
3. `package:aria_api/aria_api.dart` - 65 edges
4. `../../core/theme.dart` - 58 edges
5. `$()` - 41 edges
6. `Enricher` - 36 edges
7. `package:go_router/go_router.dart` - 33 edges
8. `../../core/connection.dart` - 30 edges
9. `esc()` - 29 edges
10. `disp()` - 26 edges

## Surprising Connections (you probably didn't know these)
- `tile` --calls--> `renderHome()`  [INFERRED]
  app_flutter/lib/features/home/home_screen.dart → app/ui/app.js
- `mk()` --calls--> `api()`  [INFERRED]
  server/test.js → app/ui/app.js
- `evalRule()` --calls--> `one`  [INFERRED]
  server/internal/api/playlists.go → app_flutter/lib/features/library/track_filters.dart
- `creditsByRecording()` --calls--> `contains`  [INFERRED]
  server/internal/enrich/musicbrainz.go → app_flutter/lib/core/selection.dart
- `readBandRels()` --calls--> `contains`  [INFERRED]
  server/internal/enrich/enrich.go → app_flutter/lib/core/selection.dart

## Communities

### Community 0 - "Community 0"
Cohesion: 0.01
Nodes (234): album_page.dart, art_image.dart, artist_discography.dart, artist_info_tab.dart, artist_overview.dart, artist_page.dart, artist_util.dart, composer_page.dart (+226 more)

### Community 1 - "Community 1"
Cohesion: 0.02
Nodes (156): charts.dart, connection.dart, context_menu.dart, ../../core/connection.dart, ../../core/library_providers.dart, ../../core/player_providers.dart, ../../core/playlists_providers.dart, ../../core/profiles_providers.dart (+148 more)

### Community 2 - "Community 2"
Cohesion: 0.04
Nodes (161): Row, $(), activeFilterCount(), addTrackTo(), albumCard(), albumCtx(), albumPassesFilters(), albumType() (+153 more)

### Community 3 - "Community 3"
Cohesion: 0.02
Nodes (99): album_filters.dart, albums_section.dart, artists_section.dart, composers_section.dart, dart:collection, genre_card.dart, genres_section.dart, _addedMs (+91 more)

### Community 4 - "Community 4"
Cohesion: 0.02
Nodes (46): Deps, NewDeps(), Enricher, Scanner, Album, Albums, NewAlbums(), Edits (+38 more)

### Community 5 - "Community 5"
Cohesion: 0.04
Nodes (86): httpError(), NewHub(), register(), requireFields(), writeJSON(), init(), registerArt(), builtinStation (+78 more)

### Community 6 - "Community 6"
Cohesion: 0.02
Nodes (90): AudioExclusiveNotifier, build, clear, clearForRadio, copyWith, move, next, _onEnded (+82 more)

### Community 7 - "Community 7"
Cohesion: 0.03
Nodes (75): New(), main(), Config, FromEnv(), getenv(), dart:ffi, build, enter (+67 more)

### Community 8 - "Community 8"
Cohesion: 0.04
Nodes (43): Composer, Deezer, NewDeezer(), dzServer(), TestAlbumCoverURL(), TestDiscography(), TestSearchArtist(), TestSimilar() (+35 more)

### Community 9 - "Community 9"
Cohesion: 0.08
Nodes (19): albumCache, AlbumCandidate, ArtistCandidate, ArtistDiscography, ArtistEntry, ComposerEntry, firstOf(), hasWikiRel() (+11 more)

### Community 10 - "Community 10"
Cohesion: 0.05
Nodes (42): edit_metadata_dialog.dart, _AlbumBody, AlbumPage, _artistPath, build, Column, Container, CreditCard (+34 more)

### Community 11 - "Community 11"
Cohesion: 0.05
Nodes (34): dart:convert, exceptions.dart, AriaApiException, AriaClient, artUrl, _get, jsonDecode, _post (+26 more)

### Community 12 - "Community 12"
Cohesion: 0.05
Nodes (31): AlbumCandidate, AlbumInfo, ArtistCandidate, ArtistInfo, ComposerInfo, DiscographyItem, EnrichStatus, Lyrics (+23 more)

### Community 13 - "Community 13"
Cohesion: 0.08
Nodes (17): Hub, close, Playlist, Playlists, nullRaw(), scanPlaylist(), fileEntry, Scanner (+9 more)

### Community 14 - "Community 14"
Cohesion: 0.05
Nodes (33): build, CreditCard, InkWell, SizedBox, build, InkWell, PersonCard, SizedBox (+25 more)

### Community 15 - "Community 15"
Cohesion: 0.06
Nodes (30): ../features/album/routes.dart, ../features/artist/routes.dart, ../features/home/routes.dart, ../features/library/routes.dart, ../features/now_playing/routes.dart, ../features/playlists/routes.dart, ../features/radio/routes.dart, ../features/search/routes.dart (+22 more)

### Community 16 - "Community 16"
Cohesion: 0.1
Nodes (17): createEnricher(), get(), mb(), sleep(), loadIndex(), scan(), sha1(), splitWork() (+9 more)

### Community 17 - "Community 17"
Cohesion: 0.07
Nodes (27): AlertDialog, apply, build, _changed, clear, Column, dispose, dropdown (+19 more)

### Community 18 - "Community 18"
Cohesion: 0.08
Nodes (22): build, _changed, Column, dispose, initState, InkWell, MultiSelectField, _MultiSelectFieldState (+14 more)

### Community 19 - "Community 19"
Cohesion: 0.09
Nodes (21): AlertDialog, build, ConstrainedBox, Container, dispose, _hex, InkWell, MenuAnchor (+13 more)

### Community 20 - "Community 20"
Cohesion: 0.1
Nodes (19): build, Column, dispose, _ExclusiveToggle, _LibraryTools, _ListenBrainzField, _ListenBrainzFieldState, Padding (+11 more)

### Community 21 - "Community 21"
Cohesion: 0.12
Nodes (15): build, Column, dispose, InkWell, _RadioCard, RadioPage, _RadioPageState, Scaffold (+7 more)

### Community 22 - "Community 22"
Cohesion: 0.14
Nodes (4): fl_register_plugins(), main(), my_application_activate(), my_application_new()

### Community 23 - "Community 23"
Cohesion: 0.14
Nodes (13): command, create, initialize, MpvEventData, MpvRaw, observeProperty, PlayerUnavailableException, requestLogMessages (+5 more)

### Community 24 - "Community 24"
Cohesion: 0.15
Nodes (12): AlertDialog, _ArtistEditorDialog, _ArtistEditorDialogState, build, dispose, _fieldRow, fig, _imagePreview (+4 more)

### Community 25 - "Community 25"
Cohesion: 0.36
Nodes (7): buildAplayArgs(), buildFfmpegArgs(), createPlayer(), detectEngine(), ffmpegEngine(), mpvEngine(), pcmFormats()

### Community 26 - "Community 26"
Cohesion: 0.25
Nodes (7): AriaColors, copyWith, dark, l, lerp, light, of

### Community 27 - "Community 27"
Cohesion: 0.29
Nodes (6): albumPath, artistPath, BioBlock, composerPath, decodeArtistRouteParam, normTitle

### Community 28 - "Community 28"
Cohesion: 0.33
Nodes (5): formatBadgeText, formatDuration, formatListenTime, initials, isHiRes

### Community 29 - "Community 29"
Cohesion: 0.33
Nodes (3): RegisterGeneratedPlugins(), NSWindow, MainFlutterWindow

### Community 30 - "Community 30"
Cohesion: 0.4
Nodes (2): FlutterAppDelegate, AppDelegate

### Community 31 - "Community 31"
Cohesion: 0.6
Nodes (3): cfgPath(), loadConfig(), saveConfig()

### Community 32 - "Community 32"
Cohesion: 0.5
Nodes (3): currentLrcIndex, LoadedLyrics, LrcLine

### Community 33 - "Community 33"
Cohesion: 0.5
Nodes (2): RunnerTests, XCTestCase

### Community 34 - "Community 34"
Cohesion: 0.5
Nodes (3): Album, _or, track.dart

### Community 35 - "Community 35"
Cohesion: 0.67
Nodes (1): GeneratedPluginRegistrant

### Community 36 - "Community 36"
Cohesion: 0.67
Nodes (2): AriaApiException, toString

### Community 37 - "Community 37"
Cohesion: 1.0
Nodes (1): MainActivity

### Community 38 - "Community 38"
Cohesion: 1.0
Nodes (1): matchesQuery

### Community 49 - "Community 49"
Cohesion: 1.0
Nodes (1): asBool

## Knowledge Gaps
- **938 isolated node(s):** `Config`, `Track`, `PathInfo`, `Album`, `TagItem` (+933 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Community 30`** (5 nodes): `AppDelegate.swift`, `FlutterAppDelegate`, `AppDelegate`, `.applicationShouldTerminateAfterLastWindowClosed()`, `.applicationSupportsSecureRestorableState()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 33`** (4 nodes): `RunnerTests.swift`, `RunnerTests`, `.testExample()`, `XCTestCase`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 35`** (3 nodes): `GeneratedPluginRegistrant.java`, `GeneratedPluginRegistrant`, `.registerWith()`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 36`** (3 nodes): `exceptions.dart`, `AriaApiException`, `toString`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 37`** (2 nodes): `MainActivity.kt`, `MainActivity`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 38`** (2 nodes): `translit.dart`, `matchesQuery`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 49`** (2 nodes): `json.dart`, `asBool`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `package:aria_api/aria_api.dart` connect `Community 1` to `Community 0`, `Community 3`, `Community 6`, `Community 7`, `Community 10`, `Community 11`, `Community 14`, `Community 15`, `Community 17`, `Community 18`, `Community 19`, `Community 20`, `Community 21`, `Community 24`, `Community 27`?**
  _High betweenness centrality (0.231) - this node is a cross-community bridge._
- **Why does `package:flutter_riverpod/flutter_riverpod.dart` connect `Community 1` to `Community 0`, `Community 3`, `Community 6`, `Community 7`, `Community 10`, `Community 14`, `Community 15`, `Community 17`, `Community 18`, `Community 19`, `Community 20`, `Community 21`, `Community 24`?**
  _High betweenness centrality (0.220) - this node is a cross-community bridge._
- **Why does `contains` connect `Community 5` to `Community 8`, `Community 9`, `Community 7`?**
  _High betweenness centrality (0.136) - this node is a cross-community bridge._
- **What connects `Config`, `Track`, `PathInfo` to the rest of the system?**
  _938 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.01 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.02 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.04 - nodes in this community are weakly interconnected._