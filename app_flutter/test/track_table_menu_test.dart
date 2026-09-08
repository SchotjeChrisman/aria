import 'package:aria/core/connection.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria/core/theme.dart';
import 'package:aria/features/library/tracks_section.dart';
import 'package:aria/widgets/context_menu.dart';
import 'package:aria/widgets/track_actions.dart';
import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every row of the track table carries a "…" button, so a mouse reaches the
/// same verbs a right-click reaches. The playlist pages add their own Remove
/// to it — that entry is the only way off a manual playlist now that the row
/// has no inline ✕.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const tracks = [
    Track(id: 't1', albumId: 'al', title: 'One', artist: 'A', album: 'Rec'),
    Track(id: 't2', albumId: 'al', title: 'Two', artist: 'B', album: 'Rec'),
  ];

  Future<Widget> app(Widget child) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // ponytail: unavailable player — every command no-ops, which is all these
    // widget assertions need.
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
      ],
      child: MaterialApp(
        theme: AriaTheme.light(),
        home: Scaffold(body: child),
      ),
    );
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(await app(child));
    await tester.pumpAndSettle();
  }

  testWidgets('every row carries a menu button, the header does not', (
    tester,
  ) async {
    await pump(tester, const TrackTable(tracks: tracks));
    expect(find.byType(TrackMenuButton), findsNWidgets(tracks.length));
  });

  testWidgets('the menu opens the standard track verbs', (tester) async {
    await pump(tester, const TrackTable(tracks: tracks));

    await tester.tap(find.byType(TrackMenuButton).first);
    await tester.pumpAndSettle();

    expect(find.text('Add to queue'), findsOneWidget);
    expect(find.text('Go to album'), findsOneWidget);
  });

  testWidgets('a playlist adds Remove, and it fires for the right track', (
    tester,
  ) async {
    final removed = <String>[];
    await pump(
      tester,
      TrackTable(
        tracks: tracks,
        menuExtra: (t) => [
          AriaMenuItem('Remove from playlist', () => removed.add(t.id)),
        ],
      ),
    );

    // second row's button, to catch a menu wired to the wrong track
    await tester.tap(find.byType(TrackMenuButton).last);
    await tester.pumpAndSettle();
    expect(find.text('Remove from playlist'), findsOneWidget);

    await tester.tap(find.text('Remove from playlist'));
    await tester.pumpAndSettle();
    expect(removed, ['t2']);
  });

  testWidgets('rows stay within the table itemExtent', (tester) async {
    await pump(tester, const TrackTable(tracks: tracks));
    // The dense button must fit 44px, or every row overflows.
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(TrackTableRow).first).height, 44);
  });
}
