import 'package:aria/core/formats.dart';
import 'package:aria/widgets/artist_avatar.dart';
import 'package:flutter/material.dart';
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

  testWidgets('ArtistAvatar shows initials without an image', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ArtistAvatar(name: 'Nina Simone')),
      ),
    );
    expect(find.text('NS'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
