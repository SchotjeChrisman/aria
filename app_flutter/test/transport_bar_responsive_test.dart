import 'package:aria/core/connection.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria/core/theme.dart';
import 'package:aria/features/now_playing/transport_bar.dart';
import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The bar must lay out without RenderFlex overflow at any window width —
/// overflow throws in widget tests, so pumping at each width is the assert.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const track = Track(
    id: 't1',
    albumId: 'al',
    title: 'A Fairly Long Track Title That Should Ellipsize',
    artist: 'An Artist With A Long Name',
    album: 'Some Album',
    duration: 300,
    format: 'FLAC',
    sampleRate: 192000,
    bitsPerSample: 24,
    lossless: true,
  );

  Future<Widget> app({Track? current}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // ponytail: unavailable player (rawFactory throws) — every command
    // no-ops, which is all a pure layout test needs.
    final player = AriaPlayer(rawFactory: () => throw StateError('test'));
    return ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        ariaPlayerProvider.overrideWithValue(player),
        apiClientProvider.overrideWithValue(AriaClient(baseUrl: 'http://s')),
        currentTrackProvider.overrideWithValue(current),
      ],
      child: MaterialApp(
        theme: AriaTheme.dark(),
        home: const Scaffold(bottomNavigationBar: TransportBar()),
      ),
    );
  }

  // Every layout-mode boundary, one step either side.
  const widths = [
    320.0,
    480.0,
    639.0,
    640.0,
    819.0,
    820.0,
    899.0,
    900.0,
    1000.0,
    1400.0,
  ];

  for (final w in widths) {
    testWidgets('no overflow at ${w.toInt()}px with a track', (tester) async {
      tester.view.physicalSize = Size(w, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(await app(current: track));
      await tester.pump();
      expect(find.byType(TransportBar), findsOneWidget);
    });

    testWidgets('no overflow at ${w.toInt()}px idle', (tester) async {
      tester.view.physicalSize = Size(w, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(await app());
      await tester.pump();
      expect(find.text('Nothing playing'), findsOneWidget);
    });
  }
}
