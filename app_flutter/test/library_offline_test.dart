import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aria/core/connection.dart';
import 'package:aria/core/library_providers.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Offline cold start: a hung/slow server must fall back to the disk cache
// after ~3s instead of waiting out the full API timeout, while the original
// fetch keeps running to refresh the cache when the server answers late.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aria_lib_offline_test');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  ProviderContainer containerWith(AriaClient client) {
    final c = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        appSupportDirProvider.overrideWithValue(dir),
        apiClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  final payload = jsonEncode([
    {'id': 't1', 'albumId': 'al', 'title': 'One'},
    {'id': 't2', 'albumId': 'al', 'title': 'Two'},
  ]);

  File cacheFile() => File('${dir.path}/cache/tracks.json');

  void seedCache(String body) {
    cacheFile().parent.createSync(recursive: true);
    cacheFile().writeAsStringSync(body);
  }

  test('hung server falls back to the cache in ~3s, not the API timeout',
      () async {
    seedCache(payload);
    final hung = AriaClient(
      baseUrl: 'http://s',
      // Never completes — simulates an unreachable server that has not yet
      // errored (no RST, packets black-holed).
      httpClient: MockClient((_) => Completer<http.Response>().future),
    );
    final sw = Stopwatch()..start();
    final tracks =
        await containerWith(hung).read(libraryTracksProvider.future);
    sw.stop();
    expect([for (final t in tracks) t.id], ['t1', 't2']);
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)),
        reason: 'must not wait out the full API timeout');
  });

  test('late server response still refreshes the disk cache', () async {
    seedCache(payload);
    final fresh = jsonEncode([
      {'id': 't3', 'albumId': 'al', 'title': 'Three'},
    ]);
    final slow = AriaClient(
      baseUrl: 'http://s',
      httpClient: MockClient((_) async {
        await Future<void>.delayed(const Duration(seconds: 4));
        return http.Response(fresh, 200);
      }),
    );
    final tracks =
        await containerWith(slow).read(libraryTracksProvider.future);
    // Served from cache first…
    expect([for (final t in tracks) t.id], ['t1', 't2']);
    // …then the background fetch overwrites the cache when it lands.
    for (var i = 0;
        i < 400 && cacheFile().readAsStringSync() != fresh;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(cacheFile().readAsStringSync(), fresh);
  });

  test('hung server without a cache waits for the real fetch', () async {
    final completer = Completer<http.Response>();
    final slow = AriaClient(
      baseUrl: 'http://s',
      httpClient: MockClient((_) => completer.future),
    );
    final future =
        containerWith(slow).read(libraryTracksProvider.future);
    // Let the 3s cache-fallback window pass, then answer.
    Timer(const Duration(seconds: 4),
        () => completer.complete(http.Response(payload, 200)));
    final tracks = await future;
    expect([for (final t in tracks) t.id], ['t1', 't2']);
  });
}
