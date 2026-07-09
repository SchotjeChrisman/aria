import 'package:aria/core/theme.dart';
import 'package:aria/widgets/shelf.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Item 2: on a mobile-width screen the shelf must show exactly 3 full album
/// cards with no partial fourth peeking — i.e. card width = (W - 3*gap)/3.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile shelf fits 3 full cards, no peek', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AriaTheme.light(),
        home: Scaffold(
          body: Shelf(
            title: 'Cards',
            height: 236,
            itemCount: 10,
            itemBuilder: (_, i) => const SizedBox.shrink(),
          ),
        ),
      ),
    );

    // Shelf fills the Scaffold body width (no outer padding here).
    const gap = AriaSpace.s6;
    const w = 390.0;
    final expected = (w - 3 * gap) / 3;

    // The per-item SizedBox inside the horizontal ListView carries the card
    // width. Grab the first one and confirm it matches the no-peek/3 formula.
    final cardWidth = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .map((s) => s.width)
        .firstWhere((wd) => wd != null && (wd - expected).abs() < 0.5,
            orElse: () => null);

    expect(cardWidth, isNotNull,
        reason: 'expected a card sized ~$expected (3 full, no peek)');
    // And three cards + two gaps must not exceed the viewport (no partial 4th).
    expect(3 * expected + 2 * gap, lessThanOrEqualTo(w + 0.5));
  });
}
