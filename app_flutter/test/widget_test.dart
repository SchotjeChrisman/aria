import 'package:aria/core/theme.dart';
import 'package:aria/widgets/empty_state.dart';
import 'package:aria/widgets/track_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AriaTheme.light(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('TrackRow shows number, title, badge and duration', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const TrackRow(
          number: 3,
          title: 'So What',
          subtitle: 'Miles Davis',
          duration: 562,
          format: 'FLAC',
          bitsPerSample: 24,
          sampleRate: 96000,
          lossless: true,
        ),
      ),
    );
    expect(find.text('3'), findsOneWidget);
    expect(find.text('So What'), findsOneWidget);
    expect(find.text('Miles Davis'), findsOneWidget);
    expect(find.text('FLAC 24/96'), findsOneWidget);
    expect(find.text('9:22'), findsOneWidget);
  });

  testWidgets('TrackRow current: ▶ replaces the number, accent title', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const TrackRow(number: 3, title: 'So What', isCurrent: true)),
    );
    expect(find.text('▶'), findsOneWidget);
    expect(find.text('3'), findsNothing);
    final title = tester.widget<Text>(find.text('So What'));
    expect(title.style?.color, AriaColors.light.accent);
  });

  testWidgets('EmptyState renders message and icon', (tester) async {
    await tester.pumpWidget(
      _app(
        const EmptyState(message: 'Queue is empty.', icon: Icons.queue_music),
      ),
    );
    expect(find.text('Queue is empty.'), findsOneWidget);
    expect(find.byIcon(Icons.queue_music), findsOneWidget);
  });
}
