import 'package:aria/core/library_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('library SSE frames yield a comparable generation', () {
    expect(libraryGen({'gen': 7}), 7);
    expect(libraryGen({'gen': 0}), 0); // a fresh server, not "no generation"
    // Defensive: a junk or foreign frame must read as null, so the watcher
    // skips it rather than refetching the whole library on garbage.
    expect(libraryGen({'done': 3, 'total': 9}), null);
    expect(libraryGen('garbage'), null);
    expect(libraryGen(null), null);
  });
}
