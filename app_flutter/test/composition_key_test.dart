import 'package:aria/features/home/home_screen.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_test/flutter_test.dart';

Track _t({String? title, String? composer, String? work}) =>
    Track(id: '1', albumId: 'a', title: title, composer: composer, work: work);

void main() {
  test('work tag wins and dedups case-insensitively', () {
    expect(
      compositionKey(_t(work: 'Symphony No. 5', title: 'I. Allegro')),
      compositionKey(_t(work: 'symphony no. 5', title: 'II. Andante')),
    );
  });

  test('no work: synthesize from composer + title, distinct per composer', () {
    final a = compositionKey(_t(title: 'Home', composer: 'Alice'));
    final b = compositionKey(_t(title: 'Home', composer: 'Bob'));
    expect(a, isNotNull);
    expect(a, isNot(b));
    // Same song, same composer collapses.
    expect(a, compositionKey(_t(title: ' home ', composer: 'alice')));
  });

  test('filler and untitled tracks are not compositions', () {
    expect(compositionKey(_t(title: 'Intro')), isNull);
    expect(compositionKey(_t(title: '  Outro ')), isNull);
    expect(compositionKey(_t(title: '')), isNull);
    expect(compositionKey(_t(title: null)), isNull);
  });
}
