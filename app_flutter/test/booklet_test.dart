import 'package:aria/core/connection.dart';
import 'package:aria/features/album/providers.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Fake at the client level — no HTTP; the pdfrx viewer itself is not
/// widget-testable (native pdfium).
class _FakeClient extends AriaClient {
  _FakeClient(this._booklets) : super(baseUrl: 'http://s');

  final Future<List<String>> Function(String) _booklets;

  @override
  Future<List<String>> booklets(String albumId) => _booklets(albumId);
}

void main() {
  ProviderContainer withClient(AriaClient c) => ProviderContainer(
    overrides: [apiClientProvider.overrideWithValue(c)],
  );

  test('bookletsProvider surfaces the server list (non-empty shows the button)',
      () async {
    final container = withClient(
      _FakeClient((id) async => id == 'yes' ? ['booklet.pdf', 'scan.pdf'] : []),
    );
    addTearDown(container.dispose);
    expect(await container.read(bookletsProvider('yes').future),
        ['booklet.pdf', 'scan.pdf']);
    expect(await container.read(bookletsProvider('no').future), isEmpty);
  });

  test('bookletsProvider maps errors to [] (button stays hidden)', () async {
    final container = withClient(
      _FakeClient((_) => throw AriaApiException(500, 'boom')),
    );
    addTearDown(container.dispose);
    expect(await container.read(bookletsProvider('x').future), isEmpty);
  });
}
