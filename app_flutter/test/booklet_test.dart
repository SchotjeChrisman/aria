import 'package:aria/core/connection.dart';
import 'package:aria/features/album/providers.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Fake at the client level — no HTTP; the pdfrx viewer itself is not
/// widget-testable (native pdfium).
class _FakeClient extends AriaClient {
  _FakeClient(this._hasBooklet) : super(baseUrl: 'http://s');

  final Future<bool> Function(String) _hasBooklet;

  @override
  Future<bool> hasBooklet(String albumId) => _hasBooklet(albumId);
}

void main() {
  ProviderContainer withClient(AriaClient c) => ProviderContainer(
    overrides: [apiClientProvider.overrideWithValue(c)],
  );

  test('hasBookletProvider surfaces the server answer', () async {
    final container = withClient(_FakeClient((id) async => id == 'yes'));
    addTearDown(container.dispose);
    expect(await container.read(hasBookletProvider('yes').future), isTrue);
    expect(await container.read(hasBookletProvider('no').future), isFalse);
  });

  test('hasBookletProvider maps errors to false (button stays hidden)', () async {
    final container = withClient(
      _FakeClient((_) => throw AriaApiException(500, 'boom')),
    );
    addTearDown(container.dispose);
    expect(await container.read(hasBookletProvider('x').future), isFalse);
  });
}
