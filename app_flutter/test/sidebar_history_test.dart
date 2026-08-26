import 'package:aria/core/connection.dart';
import 'package:aria/core/library_providers.dart';
import 'package:aria/core/log_sync.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria/core/router.dart';
import 'package:aria/core/theme.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sidebar items are absolute destinations (always the section root, never a
/// resumed detail page), and back undoes the jump — go_router keeps no
/// cross-branch history, so AdaptiveShell keeps its own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GoRouter router;

  /// Deepest matched leaf, not `currentConfiguration.uri` — that one ignores
  /// imperative pushes, so an open album detail still reads '/library/albums'.
  String location() =>
      router.routerDelegate.currentConfiguration.last.matchedLocation;

  Future<void> pump(WidgetTester tester, {double width = 1240}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'aria.serverUrl': 'http://s'});
    final prefs = await SharedPreferences.getInstance();
    // ponytail: unavailable player (rawFactory throws) — every command
    // no-ops, which is all a navigation test needs.
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        ariaPlayerProvider.overrideWithValue(
          AriaPlayer(rawFactory: () => throw StateError('test')),
        ),
        // Inert: the real ones keep timers alive past teardown.
        enrichRefreshProvider.overrideWith((ref) {}),
        logSyncProvider.overrideWith(
          (ref) => LogSync(prefs: prefs, file: () => null, upload: (_) async {}),
        ),
        libraryTracksProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AriaTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The Android back button / predictive-back gesture, verbatim: it enters
  /// the delegate the same way, so this exercises the real navigator walk
  /// (branch first, shell PopScope only once the branch is empty).
  Future<void> back(WidgetTester tester) async {
    await router.routerDelegate.popRoute();
    await tester.pumpAndSettle();
  }

  Future<void> tapSidebar(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(Sidebar),
      matching: find.text(label),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('back unwinds sidebar jumps, oldest last', (tester) async {
    await pump(tester);
    expect(location(), '/home');

    await tapSidebar(tester, 'Albums');
    expect(location(), '/library/albums');
    await tapSidebar(tester, 'Artists');
    expect(location(), '/library/artists');

    await back(tester);
    expect(location(), '/library/albums');
    await back(tester);
    expect(location(), '/home');
  });

  testWidgets('sidebar is absolute; back returns to the abandoned detail', (
    tester,
  ) async {
    await pump(tester);
    await tapSidebar(tester, 'Albums');
    // Stand in for opening an album: a detail route mounted in the albums
    // branch, pushed the way the grid pushes it.
    router.push('/album/a1');
    await tester.pumpAndSettle();
    expect(location(), '/album/a1');

    await tapSidebar(tester, 'Artists');
    // The jump that used to resume the detail page instead of the grid.
    await tapSidebar(tester, 'Albums');
    expect(location(), '/library/albums');

    await back(tester);
    expect(location(), '/library/artists');
    await back(tester);
    // Restored with its own stack intact, so the detail comes back...
    expect(location(), '/album/a1');
    await back(tester);
    // ...and its in-branch back still reaches the grid beneath it.
    expect(location(), '/library/albums');
  });

  testWidgets('narrow: back closes the drawer instead of navigating', (
    tester,
  ) async {
    // 599 = mobile band: AppBar + NavigationDrawer instead of the sidebar.
    await pump(tester, width: 599);
    Future<void> openDrawer() async {
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
    }

    await openDrawer();
    await tester.tap(find.descendant(
      of: find.byType(NavigationDrawer),
      matching: find.text('Search'),
    ));
    await tester.pumpAndSettle();
    expect(location(), '/search');

    // History is non-empty now, so the shell's PopScope wants this back
    // press — but the open drawer's LocalHistoryEntry has the prior claim.
    await openDrawer();
    expect(find.byType(NavigationDrawer), findsOneWidget);
    await back(tester);
    expect(find.byType(NavigationDrawer), findsNothing, reason: 'drawer shut');
    expect(location(), '/search', reason: 'back did not also navigate');

    // Drawer gone, so the next back is ours again.
    await back(tester);
    expect(location(), '/home');
  });

  testWidgets('re-tapping the current section spends no back press', (
    tester,
  ) async {
    await pump(tester);
    await tapSidebar(tester, 'Albums');
    await tapSidebar(tester, 'Albums');
    await tapSidebar(tester, 'Albums');
    await back(tester);
    expect(location(), '/home');
  });
}
