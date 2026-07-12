import 'package:aria/core/connection.dart';
import 'package:aria/core/phosphor_icons.dart';
import 'package:aria/core/library_providers.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria/core/router.dart';
import 'package:aria/core/theme.dart';
import 'package:aria/features/album/album_page.dart';
import 'package:aria/features/artist/artist_page.dart';
import 'package:aria/features/now_playing/lyrics_view.dart';
import 'package:aria/features/now_playing/now_playing_screen.dart';
import 'package:aria/features/now_playing/queue_screen.dart';
import 'package:aria/widgets/art_image.dart';
import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression: /now-playing (and /queue) live ABOVE the shell, while
/// /album/:id and /artist/:name live INSIDE library shell branches.
/// context.push() across that boundary corrupts the root navigator's page
/// stack (duplicate shell page keys) and the target page never appears —
/// these navigations must use context.go().
class _NoopMpv implements MpvRaw {
  @override
  int create() => 1;
  @override
  int initialize(int handle) => 0;
  @override
  int setOptionString(int handle, String name, String value) => 0;
  @override
  int setPropertyString(int handle, String name, String value) => 0;
  @override
  int setPropertyDouble(int handle, String name, double value) => 0;
  @override
  int command(int handle, List<String> args) => 0;
  @override
  int observeProperty(int handle, int replyUserdata, String name, int format) =>
      0;
  @override
  int requestLogMessages(int handle, String minLevel) => 0;
  @override
  MpvEventData? waitEvent(int handle, double timeoutSeconds) => null;
  @override
  void terminateDestroy(int handle) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AriaPlayer player;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'aria.serverUrl': 'http://s',
    });
    final prefs = await SharedPreferences.getInstance();
    player = AriaPlayer(
      rawFactory: _NoopMpv.new,
      pollInterval: const Duration(days: 1),
    );
    await player.initialize();
    container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        ariaPlayerProvider.overrideWithValue(player),
        // Inert: the real one keeps a 5s SSE-reconnect timer alive, which
        // trips the pending-timer invariant at test teardown.
        enrichRefreshProvider.overrideWith((ref) {}),
      ],
    );
  });

  // Disposal must happen inside the test body: the pending-timer invariant
  // runs before tearDown, and both the player poll timer and provider
  // timers must be gone by then.
  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await player.dispose();
  }

  Future<void> pumpApp(WidgetTester tester) async {
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

  const track = Track(
    id: 't1',
    albumId: 'a1b2c3',
    title: 'So What',
    artist: 'Miles Davis',
    album: 'Kind of Blue',
  );

  testWidgets('album art tap on now-playing opens the album page', (
    tester,
  ) async {
    await pumpApp(tester);
    container.read(queueProvider.notifier).playQueue(const [track], 0);
    container.read(routerProvider).push('/now-playing');
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingScreen), findsOneWidget);

    await tester.tap(find.byType(ArtImage).first, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(AlbumPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await cleanup(tester);
  });

  testWidgets('artist line tap on now-playing opens the artist page', (
    tester,
  ) async {
    await pumpApp(tester);
    container.read(queueProvider.notifier).playQueue(const [track], 0);
    container.read(routerProvider).push('/now-playing');
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Miles Davis').first,
        warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(ArtistPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await cleanup(tester);
  });

  testWidgets('lyrics button (bottom controls) opens the lyrics screen', (
    tester,
  ) async {
    await pumpApp(tester);
    container.read(queueProvider.notifier).playQueue(const [track], 0);
    container.read(routerProvider).push('/now-playing');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(PhosphorIconsRegular.microphoneStage));
    await tester.pumpAndSettle();

    expect(find.byType(LyricsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await cleanup(tester);
  });

  testWidgets('queue button (bottom controls) opens the queue screen', (
    tester,
  ) async {
    await pumpApp(tester);
    container.read(queueProvider.notifier).playQueue(const [track], 0);
    container.read(routerProvider).push('/now-playing');
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(PhosphorIconsRegular.queue));
    await tester.pumpAndSettle();

    expect(find.byType(QueueScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await cleanup(tester);
  });

  testWidgets('now-playing does not overflow on a short window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 560);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await pumpApp(tester);
    container.read(queueProvider.notifier).playQueue(const [track], 0);
    container.read(routerProvider).push('/now-playing');
    await tester.pumpAndSettle();

    expect(find.byType(NowPlayingScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await cleanup(tester);
  });
}
