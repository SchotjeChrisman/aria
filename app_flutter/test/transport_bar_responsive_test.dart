import 'package:aria/core/connection.dart';
import 'package:aria/core/phosphor_icons.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria/core/theme.dart';
import 'package:aria/features/now_playing/transport_bar.dart';
import 'package:aria/widgets/format_badge.dart';
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

  Future<Widget> app({
    Track? current,
    double? railWidth,
    bool radio = false,
  }) async {
    // Persisted station is the only override-free way to put the bar in radio
    // mode — the notifier rehydrates it in build().
    SharedPreferences.setMockInitialValues(radio
        ? {'aria.radio': '{"id":"r1","name":"A Station","url":"http://s/x"}'}
        : {});
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
        theme: AriaTheme.light(),
        // Align gives loose constraints so the SizedBox width is honoured;
        // bottomNavigationBar forces tight full width and cannot narrow.
        home: railWidth == null
            ? const Scaffold(bottomNavigationBar: TransportBar())
            : Scaffold(
                body: Align(
                  alignment: Alignment.bottomRight,
                  child: SizedBox(
                    width: railWidth,
                    child: const TransportBar(),
                  ),
                ),
              ),
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
    1240.0,
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
      // Shuffle/repeat are desktop-only — this fails if they leak into the
      // stacked branch, or vanish from the desktop one.
      expect(
        find.byIcon(PhosphorIconsRegular.shuffle),
        w >= 1240 ? findsOneWidget : findsNothing,
      );
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

  // The shell mounts the bar in the content column RIGHT of the sidebar
  // (core/router.dart), so the desktop bar is ~200px narrower than the
  // window — the full-width cases above never exercise the tightest real
  // desktop layout.
  for (final w in [1240.0, 1920.0]) {
    final content = w - (w * 0.16).clamp(150.0, 200.0) - 1;

    testWidgets('no overflow at ${w.toInt()}px beside the rail with a track',
        (tester) async {
      tester.view.physicalSize = Size(w, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(await app(current: track, railWidth: content));
      await tester.pump();
      expect(tester.takeException(), isNull);
      // Present, not merely clipped, inside the real (narrower) column.
      expect(find.byIcon(PhosphorIconsRegular.shuffle), findsOneWidget);
      expect(find.byIcon(PhosphorIconsFill.repeat), findsOneWidget);
      // Pairs with the 2x-text case below: without this the "badge is gone at
      // 2x" assert would also pass if the badge never rendered at all.
      expect(find.byType(FormatBadge), findsOneWidget);
    });

    // The 84px pill has no room for the third meta line once the OS text
    // scale grows — the line is gated off above ~1.4x rather than clipped.
    testWidgets('no overflow at ${w.toInt()}px beside the rail at 2x text',
        (tester) async {
      tester.view.physicalSize = Size(w, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(await app(current: track, railWidth: content));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(FormatBadge), findsNothing);
    });

    testWidgets('no overflow at ${w.toInt()}px beside the rail idle',
        (tester) async {
      tester.view.physicalSize = Size(w, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(await app(railWidth: content));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Nothing playing'), findsOneWidget);
    });

    testWidgets('no overflow at ${w.toInt()}px beside the rail on radio',
        (tester) async {
      tester.view.physicalSize = Size(w, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(await app(railWidth: content, radio: true));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('A Station'), findsOneWidget);
      // Live stream has no queue: shuffle/repeat render but disabled.
      expect(
        tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(PhosphorIconsRegular.shuffle),
            matching: find.byType(IconButton),
          ),
        ).onPressed,
        isNull,
      );
    });
  }
}
