import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aria/core/connection.dart';
import 'package:aria/core/data_usage.dart';
import 'package:aria/core/downloads.dart';
import 'package:aria/core/library_providers.dart';
import 'package:aria/core/pending_plays.dart';
import 'package:aria/core/quality.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track fmtTrack(String id, {String? format = 'FLAC', String albumId = 'al'}) =>
    Track(id: id, albumId: albumId, title: id, format: format);

/// Serves 4-byte payloads for streams and a tiny PNG-ish blob for art.
AriaClient fakeServer({Set<String> failIds = const {}}) => AriaClient(
  baseUrl: 'http://s',
  httpClient: MockClient((req) async {
    final segs = req.url.pathSegments; // api / stream|art / id
    if (segs.length == 3 && segs[1] == 'stream') {
      if (failIds.contains(segs[2])) return http.Response('boom', 500);
      return http.Response.bytes(
        [1, 2, 3, 4],
        200,
        headers: {'content-type': 'audio/flac', 'etag': '"e-${segs[2]}"'},
      );
    }
    if (segs.length == 3 && segs[1] == 'art') {
      return http.Response.bytes([9, 9], 200);
    }
    return http.Response('Not Found', 404);
  }),
);

Future<void> eventually(bool Function() cond) async {
  for (var i = 0; i < 200 && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(cond(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('extensionFor', () {
    test('track format wins, lowercased', () {
      expect(extensionFor('FLAC', null), '.flac');
      expect(extensionFor('mp3', 'audio/flac'), '.mp3');
    });

    test('falls back to Content-Type, then .bin', () {
      expect(extensionFor(null, 'audio/mpeg'), '.mp3');
      // Transcoder serves Opus-in-Ogg; a null format (transcoded tier) maps
      // audio/ogg to .opus.
      expect(extensionFor(null, 'audio/ogg; charset=binary'), '.opus');
      expect(extensionFor('not/safe', 'audio/flac'), '.flac');
      expect(extensionFor(null, 'application/octet-stream'), '.bin');
      expect(extensionFor(null, null), '.bin');
    });
  });

  group('DownloadsNotifier', () {
    late Directory dir;

    Future<ProviderContainer> harness({
      AriaClient? client,
      Map<String, Object> prefs = const {},
      Stream<NetKind>? net,
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      final sharedPrefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(sharedPrefs),
          appSupportDirProvider.overrideWithValue(dir),
          apiClientProvider.overrideWithValue(client ?? fakeServer()),
          networkKindProvider.overrideWith(
            (ref) => net ?? Stream.value(NetKind.wifi),
          ),
        ],
      );
      addTearDown(c.dispose);
      c.listen(networkKindProvider, (_, _) {});
      await c.read(networkKindProvider.future);
      return c;
    }

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('aria_dl_test');
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('downloads to <id>.<ext>, indexes bytes+etag, no .part left',
        () async {
      final c = await harness();
      await c
          .read(downloadsProvider.notifier)
          .downloadTracks([fmtTrack('t1')]);

      final e = c.read(downloadsProvider).index['t1']!;
      expect(e.path, '${dir.path}/downloads/t1.flac');
      expect(e.bytes, 4);
      expect(e.etag, '"e-t1"');
      expect(File(e.path).readAsBytesSync(), [1, 2, 3, 4]);
      expect(File('${e.path}.part').existsSync(), isFalse);
      // Album art fetched once per album.
      expect(File('${dir.path}/downloads/art/al').existsSync(), isTrue);
      expect(c.read(downloadsProvider).active, isNull);
      expect(c.read(downloadsProvider).queue, isEmpty);
    });

    test('download tier: requests ?tier, stores .opus + tier on the entry',
        () async {
      final seen = <Uri>[];
      final ogg = AriaClient(
        baseUrl: 'http://s',
        httpClient: MockClient((req) async {
          seen.add(req.url);
          final segs = req.url.pathSegments;
          if (segs.length == 3 && segs[1] == 'art') {
            return http.Response.bytes([9, 9], 200);
          }
          // Transcoded response: Opus-in-Ogg, no source-format hint.
          return http.Response.bytes(
            [1, 2, 3, 4],
            200,
            headers: {'content-type': 'audio/ogg', 'etag': '"e-low"'},
          );
        }),
      );
      final c = await harness(
        client: ogg,
        prefs: {
          'aria.quality': jsonEncode({'tierDownload': 'low'}),
        },
      );
      await c.read(downloadsProvider.notifier).downloadTracks([fmtTrack('t1')]);

      final e = c.read(downloadsProvider).index['t1']!;
      expect(e.path, endsWith('/t1.opus'));
      expect(e.tier, QualityTier.low);
      expect(File(e.path).existsSync(), isTrue);
      // The stream request carried ?tier=low.
      final streamReq = seen.firstWhere((u) => u.pathSegments[1] == 'stream');
      expect(streamReq.queryParameters['tier'], 'low');

      // Tier round-trips through index.json (app restart).
      final c2 = await harness(client: ogg);
      expect(c2.read(downloadsProvider).index['t1']!.tier, QualityTier.low);
    });

    test('index round-trips across containers (app restart)', () async {
      final c = await harness();
      await c
          .read(downloadsProvider.notifier)
          .downloadTracks([fmtTrack('t1')]);

      final c2 = await harness();
      final index = c2.read(downloadsProvider).index;
      expect(index.keys, ['t1']);
      expect(index['t1']!.path, endsWith('/t1.flac'));
    });

    test('localSourceResolverProvider prefers the downloaded file', () async {
      final c = await harness();
      await c
          .read(downloadsProvider.notifier)
          .downloadTracks([fmtTrack('t1')]);
      final resolve = c.read(localSourceResolverProvider);
      expect(resolve('t1'), '${dir.path}/downloads/t1.flac');
      expect(resolve('t2'), isNull);
    });

    test('dedupes already-downloaded and already-queued tracks', () async {
      final c = await harness();
      final n = c.read(downloadsProvider.notifier);
      await n.downloadTracks([fmtTrack('t1')]);
      await n.downloadTracks([fmtTrack('t1'), fmtTrack('t2')]);
      expect(c.read(downloadsProvider).index.keys, ['t1', 't2']);
      expect(File('${dir.path}/downloads/t2.flac').existsSync(), isTrue);
    });

    test('a failed download leaves no index entry and continues', () async {
      final c = await harness(client: fakeServer(failIds: {'t1'}));
      final n = c.read(downloadsProvider.notifier);
      await n.downloadTracks([fmtTrack('t1'), fmtTrack('t2')]);
      // The first failure pauses the worker with t1 re-queued; re-tapping
      // burns the remaining attempts (t2 succeeds on the second pump).
      await n.downloadTracks([fmtTrack('t1')]);
      await n.downloadTracks([fmtTrack('t1')]);
      final index = c.read(downloadsProvider).index;
      expect(index.containsKey('t1'), isFalse);
      expect(index.containsKey('t2'), isTrue);
    });

    test('cellular gate pauses the queue; a network flip resumes it',
        () async {
      // Non-broadcast: the seeded kind buffers until the provider listens.
      final net = StreamController<NetKind>();
      addTearDown(net.close);
      net.add(NetKind.cellular); // downloadOnCellular defaults to false
      final c = await harness(net: net.stream);
      await eventually(
        () => c.read(networkKindProvider).value == NetKind.cellular,
      );

      final n = c.read(downloadsProvider.notifier);
      await n.downloadTracks([fmtTrack('t1')]);
      expect(c.read(downloadsProvider).queue, ['t1']); // parked, not dropped
      expect(c.read(downloadsProvider).index, isEmpty);

      net.add(NetKind.wifi); // listener re-pumps
      await eventually(
        () => c.read(downloadsProvider).index.containsKey('t1'),
      );
      expect(c.read(downloadsProvider).queue, isEmpty);
    });

    test('enabling cellular downloads resumes a paused queue', () async {
      final net = StreamController<NetKind>();
      addTearDown(net.close);
      net.add(NetKind.cellular);
      final c = await harness(net: net.stream);
      await eventually(
        () => c.read(networkKindProvider).value == NetKind.cellular,
      );

      final n = c.read(downloadsProvider.notifier);
      await n.downloadTracks([fmtTrack('t1')]);
      expect(c.read(downloadsProvider).queue, ['t1']); // parked

      await c
          .read(dataUsageProvider.notifier)
          .set(const DataUsage(downloadOnCellular: true));
      await eventually(
        () => c.read(downloadsProvider).index.containsKey('t1'),
      );
      expect(c.read(downloadsProvider).queue, isEmpty);
    });

    test('concurrent removes never tear index.json (.part + chained saves)',
        () async {
      final c = await harness();
      final n = c.read(downloadsProvider.notifier);
      await n.downloadTracks(
        [fmtTrack('t1'), fmtTrack('t2'), fmtTrack('t3')],
      );

      await Future.wait([n.remove('t1'), n.remove('t2')]);
      final f = File('${dir.path}/downloads/index.json');
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      expect(j.keys, ['t3']);
      expect(File('${f.path}.part').existsSync(), isFalse);
    });

    test('load prunes index entries whose file is missing', () async {
      final c = await harness();
      await c
          .read(downloadsProvider.notifier)
          .downloadTracks([fmtTrack('t1'), fmtTrack('t2')]);
      File('${dir.path}/downloads/t1.flac').deleteSync(); // external cleanup

      final c2 = await harness();
      expect(c2.read(downloadsProvider).index.keys, ['t2']);
    });

    test('a failed download retries, then drops after 3 attempts', () async {
      final c = await harness(client: fakeServer(failIds: {'t1'}));
      final n = c.read(downloadsProvider.notifier);

      await n.downloadTracks([fmtTrack('t1')]); // attempt 1 -> re-queued
      expect(c.read(downloadsProvider).queue, ['t1']);
      await n.downloadTracks([fmtTrack('t1')]); // attempt 2 -> re-queued
      expect(c.read(downloadsProvider).queue, ['t1']);
      await n.downloadTracks([fmtTrack('t1')]); // attempt 3 -> dropped
      expect(c.read(downloadsProvider).queue, isEmpty);
      expect(c.read(downloadsProvider).index, isEmpty);
    });

    test('remove deletes the file and the entry; removeAll wipes everything',
        () async {
      final c = await harness();
      final n = c.read(downloadsProvider.notifier);
      await n.downloadTracks([fmtTrack('t1'), fmtTrack('t2')]);

      await n.remove('t1');
      expect(c.read(downloadsProvider).index.keys, ['t2']);
      expect(File('${dir.path}/downloads/t1.flac').existsSync(), isFalse);
      expect(File('${dir.path}/downloads/t2.flac').existsSync(), isTrue);

      await n.removeAll();
      expect(c.read(downloadsProvider).index, isEmpty);
      expect(File('${dir.path}/downloads/t2.flac').existsSync(), isFalse);
      expect(Directory('${dir.path}/downloads/art').existsSync(), isFalse);
    });

    test('localArt resolves only after a download cached the cover',
        () async {
      final c = await harness();
      expect(c.read(localArtResolverProvider)('al'), isNull);
      await c
          .read(downloadsProvider.notifier)
          .downloadTracks([fmtTrack('t1')]);
      expect(
        c.read(localArtResolverProvider)('al'),
        '${dir.path}/downloads/art/al',
      );
    });

    test('without a support dir the notifier is inert', () async {
      SharedPreferences.setMockInitialValues({});
      final sharedPrefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(sharedPrefs)],
      );
      addTearDown(c.dispose);
      await c
          .read(downloadsProvider.notifier)
          .downloadTracks([fmtTrack('t1')]);
      expect(c.read(downloadsProvider).index, isEmpty);
      expect(c.read(localSourceResolverProvider)('t1'), isNull);
    });
  });

  group('offline library cache', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('aria_cache_test');
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    ProviderContainer containerWith(AriaClient client) {
      final c = ProviderContainer(
        // Riverpod 3 auto-retries failed providers with backoff; the error
        // assertions below need the first failure surfaced.
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

    test('successful fetch mirrors the payload to disk', () async {
      final ok = AriaClient(
        baseUrl: 'http://s',
        httpClient: MockClient((_) async => http.Response(payload, 200)),
      );
      final c = containerWith(ok);
      final tracks = await c.read(libraryTracksProvider.future);
      expect(tracks, hasLength(2));
      final cache = File('${dir.path}/cache/tracks.json');
      await eventually(cache.existsSync); // write is fire-and-forget
      expect(cache.readAsStringSync(), payload);
    });

    test('fetch failure falls back to the cached payload', () async {
      final cache = File('${dir.path}/cache/tracks.json');
      cache.parent.createSync(recursive: true);
      cache.writeAsStringSync(payload);
      final down = AriaClient(
        baseUrl: 'http://s',
        httpClient: MockClient(
          (_) async => throw const SocketException('offline'),
        ),
      );
      final tracks =
          await containerWith(down).read(libraryTracksProvider.future);
      expect([for (final t in tracks) t.id], ['t1', 't2']);
    });

    test('fetch failure without a cache rethrows', () async {
      final down = AriaClient(
        baseUrl: 'http://s',
        httpClient: MockClient((_) async => http.Response('err', 500)),
      );
      await expectLater(
        containerWith(down).read(libraryTracksProvider.future),
        throwsA(isA<AriaApiException>()),
      );
    });
  });

  group('PendingPlays', () {
    Future<(PendingPlays, List<(String, String, String?)>)> pending({
      Map<String, Object> seed = const {},
      Object? Function(String trackId)? fail,
    }) async {
      SharedPreferences.setMockInitialValues(seed);
      final prefs = await SharedPreferences.getInstance();
      final sent = <(String, String, String?)>[];
      final p = PendingPlays(
        prefs: prefs,
        send: (trackId, profileId, at) async {
          final err = fail?.call(trackId);
          if (err != null) throw err;
          sent.add((trackId, profileId, at));
        },
      );
      return (p, sent);
    }

    test('add persists; flush replays oldest-first and clears', () async {
      final (p, sent) = await pending();
      p.add(trackId: 't1', profileId: 'p1', at: '2026-07-08T10:00:00.000Z');
      p.add(trackId: 't2', profileId: 'p1', at: '2026-07-08T11:00:00.000Z');

      await p.flush();
      expect(sent, [
        ('t1', 'p1', '2026-07-08T10:00:00.000Z'),
        ('t2', 'p1', '2026-07-08T11:00:00.000Z'),
      ]);
      expect(p.entries, isEmpty);
    });

    test('unreachable server keeps the queue for the next tick', () async {
      final (p, sent) = await pending(
        fail: (_) => AriaApiException(0, 'no response', path: '/api/plays'),
      );
      p.add(trackId: 't1', profileId: 'p1', at: 'x');
      await p.flush();
      expect(sent, isEmpty);
      expect(p.entries, hasLength(1));
    });

    test('a rejected play is dropped so the queue never wedges', () async {
      final (p, sent) = await pending(
        fail: (id) => id == 't1'
            ? AriaApiException(400, 'unknown profile', path: '/api/plays')
            : null,
      );
      p.add(trackId: 't1', profileId: 'gone', at: 'x');
      p.add(trackId: 't2', profileId: 'p1', at: 'y');
      await p.flush();
      expect(sent, [('t2', 'p1', 'y')]);
      expect(p.entries, isEmpty);
    });

    test('caps at 5000, dropping the oldest', () async {
      final (p, _) = await pending(
        seed: {
          'aria.pendingPlays': jsonEncode([
            for (var i = 0; i < PendingPlays.cap; i++)
              {'trackId': 't$i', 'profileId': 'p1', 'at': 'x'},
          ]),
        },
      );
      p.add(trackId: 'new', profileId: 'p1', at: 'x');
      expect(p.entries, hasLength(PendingPlays.cap));
      expect(p.entries.first['trackId'], 't1'); // t0 dropped
      expect(p.entries.last['trackId'], 'new');
    });

    test('corrupt prefs entry resets to empty', () async {
      final (p, _) = await pending(seed: {'aria.pendingPlays': 'not json'});
      expect(p.entries, isEmpty);
    });
  });

  test('isoTimestamp emits the exact server layout', () {
    expect(
      isoTimestamp(DateTime.utc(2026, 7, 8, 9, 5, 3, 7)),
      '2026-07-08T09:05:03.007Z',
    );
  });
}
