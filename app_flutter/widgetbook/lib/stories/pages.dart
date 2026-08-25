import 'package:aria/core/connection.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria/features/album/album_page.dart';
import 'package:aria/features/album/booklet_screen.dart';
import 'package:aria/features/artist/artist_page.dart';
import 'package:aria/features/artist/composer_page.dart';
import 'package:aria/features/home/home_screen.dart';
import 'package:aria/features/home/mix_screen.dart';
import 'package:aria/features/library/composition_screen.dart';
import 'package:aria/features/library/genre_screen.dart';
import 'package:aria/features/library/library_screen.dart';
import 'package:aria/features/listen_later/listen_later_screen.dart';
import 'package:aria/features/now_playing/lyrics_view.dart';
import 'package:aria/features/now_playing/now_playing_screen.dart';
import 'package:aria/features/now_playing/queue_screen.dart';
import 'package:aria/features/playlists/playlist_screen.dart';
import 'package:aria/features/playlists/playlists_screen.dart';
import 'package:aria/features/radio/radio_page.dart';
import 'package:aria/features/release/release_page.dart';
import 'package:aria/features/review/review_screen.dart';
import 'package:aria/features/search/search_page.dart';
import 'package:aria/features/settings/about_screen.dart';
import 'package:aria/features/settings/account_screen.dart';
import 'package:aria/features/settings/data_screen.dart';
import 'package:aria/features/settings/downloads_screen.dart';
import 'package:aria/features/settings/eq_browse.dart';
import 'package:aria/features/settings/eq_screen.dart';
import 'package:aria/features/settings/health_screen.dart';
import 'package:aria/features/settings/library_screen.dart' as settings;
import 'package:aria/features/settings/logs_screen.dart';
import 'package:aria/features/settings/playback_screen.dart';
import 'package:aria/features/settings/settings_page.dart';
import 'package:aria/features/stats/stats_page.dart';
import 'package:aria/features/tags/tag_screen.dart';
import 'package:aria/features/tags/tags_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../fixtures.dart';
import 'catalogue.dart';

/// Every destination in the app, mounted whole.
///
/// The rest of the catalogue is components in isolation; this file is the
/// other half — the arrangements. A component story answers "does this widget
/// look right"; a page story answers "does the page it lives on hold
/// together" — padding, scroll extent, empty states, the appbar, the lot.
///
/// Route parameters are read off the fixtures where the fixture exposes the
/// value — an album id, a playlist id, a tag id — so a renamed id fails to
/// compile instead of quietly rendering an empty page. The rest are literals
/// naming fixture content (`'Jazz'`, `'Miles Davis'`, the `'daily'` mix); the
/// render test is what catches those going stale, since the page falls to its
/// empty state and the golden changes.
///
/// Grouped into a `Pages` folder inside each feature's category, so the
/// components a page is built from stay one click away from the page itself.

/// Anything under `/nowplaying` collapses to nothing with a silent engine and
/// an empty queue. This puts the fixture album in the real QueueNotifier on
/// mount — same trick the now-playing component stories use, wrapped round a
/// child instead of sitting beside one.
class WithQueue extends ConsumerStatefulWidget {
  const WithQueue({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WithQueue> createState() => _WithQueueState();
}

class _WithQueueState extends ConsumerState<WithQueue> {
  @override
  void initState() {
    super.initState();
    // Post-frame: playQueue mutates a provider, and the subtree that reads it
    // is still building. Only when empty, so reopening a page does not stamp
    // on a queue set up by hand.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(queueProvider).tracks.isEmpty) {
        ref.read(queueProvider.notifier).playQueue(fixtureTracks, 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A page entry — always in the `Pages` folder, always named for its class.
Entry _page(String component, String key, Story builder,
        {String useCase = 'Default', bool golden = true}) =>
    Entry(
      folder: 'Pages',
      component: component,
      useCase: useCase,
      key: 'page-$key',
      builder: builder,
      golden: golden,
    );

// -------------------------------------------------------------------- shell

final shellPages = <Entry>[
  // Not reachable from the shell — it is what the app shows *instead* of the
  // shell until a server URL resolves. Catalogued here because it is the
  // other thing core/ can put on screen.
  _page('ServerSetupScreen', 'server-setup', (_) => const ServerSetupScreen()),
];

// --------------------------------------------------------------------- home

final homePages = <Entry>[
  // Wall clock: the mixes shelf names the current month and year, and the
  // listening section buckets plays against today.
  _page('HomeScreen', 'home', (_) => const HomeScreen(), golden: false),
  _page('MixScreen', 'mix', (_) => const MixScreen(id: 'daily')),
];

// ------------------------------------------------------------------ library

final libraryPages = <Entry>[
  _page('LibraryHubScreen', 'library-hub', (_) => const LibraryHubScreen()),
  for (final section in LibrarySection.values)
    _page(
      'LibraryScreen',
      'library-${section.name}',
      (_) => LibraryScreen(section: section),
      useCase: section.label,
    ),
  _page('GenreScreen', 'genre', (_) => const GenreScreen(genre: 'Jazz')),
  _page(
    'CompositionScreen',
    'composition',
    (_) => CompositionScreen(
      name: fixtureTracks.firstWhere((t) => t.work != null).work!,
    ),
  ),
];

// -------------------------------------------------------------------- album

final albumPages = <Entry>[
  _page(
    'AlbumPage',
    'album',
    (_) => AlbumPage(albumId: fixtureAlbums.first.id),
  ),
  // pdfrx renders the PDF itself, so the stub serves a real one — see
  // `_pdf()` in fake_server.dart. Anything else and this use case would
  // catalogue the viewer's error state instead of the viewer.
  _page(
    'BookletScreen',
    'booklet',
    (_) => BookletScreen(
      albumId: fixtureAlbums.first.id,
      name: 'booklet.pdf',
    ),
  ),
];

// ------------------------------------------------------------------- artist

final artistPages = <Entry>[
  // Wall clock: the overview tab ranks by recent plays.
  _page(
    'ArtistPage',
    'artist',
    (_) => const ArtistPage(name: 'Miles Davis'),
    golden: false,
  ),
  _page(
    'ComposerPage',
    'composer',
    (_) => const ComposerPage(name: 'Johann Sebastian Bach'),
  ),
];

// -------------------------------------------------------------- now playing

final nowPlayingPages = <Entry>[
  _page(
    'NowPlayingScreen',
    'now-playing',
    (_) => const WithQueue(child: NowPlayingScreen()),
  ),
  _page('QueueScreen', 'queue', (_) => const WithQueue(child: QueueScreen())),
  _page(
    'LyricsScreen',
    'lyrics',
    (_) => const WithQueue(child: LyricsScreen()),
  ),
];

// ---------------------------------------------------------------- playlists

final playlistPages = <Entry>[
  _page('PlaylistsScreen', 'playlists', (_) => const PlaylistsScreen()),
  _page(
    'PlaylistScreen',
    'playlist',
    (_) => PlaylistScreen(id: fixturePlaylists.first.id),
  ),
];

// ------------------------------------------------------------- listen later

final listenLaterPages = <Entry>[
  _page(
    'ListenLaterScreen',
    'listen-later',
    (_) => const ListenLaterScreen(),
  ),
];

// -------------------------------------------------------------------- radio

final radioPages = <Entry>[
  _page('RadioPage', 'radio', (_) => const RadioPage()),
];

// ------------------------------------------------------------------ release

final releasePages = <Entry>[
  // An album the library does not own, so the page falls through to the
  // external lookup rather than redirecting to AlbumPage.
  _page(
    'ReleasePage',
    'release',
    (_) => ReleasePage(
      ref_: ReleaseRef(
        fixtureExtAlbum.artist,
        fixtureExtAlbum.title,
        deezerId: fixtureExtAlbum.deezerId,
      ),
    ),
  ),
];

// ------------------------------------------------------------------- review

final reviewPages = <Entry>[
  _page('ReviewScreen', 'review', (_) => const ReviewScreen()),
];

// ------------------------------------------------------------------- search

final searchPages = <Entry>[
  _page('SearchPage', 'search', (_) => const SearchPage()),
];

// ----------------------------------------------------------------- settings

final settingsPages = <Entry>[
  _page('SettingsPage', 'settings', (_) => const SettingsPage()),
  _page('AccountScreen', 'settings-account', (_) => const AccountScreen()),
  _page('PlaybackScreen', 'settings-playback', (_) => const PlaybackScreen()),
  _page('EqScreen', 'settings-eq', (_) => const EqScreen()),
  _page('EqBrandsScreen', 'settings-eq-brands', (_) => const EqBrandsScreen()),
  _page(
    'EqHeadphonesScreen',
    'settings-eq-headphones',
    (_) => EqHeadphonesScreen(vendor: fixtureOpraProducts.first.vendor),
  ),
  _page(
    'EqCurvesScreen',
    'settings-eq-curves',
    (_) => EqCurvesScreen(product: fixtureOpraProducts.first),
  ),
  _page('DataScreen', 'settings-data', (_) => const DataScreen()),
  _page(
    'DownloadsScreen',
    'settings-downloads',
    (_) => const DownloadsScreen(),
  ),
  _page(
    'LibraryScreen',
    'settings-library',
    (_) => const settings.LibraryScreen(),
  ),
  _page('HealthScreen', 'settings-health', (_) => const HealthScreen()),
  // Wall clock: every line is stamped with the time it was written.
  _page(
    'LogsScreen',
    'settings-logs',
    (_) => const LogsScreen(),
    golden: false,
  ),
  _page('AboutScreen', 'settings-about', (_) => const AboutScreen()),
];

// -------------------------------------------------------------------- stats
// Wall clock: every chart buckets against today.

final statsPages = <Entry>[
  _page('StatsPage', 'stats', (_) => const StatsPage(), golden: false),
];

// --------------------------------------------------------------------- tags

final tagPages = <Entry>[
  _page('TagsScreen', 'tags', (_) => const TagsScreen()),
  _page(
    'TagScreen',
    'tag',
    (_) => TagScreen(id: fixtureTags.firstWhere((t) => !t.folder).id),
  ),
];
