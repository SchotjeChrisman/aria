import 'package:aria/core/connection.dart';
import 'package:aria/core/library_providers.dart';
import 'package:aria/core/theme.dart';
import 'package:aria/features/album/album_page.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The album header is the only place the full credit line is rendered: when
/// the server split a classical release credit it sends `albumArtists` (lead
/// performer, ensembles, then the rest) and every name gets its own link.
/// Ordinary albums — and any server predating the field — send nothing and
/// keep the single album artist.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Release ec17a59b, the worked example: performer, ensemble, conductor.
  const credited = [
    'Esther Yoo',
    'Royal Philharmonic Orchestra',
    'Vasily Petrenko',
  ];

  Track track({List<String> albumArtists = const []}) => Track(
    id: 't1',
    albumId: 'a1',
    title: 'Violin Concerto: I. Allegro',
    album: 'Barber, Bruch: Violin Concertos',
    albumArtist: 'Esther Yoo',
    albumArtists: albumArtists,
  );

  Future<void> pump(WidgetTester tester, Track t) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWithValue(AriaClient(baseUrl: 'http://s')),
          libraryTracksProvider.overrideWith((ref) async => [t]),
        ],
        child: MaterialApp(
          theme: AriaTheme.light(),
          home: const AlbumPage(albumId: 'a1'),
        ),
      ),
    );
    // Not pumpAndSettle: the header's network art keeps frames scheduled.
    await tester.pump();
  }

  testWidgets('the credited list renders in order, one link per name', (
    tester,
  ) async {
    await pump(tester, track(albumArtists: credited));

    for (final name in credited) {
      expect(find.text(name), findsOneWidget);
    }
    // Server order is the whole point of the Qobuz rule, so assert sequence,
    // not just presence. Tree order, not x/y: the credit line is a Wrap and
    // wraps to a second row on a narrow viewport.
    final line = find.byType(Wrap).first; // the credit line, above the buttons
    final names = tester
        .widgetList<Text>(find.descendant(of: line, matching: find.byType(Text)))
        .map((t) => t.data)
        .where(credited.contains);
    expect(names, credited);
  });

  testWidgets('without the field the single album artist stands', (
    tester,
  ) async {
    await pump(tester, track());
    expect(find.text('Esther Yoo'), findsOneWidget);
    expect(find.text('Royal Philharmonic Orchestra'), findsNothing);
  });
}
