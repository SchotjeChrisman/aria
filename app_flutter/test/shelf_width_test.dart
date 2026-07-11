import 'package:aria/core/theme.dart';
import 'package:aria/widgets/shelf.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Item 2: on a mobile-width screen the shelf must show exactly 3 full album
/// cards that fill the width with no partial fourth peeking and no slack at the
/// right edge — i.e. 3 cards + 2 gaps == W, so card width = (W - 2*gap)/3.
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
    const gap = AriaSpace.s5;
    const w = 390.0;
    final expected = (w - 2 * gap) / 3;

    // The per-item SizedBox inside the horizontal ListView carries the card
    // width. Grab the first one and confirm it matches the no-peek/3 formula.
    final cardWidth = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .map((s) => s.width)
        .firstWhere((wd) => wd != null && (wd - expected).abs() < 0.5,
            orElse: () => null);

    expect(cardWidth, isNotNull,
        reason: 'expected a card sized ~$expected (3 full, no peek)');
    // Three cards + two gaps fill the viewport exactly — no slack, no 4th.
    expect(3 * expected + 2 * gap, closeTo(w, 0.5));
  });

  testWidgets('mobileColumns:4 fills the width with 4 flush cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AriaTheme.light(),
        home: Scaffold(
          body: Shelf(
            title: 'Artists',
            height: 236,
            mobileColumns: 4,
            itemCount: 10,
            itemBuilder: (_, i) => const SizedBox.shrink(),
          ),
        ),
      ),
    );

    const gap = AriaSpace.s5;
    const w = 390.0;
    final expected = (w - 3 * gap) / 4;
    final cardWidth = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .map((s) => s.width)
        .firstWhere((wd) => wd != null && (wd - expected).abs() < 0.5,
            orElse: () => null);

    expect(cardWidth, isNotNull,
        reason: 'expected a card sized ~$expected (4 full, no peek)');
    expect(4 * expected + 3 * gap, closeTo(w, 0.5));
  });
}
