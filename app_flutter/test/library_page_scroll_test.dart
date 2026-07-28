import 'package:aria/core/connection.dart';
import 'package:aria/core/library_providers.dart';
import 'package:aria/core/theme.dart';
import 'package:aria/features/library/library_screen.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The library pages scroll as ONE page: the "Albums / N tracks" title and the
/// section's filter row travel with the grid. They used to sit in a Column
/// above an Expanded scroller, so only the grid moved.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Enough albums that the grid overflows any test viewport.
  final tracks = [
    for (var i = 0; i < 120; i++)
      Track(
        id: 't$i',
        albumId: 'al$i',
        title: 'Track $i',
        artist: 'Artist ${i % 7}',
        album: 'Album $i',
        genres: ['Genre $i'],
        duration: 200,
      ),
  ];

  Future<Widget> app(LibrarySection section) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWithValue(AriaClient(baseUrl: 'http://s')),
        // Everything the sections read derives from this one provider.
        libraryTracksProvider.overrideWith((ref) async => tracks),
      ],
      child: MaterialApp(
        theme: AriaTheme.light(),
        home: LibraryScreen(section: section),
      ),
    );
  }

  Future<void> pumpPage(WidgetTester tester, LibrarySection section) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(await app(section));
    // Not pumpAndSettle: the grid's network art keeps frames scheduled.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  for (final section in [
    LibrarySection.albums,
    LibrarySection.artists,
    LibrarySection.genres,
  ]) {
    testWidgets('${section.name}: the page title scrolls with the grid', (
      tester,
    ) async {
      await pumpPage(tester, section);

      final title = find.text(section.label);
      expect(title, findsOneWidget);
      final before = tester.getTopLeft(title).dy;

      // A short drag: enough to move the header, not enough to unmount it.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -60));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(
        tester.getTopLeft(title).dy,
        lessThan(before),
        reason: 'the title stayed put — the page is not one scroll view',
      );
    });
  }

  testWidgets('albums: the filter row scrolls away too', (tester) async {
    await pumpPage(tester, LibrarySection.albums);

    final genrePill = find.text('Genre');
    expect(genrePill, findsOneWidget);
    final before = tester.getTopLeft(genrePill).dy;

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -60));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(tester.getTopLeft(genrePill).dy, lessThan(before));
  });
}
