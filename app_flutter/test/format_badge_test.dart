import 'package:aria/core/formats.dart';
import 'package:aria/core/theme.dart';
import 'package:aria/widgets/format_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatBadgeText (legacy fmtBadge parity)', () {
    test('hi-res flac', () {
      expect(
        formatBadgeText(format: 'flac', bitsPerSample: 24, sampleRate: 96000),
        'FLAC 24/96',
      );
    });

    test('cd-quality keeps the 44.1 fraction', () {
      expect(
        formatBadgeText(format: 'FLAC', bitsPerSample: 16, sampleRate: 44100),
        'FLAC 16/44.1',
      );
    });

    test('lossy without bit depth is just the container', () {
      expect(formatBadgeText(format: 'MPEG', sampleRate: 44100), 'MPEG');
      expect(formatBadgeText(), '');
    });
  });

  group('isHiRes', () {
    test('flags >16 bit or >48 kHz', () {
      expect(isHiRes(bitsPerSample: 24, sampleRate: 44100), isTrue);
      expect(isHiRes(bitsPerSample: 16, sampleRate: 96000), isTrue);
      expect(isHiRes(bitsPerSample: 16, sampleRate: 44100), isFalse);
      expect(isHiRes(), isFalse);
    });
  });

  group('formatDuration (legacy fmtTime parity)', () {
    test('m:ss with zero padding', () {
      expect(formatDuration(187), '3:07');
      expect(formatDuration(0), '0:00');
      expect(formatDuration(-5), '0:00');
      expect(formatDuration(null), '0:00');
      expect(formatDuration(3600), '60:00');
    });
  });

  testWidgets('FormatBadge renders text, accent when lossless', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AriaTheme.dark(),
        home: const Scaffold(
          body: FormatBadge(
            format: 'flac',
            bitsPerSample: 24,
            sampleRate: 192000,
            lossless: true,
          ),
        ),
      ),
    );
    final text = tester.widget<Text>(find.text('FLAC 24/192'));
    expect(text.style?.color, AriaColors.dark.lossless);
  });

  testWidgets('FormatBadge renders nothing without a format', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: FormatBadge()));
    expect(find.byType(Text), findsNothing);
  });
}
