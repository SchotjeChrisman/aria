import 'package:aria/core/connection.dart';
import 'package:aria/core/library_providers.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria/core/theme.dart';
import 'package:aria/features/now_playing/transport_bar.dart';
import 'package:aria/widgets/track_actions.dart';
import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The desktop transport carries the track's own actions (♥ + "…" menu);
/// narrower layouts and radio have no room / nothing to act on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const track = Track(
    id: 't1',
    albumId: 'al',
    title: 'A Track',
    artist: 'An Artist',
    album: 'An Album',
    duration: 300,
  );

  Future<Widget> app({Track? current}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // ponytail: unavailable player (rawFactory throws) — every command
    // no-ops, which is all these widget assertions need.
    final player = AriaPlayer(rawFactory: () => throw StateError('test'));
    return ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        ariaPlayerProvider.overrideWithValue(player),
        // The heart writes the flag through to the server and reverts on
        // failure — a client that always succeeds keeps the assertion about
        // the toggle, not about connectivity.
        apiClientProvider.overrideWithValue(
          AriaClient(
            baseUrl: 'http://s',
            httpClient: MockClient((_) async => http.Response('{}', 200)),
          ),
        ),
        currentTrackProvider.overrideWithValue(current),
      ],
      child: MaterialApp(
        theme: AriaTheme.light(),
        home: const Scaffold(bottomNavigationBar: TransportBar()),
      ),
    );
  }

  Future<void> pumpAt(WidgetTester tester, double width, {Track? current}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(await app(current: current));
    await tester.pump();
  }

  testWidgets('desktop shows the heart and the track menu', (tester) async {
    await pumpAt(tester, 1400, current: track);
    expect(find.byType(FavouriteButton), findsOneWidget);
    expect(find.byType(TrackMenuButton), findsOneWidget);
  });

  testWidgets('idle desktop bar has neither', (tester) async {
    await pumpAt(tester, 1400);
    expect(find.byType(FavouriteButton), findsNothing);
    expect(find.byType(TrackMenuButton), findsNothing);
  });

  testWidgets('below the desktop band they are dropped', (tester) async {
    await pumpAt(tester, 640, current: track);
    expect(find.byType(FavouriteButton), findsNothing);
    expect(find.byType(TrackMenuButton), findsNothing);
  });

  testWidgets('the heart toggles the favourite flag', (tester) async {
    await pumpAt(tester, 1400, current: track);
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(TransportBar)),
    );
    expect(scope.read(favouriteIdsProvider).contains('t1'), isFalse);

    await tester.tap(find.byType(FavouriteButton));
    await tester.pump();
    expect(scope.read(favouriteIdsProvider).contains('t1'), isTrue);

    await tester.tap(find.byType(FavouriteButton));
    await tester.pump();
    expect(scope.read(favouriteIdsProvider).contains('t1'), isFalse);
  });

  testWidgets('the menu opens the standard track actions', (tester) async {
    await pumpAt(tester, 1400, current: track);
    await tester.tap(find.byType(TrackMenuButton));
    await tester.pumpAndSettle();
    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.text('Go to album'), findsOneWidget);
  });
}
