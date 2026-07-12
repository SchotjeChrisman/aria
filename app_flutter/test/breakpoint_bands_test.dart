import 'package:aria/core/connection.dart';
import 'package:aria/core/library_providers.dart';
import 'package:aria/core/log_sync.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria/core/playlists_providers.dart';
import 'package:aria/core/router.dart';
import 'package:aria/core/theme.dart';
import 'package:aria/features/playlists/playlists_screen.dart';
import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Spec 2026-07-08-responsive-ui-design: band cuts at 600/1240, fixed grid
/// columns per band, and AdaptiveShell chrome morphing per band.
class _StubPlaylists extends PlaylistsNotifier {
  @override
  Future<List<Playlist>> build() async => [
    for (var i = 0; i < 8; i++)
      Playlist(
        id: 'p$i',
        profileId: 'pr',
        name: 'Playlist $i',
        type: 'manual',
        trackIds: const [],
      ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> makeContainer() async {
    SharedPreferences.setMockInitialValues({'aria.serverUrl': 'http://s'});
    final prefs = await SharedPreferences.getInstance();
    // ponytail: unavailable player (rawFactory throws) — every command
    // no-ops, which is all a pure layout test needs.
    final player = AriaPlayer(rawFactory: () => throw StateError('test'));
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        ariaPlayerProvider.overrideWithValue(player),
        // Inert: the real one keeps an SSE-reconnect timer alive, which
        // trips the pending-timer invariant at test teardown.
        enrichRefreshProvider.overrideWith((ref) {}),
        // Same invariant: the real one runs a 5-min upload timer.
        logSyncProvider.overrideWith(
          (ref) => LogSync(prefs: prefs, file: () => null, upload: (_) async {}),
        ),
        // No server in tests: the real fetch fails and riverpod's retry
        // timer trips the pending-timer invariant at teardown.
        libraryTracksProvider.overrideWith((ref) async => const []),
        playlistsProvider.overrideWith(_StubPlaylists.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('AriaBreakpoint.fromWidth', () {
    test('cuts at 600 and 1240', () {
      expect(AriaBreakpoint.fromWidth(0), AriaBreakpoint.mobile);
      expect(AriaBreakpoint.fromWidth(599), AriaBreakpoint.mobile);
      expect(AriaBreakpoint.fromWidth(600), AriaBreakpoint.tablet);
      expect(AriaBreakpoint.fromWidth(1239), AriaBreakpoint.tablet);
      expect(AriaBreakpoint.fromWidth(1240), AriaBreakpoint.desktop);
    });

    test('gridColumns is 2/4/6 per band', () {
      expect(AriaBreakpoint.mobile.gridColumns, 2);
      expect(AriaBreakpoint.tablet.gridColumns, 4);
      expect(AriaBreakpoint.desktop.gridColumns, 6);
    });
  });

  group('AdaptiveShell chrome per band', () {
    Future<void> pumpShell(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = await makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: AriaTheme.light(),
            routerConfig: container.read(routerProvider),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('599: AppBar + drawer, no rail (mobile)', (tester) async {
      await pumpShell(tester, 599);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.drawer, isA<NavigationDrawer>());
    });

    testWidgets('600: flat sidebar, no AppBar (tablet)', (tester) async {
      await pumpShell(tester, 600);
      expect(find.byType(AppBar), findsNothing);
      // Custom flat sidebar (not NavigationRail): brand wordmark + labels.
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('ARIA'), findsOneWidget);
    });

    testWidgets('1240: flat sidebar, no AppBar (desktop)', (tester) async {
      await pumpShell(tester, 1240);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('ARIA'), findsOneWidget);
    });
  });

  group('grid screen columns per band', () {
    // Pumping the real screen also asserts the tiles fit their cells:
    // RenderFlex overflow throws in widget tests.
    Future<void> pumpGrid(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = await makeContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AriaTheme.light(),
            home: const PlaylistsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final (width, cols) in [(599.0, 2), (600.0, 4), (1240.0, 6)]) {
      testWidgets('$width: $cols columns', (tester) async {
        await pumpGrid(tester, width);
        final grid = tester.widget<GridView>(find.byType(GridView));
        final delegate =
            grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, cols);
      });
    }
  });
}
