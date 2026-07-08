import 'dart:convert';

import 'package:aria_api/aria_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('URL builders', () {
    final c = AriaClient(baseUrl: 'http://box:3000/');

    test('trailing slash normalized; stream/art/booklet URLs', () {
      expect(c.baseUrl, 'http://box:3000');
      expect(c.streamUrl('abc123'), 'http://box:3000/api/stream/abc123');
      expect(c.artUrl('deadbeef'), 'http://box:3000/api/art/deadbeef');
      expect(c.bookletUrl('deadbeef', 'liner notes.pdf'),
          'http://box:3000/api/albums/deadbeef/booklet/liner%20notes.pdf');
    });

    test('streamUrl appends ?tier only for high/low, omits for original', () {
      expect(c.streamUrl('t1'), 'http://box:3000/api/stream/t1');
      expect(c.streamUrl('t1', tier: null), 'http://box:3000/api/stream/t1');
      expect(c.streamUrl('t1', tier: ''), 'http://box:3000/api/stream/t1');
      expect(c.streamUrl('t1', tier: 'original'),
          'http://box:3000/api/stream/t1');
      expect(
          c.streamUrl('t1', tier: 'high'), 'http://box:3000/api/stream/t1?tier=high');
      expect(
          c.streamUrl('t1', tier: 'low'), 'http://box:3000/api/stream/t1?tier=low');
    });
  });

  group('endpoints', () {
    late List<http.Request> seen;

    AriaClient client(Object? Function(http.Request) handler) {
      seen = [];
      return AriaClient(
        baseUrl: 'http://box:3000',
        httpClient: MockClient((req) async {
          seen.add(req);
          final body = handler(req);
          return http.Response(jsonEncode(body), 200,
              headers: {'content-type': 'application/json'});
        }),
      );
    }

    test('tracks passes limit/offset query params', () async {
      final c = client((_) => []);
      await c.tracks(limit: 50, offset: 100);
      expect(seen.single.url.path, '/api/tracks');
      expect(seen.single.url.queryParameters, {'limit': '50', 'offset': '100'});
    });

    test('tracks omits query when unpaginated', () async {
      final c = client((_) => []);
      await c.tracks();
      expect(seen.single.url.query, isEmpty);
    });

    test('createPlaylist sends smart type when rules given', () async {
      final c = client((req) => {
            'id': 'p1',
            'profileId': 'default',
            'type': 'smart',
            'name': 'X',
            'rules': jsonDecode(req.body)['rules'],
          });
      const rules = SmartRules(match: 'all', rules: [
        SmartRule(field: 'lossless', op: 'is', value: true),
      ]);
      final p =
          await c.createPlaylist(profileId: 'default', name: 'X', rules: rules);
      final sent = jsonDecode(seen.single.body) as Map<String, dynamic>;
      expect(sent['type'], 'smart');
      expect(sent['rules']['match'], 'all');
      expect(p.isSmart, isTrue);
      expect(p.rules!.rules.single.field, 'lossless');
    });

    test('tag item add/remove use PUT/DELETE with JSON body', () async {
      final c = client(
          (_) => {'id': 'u1', 'name': 'Chill', 'parent': null, 'items': []});
      await c.addTagItem('u1', kind: 'album', key: 'A');
      await c.removeTagItem('u1', kind: 'album', key: 'A');
      expect(seen[0].method, 'PUT');
      expect(seen[1].method, 'DELETE');
      expect(jsonDecode(seen[1].body), {'kind': 'album', 'key': 'A'});
      expect(seen[0].url.path, '/api/tags/u1/items');
    });

    test('updateTag distinguishes absent parent from explicit null', () async {
      final c = client(
          (_) => {'id': 'u1', 'name': 'Chill', 'parent': null, 'items': []});
      await c.updateTag('u1', name: 'Calm');
      expect(jsonDecode(seen[0].body), {'name': 'Calm'});
      await c.updateTag('u1', parent: null);
      expect(jsonDecode(seen[1].body), {'parent': null});
    });

    test('stats passes profileId and counts=1', () async {
      final c = client((_) => {
            'totalPlays': 0,
            'totalSeconds': 0,
            'uniqueTracks': 0,
            'week': {'plays': 0, 'seconds': 0},
            'month': {'plays': 0, 'seconds': 0},
          });
      await c.stats(profileId: 'default', counts: true);
      expect(seen.single.url.queryParameters,
          {'profileId': 'default', 'counts': '1'});
    });

    test('artist name is URL-encoded', () async {
      final c = client((_) => {'bio': 'x'});
      await c.artist('AC/DC');
      expect(seen.single.url.path, '/api/artist/AC%2FDC');
    });

    test('booklets returns the server name list', () async {
      final c = client((_) => {'booklets': ['Booklet.PDF', 'scan.pdf']});
      expect(await c.booklets('deadbeef'), ['Booklet.PDF', 'scan.pdf']);
      expect(seen.single.url.path, '/api/albums/deadbeef/booklets');
    });

    test('booklets empty list when the album has no PDF', () async {
      final c = client((_) => {'booklets': []});
      expect(await c.booklets('deadbeef'), isEmpty);
    });

    test('404 lookups return null', () async {
      final c = AriaClient(
        baseUrl: 'http://box:3000',
        httpClient: MockClient((_) async => http.Response('Not Found', 404)),
      );
      expect(await c.artist('nobody'), isNull);
      expect(await c.lyrics('nope'), isNull);
      expect(await c.composer('nope'), isNull);
      expect(await c.albumInfo('nope'), isNull);
      expect(await c.edits('track', 'nope'), isNull);
    });

    test('non-2xx throws AriaApiException with server error message', () async {
      final c = AriaClient(
        baseUrl: 'http://box:3000',
        httpClient: MockClient(
            (_) async => http.Response('{"error":"invalid name"}', 400)),
      );
      await expectLater(
        c.createTag(''),
        throwsA(isA<AriaApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'invalid name')),
      );
    });

    test('uploadLogs posts device+entries and returns stored count', () async {
      final c = client((_) => {'stored': 2});
      final n = await c.uploadLogs('linux-a1b2c3', [
        {'ts': 't0', 'level': 'info', 'tag': 'app', 'msg': 'start'},
        {'ts': 't1', 'level': 'error', 'tag': 'playback', 'msg': 'boom'},
      ]);
      expect(n, 2);
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/api/logs');
      final sent = jsonDecode(seen.single.body) as Map<String, dynamic>;
      expect(sent['device'], 'linux-a1b2c3');
      expect((sent['entries'] as List), hasLength(2));
    });

    test('recordPlay posts trackId+profileId', () async {
      final c = client((_) => {'ok': true});
      await c.recordPlay(trackId: 't1', profileId: 'default');
      expect(seen.single.method, 'POST');
      expect(seen.single.url.path, '/api/plays');
      expect(jsonDecode(seen.single.body),
          {'trackId': 't1', 'profileId': 'default'});
    });

    test('recordPlay includes at only when supplied', () async {
      final c = client((_) => {'ok': true});
      await c.recordPlay(
          trackId: 't1', profileId: 'default', at: '2026-07-08T12:00:00.000Z');
      expect(jsonDecode(seen.single.body), {
        'trackId': 't1',
        'profileId': 'default',
        'at': '2026-07-08T12:00:00.000Z',
      });
    });

    test('download streams the original bytes from /api/stream', () async {
      final c = client((_) => null); // unused — raw handler below
      final raw = AriaClient(
        baseUrl: 'http://box:3000',
        httpClient: MockClient((req) async {
          expect(req.url.path, '/api/stream/t%201');
          return http.Response.bytes([1, 2, 3], 200,
              headers: {'content-type': 'audio/flac', 'etag': '"e1"'});
        }),
      );
      final res = await raw.download('t 1');
      expect(res.headers['etag'], '"e1"');
      expect(await res.stream.toBytes(), [1, 2, 3]);
      c.close();
    });

    test('download appends ?tier=low, omits it for original/null', () async {
      final seen = <Uri>[];
      final raw = AriaClient(
        baseUrl: 'http://box:3000',
        httpClient: MockClient((req) async {
          seen.add(req.url);
          return http.Response.bytes([1], 200);
        }),
      );
      await raw.download('t1', tier: 'low');
      await raw.download('t1');
      await raw.download('t1', tier: 'original');
      expect(seen[0].toString(), 'http://box:3000/api/stream/t1?tier=low');
      expect(seen[1].toString(), 'http://box:3000/api/stream/t1');
      expect(seen[2].toString(), 'http://box:3000/api/stream/t1');
    });

    test('download/downloadArt throw AriaApiException on non-2xx', () async {
      final raw = AriaClient(
        baseUrl: 'http://box:3000',
        httpClient: MockClient((_) async => http.Response('Not Found', 404)),
      );
      await expectLater(
        raw.download('nope'),
        throwsA(isA<AriaApiException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
      await expectLater(raw.downloadArt('nope'),
          throwsA(isA<AriaApiException>()));
    });

    test('tracksBytes returns the raw payload; decodeTracks parses it',
        () async {
      final c = client((_) => [
            {'id': 't1', 'albumId': 'al1', 'title': 'One'},
          ]);
      final bytes = await c.tracksBytes();
      final tracks = AriaClient.decodeTracks(bytes);
      expect(tracks.single.id, 't1');
      expect(tracks.single.title, 'One');
    });

    test('scan returns track count', () async {
      final c = client((_) => {'tracks': 4321});
      expect(await c.scan(), 4321);
      expect(seen.single.method, 'POST');
    });

    test('genres parses tree', () async {
      final c = client((_) => {
            'tree': {'Jazz': null, 'Swing': 'Jazz'}
          });
      final g = await c.genres();
      expect(g.childrenOf('Jazz'), ['Swing']);
    });

    test('eqOpra parses products with eqs and bands', () async {
      final c = client((_) => {
            'products': [
              {
                'vendor': 'Sennheiser',
                'product': 'HD 650',
                'eqs': [
                  {
                    'author': 'oratory1990',
                    'gainDb': -6.8,
                    'bands': [
                      {'type': 'peak_dip', 'frequency': 105, 'gainDb': 3.1, 'q': 0.7},
                      {'type': 'low_pass', 'frequency': 18000, 'slope': 12},
                    ],
                  },
                ],
              },
            ],
          });
      final products = await c.eqOpra();
      expect(seen.single.url.path, '/api/eq/opra');
      final eq = products.single.eqs.single;
      expect(products.single.vendor, 'Sennheiser');
      expect(eq.author, 'oratory1990');
      expect(eq.gainDb, -6.8);
      expect(eq.bands.first.q, 0.7);
      expect(eq.bands.last.slope, 12);
      expect(eq.bands.last.q, isNull);
    });

    test('reidentify posts mbid (null allowed for fresh search)', () async {
      final c = client((_) => <String, dynamic>{});
      await c.reidentifyAlbum('A', mbid: null);
      expect(seen.single.url.path, '/api/album/A/reidentify');
      expect(jsonDecode(seen.single.body), {'mbid': null});
    });
  });
}
