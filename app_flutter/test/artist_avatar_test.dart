import 'package:aria/core/connection.dart';
import 'package:aria/core/formats.dart';
import 'package:aria/widgets/artist_avatar.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('initials (legacy parity)', () {
    test('two words -> two letters', () {
      expect(initials('Miles Davis'), 'MD');
    });
    test('one word -> one letter', () {
      expect(initials('Radiohead'), 'R');
    });
    test('more than two words truncates', () {
      expect(initials('Tom Waits Band'), 'TW');
    });
    test('empty and null -> ?', () {
      expect(initials(''), '?');
      expect(initials(null), '?');
      expect(initials('   '), '?');
    });
  });

  testWidgets('ArtistAvatar falls back to initials when the portrait fails',
      (tester) async {
    // The avatar always attempts the LAN proxy now, so it needs a client; the
    // proxy URL 404s in the test HTTP stub, exercising the initials fallback.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(AriaClient(baseUrl: 'http://s')),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ArtistAvatar(name: 'Nina Simone')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('NS'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
