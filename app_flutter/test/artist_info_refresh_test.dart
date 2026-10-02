import 'dart:convert';

import 'package:aria/core/connection.dart';
import 'package:aria/core/library_providers.dart';
import 'package:aria/features/artist/providers.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// An open artist or composer page refetches when the people map reloads — an
// edit on another device, a new artist.jpg — so its photo follows the avatars.
void main() {
  test('artist and composer info refetch when the people map reloads',
      () async {
    var photo = 'https://cdn/old.jpg';
    var artistCalls = 0;
    final c = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(AriaClient(
        baseUrl: 'http://s',
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/artist/Bach') artistCalls++;
          return http.Response(
              jsonEncode(switch (req.url.path) {
                '/api/people' => {'Bach': photo},
                '/api/artist/Bach' => {'image': photo},
                _ => {'portrait': photo},
              }),
              200);
        }),
      )),
    ]);
    addTearDown(c.dispose);
    await c.read(peopleProvider.future); // loaded, as when a page opens
    c.listen(artistInfoProvider('Bach'), (_, _) {});
    c.listen(composerInfoProvider('Bach'), (_, _) {});
    expect((await c.read(artistInfoProvider('Bach').future))!.image, photo);

    photo = 'https://cdn/new.jpg';
    c.invalidate(peopleProvider);
    await c.read(peopleProvider.future);
    await Future<void>.delayed(Duration.zero);
    expect((await c.read(artistInfoProvider('Bach').future))!.image, photo);
    expect((await c.read(composerInfoProvider('Bach').future))!.portrait, photo);
    expect(artistCalls, 2, reason: 'one fetch, then one per people reload');
  });
}
