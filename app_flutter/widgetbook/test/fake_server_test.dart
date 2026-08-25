import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aria_api/aria_api.dart';
import 'package:aria_widgetbook/fake_server.dart';
import 'package:aria_widgetbook/fixtures.dart';
import 'package:flutter_test/flutter_test.dart';

/// The catalogue's two pieces of real logic: the stub server's routing and the
/// hand-rolled PNG encoder. Everything else in this project is arguments
/// passed to widgets the app already tests.
void main() {
  late FakeAriaServer server;
  late HttpClient http;

  setUpAll(() async {
    server = await FakeAriaServer.start();
    http = HttpClient();
  });

  tearDownAll(() async {
    http.close(force: true);
    await server.close();
  });

  Future<List<int>> getBytes(String path) async {
    final req = await http.getUrl(Uri.parse('${server.baseUrl}$path'));
    final res = await req.close();
    expect(res.statusCode, 200, reason: path);
    return res.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
  }

  Future<Object?> getJson(String path) async =>
      jsonDecode(utf8.decode(await getBytes(path)));

  group('cover art', () {
    test('is a decodable 8-bit truecolour PNG', () async {
      final png = await getBytes('/api/art/a-kind-of-blue');

      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
          reason: 'PNG signature');

      // Walk the chunks the way a decoder would, checking each CRC.
      final view = ByteData.sublistView(Uint8List.fromList(png));
      var offset = 8;
      final types = <String>[];
      while (offset < png.length) {
        final length = view.getUint32(offset);
        final type = ascii.decode(png.sublist(offset + 4, offset + 8));
        final declared = view.getUint32(offset + 8 + length);
        expect(declared, _crc32(png.sublist(offset + 4, offset + 8 + length)),
            reason: 'CRC of $type chunk');
        types.add(type);
        offset += 12 + length;
      }
      expect(offset, png.length, reason: 'no trailing bytes after IEND');
      expect(types, ['IHDR', 'IDAT', 'IEND']);

      expect(view.getUint32(16), 240, reason: 'width');
      expect(view.getUint32(20), 240, reason: 'height');
      expect(png[24], 8, reason: 'bit depth');
      expect(png[25], 2, reason: 'colour type 2 = truecolour RGB');
      expect(png.sublist(26, 29), [0, 0, 0],
          reason: 'deflate, adaptive filtering, no interlace');
    });

    test('inflates to exactly one filter byte per RGB scanline', () async {
      final png = await getBytes('/api/art/a-kind-of-blue');
      final view = ByteData.sublistView(Uint8List.fromList(png));
      const idatStart = 8 + 25; // signature + IHDR chunk
      final idatLength = view.getUint32(idatStart);
      final raw = zlib.decode(
        png.sublist(idatStart + 8, idatStart + 8 + idatLength),
      );

      expect(raw.length, 240 * (1 + 240 * 3));
      for (var y = 0; y < 240; y++) {
        expect(raw[y * (1 + 240 * 3)], 0, reason: 'filter byte on row $y');
      }
      // A flat image would mean the gradient never ran.
      expect(raw.sublist(1, 4), isNot(raw.sublist(raw.length - 3)));
    });

    test('is stable per subject and differs between subjects', () async {
      final a1 = await getBytes('/api/art/a-kind-of-blue');
      final a2 = await getBytes('/api/art/a-kind-of-blue');
      final b = await getBytes('/api/art/goldberg-variations-1981');

      expect(a1, a2, reason: 'same album must not reshuffle between requests');
      expect(a1, isNot(b), reason: 'different albums must not collide');
    });

    test('serves portraits and proxied external covers too', () async {
      for (final path in [
        '/api/people/img/Miles%20Davis',
        '/api/extalbum/img?u=https://cdn.example/owl-song.jpg',
      ]) {
        expect((await getBytes(path)).sublist(1, 4), ascii.encode('PNG'),
            reason: path);
      }
    });
  });

  group('json', () {
    test('/api/tracks decodes through the app decoder', () async {
      final bytes = await getBytes('/api/tracks');
      final tracks = AriaClient.decodeTracks(bytes);

      expect(tracks.length, fixtureTrackJson.length);
      expect(tracks.map((t) => t.id), fixtureTracks.map((t) => t.id));

      // The states the catalogue claims to cover must actually be present.
      expect(tracks.any((t) => (t.bitsPerSample ?? 0) > 16), isTrue,
          reason: 'a hi-res track');
      expect(tracks.any((t) => !t.lossless), isTrue, reason: 'a lossy track');
      expect(tracks.any((t) => !t.hasArt), isTrue, reason: 'an artless track');
      expect(tracks.any((t) => t.composer != null), isTrue,
          reason: 'a classical track');
    });

    test('tags and playlists parse into their models', () async {
      final tags = (await getJson('/api/tags') as List)
          .cast<Map<String, dynamic>>()
          .map(Tag.fromJson)
          .toList();
      expect(tags.length, fixtureTags.length);
      expect(tags.where((t) => t.folder), isNotEmpty, reason: 'a tag folder');
      expect(tags.where((t) => t.parent != null), isNotEmpty,
          reason: 'a foldered tag');

      final playlists = (await getJson('/api/playlists') as List)
          .cast<Map<String, dynamic>>()
          .map(Playlist.fromJson)
          .toList();
      expect(playlists.where((p) => p.isSmart), isNotEmpty);
      expect(playlists.where((p) => !p.isSmart), isNotEmpty,
          reason: 'showAddToPlaylistMenu filters smart playlists out, so a '
              'manual one must exist or that sheet renders empty');
    });

    test('unknown routes answer [] rather than an error', () async {
      expect(await getJson('/api/nothing-here'), isEmpty);
      expect(await getJson('/api/still/nothing'), isEmpty);
    });

    test('serves the feature endpoints the catalogue reads', () async {
      for (final path in const [
        '/api/stats',
        '/api/mixes',
        '/api/newreleases',
        '/api/listenlater',
        '/api/library/health',
        '/api/library/duplicates',
        '/api/match/review',
        '/api/radio',
        '/api/eq/opra',
        '/api/genres',
      ]) {
        expect(await getJson(path), isNotEmpty, reason: '$path is empty');
      }
    });

    test('the booklet route serves a PDF with a valid xref table', () async {
      expect(await getJson('/api/albums/anything/booklets'), isNotEmpty);

      final pdf = latin1.decode(await getBytes('/api/albums/x/booklet/b.pdf'));
      expect(pdf, startsWith('%PDF-'));
      expect(pdf, endsWith('%%EOF\n'));

      // Every offset in the xref table must land on the object it claims,
      // because pdfium seeks by them — a table built by hand goes stale the
      // moment an object above it changes length.
      final start = int.parse(
        RegExp(r'startxref\n(\d+)').firstMatch(pdf)!.group(1)!,
      );
      final rows = RegExp(r'^(\d{10}) 00000 n $', multiLine: true)
          .allMatches(pdf.substring(start))
          .map((m) => int.parse(m.group(1)!))
          .toList();
      expect(rows, hasLength(5));
      for (final (i, off) in rows.indexed) {
        expect(pdf.substring(off), startsWith('${i + 1} 0 obj'));
      }
    });

    test('path-parameter routes answer for any id', () async {
      expect(await getJson('/api/artist/Anyone'), isNotEmpty);
      expect(await getJson('/api/composer/Anyone'), isNotEmpty);
      expect(await getJson('/api/album/anything/info'), isNotEmpty);
      expect(await getJson('/api/lyrics/anything'), isNotEmpty);
    });
  });

  group('fixtures', () {
    test('group into albums by the app rules', () {
      expect(fixtureAlbums.length, 4);
      expect(albumById('a-kind-of-blue').tracks.map((t) => t.trackNo),
          [1, 2, 3], reason: 'Album.group sorts by disc then track');
      expect(albumById('a-kind-of-blue').lossless, isTrue);
      expect(albumById('live-at-the-plugged-nickel').hasArt, isFalse);
    });
  });
}

/// Reference CRC32 (PNG polynomial), computed independently of the encoder so
/// the test is not checking the implementation against itself.
int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
