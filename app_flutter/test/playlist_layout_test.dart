import 'package:aria/core/connection.dart';
import 'package:aria/core/playlists_providers.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria/core/theme.dart';
import 'package:aria/features/library/tracks_section.dart';
import 'package:aria/features/playlists/playlist_screen.dart';
import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The playlist page stopped being one ListView when it took on the library's
/// track table: the header is now fixed and only the table scrolls. That is
/// what makes the two pages identical, but it also means the header has to
/// survive a window short enough that it no longer fits.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const tracks = [
    Track(id: 't1', albumId: 'al', title: 'One', artist: 'A', album: 'Rec'),
    Track(id: 't2', albumId: 'al', title: 'Two', artist: 'B', album: 'Rec'),
  ];

  Future<Widget> app() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final player = AriaPlayer(rawFactory: () => throw StateError('test'));
    return ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        ariaPlayerProvider.overrideWithValue(player),
        apiClientProvider.overrideWithValue(
          AriaClient(
            baseUrl: 'http://s',
            httpClient: MockClient((_) async => http.Response('{}', 200)),
          ),
        ),
        playlistsProvider.overrideWith(() => _StubPlaylists()),
        playlistTracksProvider(
          'p1',
        ).overrideWith((ref) => Future.value(tracks)),
      ],
      child: MaterialApp(
        theme: AriaTheme.light(),
        home: const PlaylistScreen(id: 'p1'),
      ),
    );
  }

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(await app());
    await tester.pumpAndSettle();
  }

  // Landscape phone, then a small desktop window that is narrow enough to
  // wrap the action buttons onto extra lines AND short enough to squeeze.
  for (final size in const [
    Size(1280, 800),
    Size(740, 360),
    Size(420, 320),
    Size(380, 240),
  ]) {
    testWidgets('no overflow at ${size.width}x${size.height}', (tester) async {
      await pumpAt(tester, size);
      expect(tester.takeException(), isNull);
      expect(find.byType(TrackTable), findsOneWidget);
    });
  }
}

class _StubPlaylists extends PlaylistsNotifier {
  @override
  Future<List<Playlist>> build() async => const [
    // A long name and five action buttons: the tallest the header gets.
    Playlist(
      id: 'p1',
      profileId: 'pr',
      name: 'A Manual Playlist With A Fairly Long Name',
      type: 'manual',
      trackIds: ['t1', 't2'],
    ),
  ];
}
