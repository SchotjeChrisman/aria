import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'fixtures.dart';

/// A loopback stand-in for the Aria server, so the catalogue can show the real
/// widgets doing the real thing.
///
/// The alternative was mocking providers one by one. Every network-touching
/// path in the app funnels through `AriaClient(baseUrl:)`, and cover art is
/// fetched by `Image.network` — which goes straight to `dart:io`'s HttpClient
/// and never sees an injected `http.Client`. One socket satisfies both; a
/// mock layer would have needed two, and would still have left `ArtImage`
/// showing nothing but initials.
class FakeAriaServer {
  FakeAriaServer._(this._server, this._webRoot);

  final HttpServer _server;

  /// When set, anything that is not `/api/*` is served from this directory —
  /// the `flutter build web` output. Serving the catalogue and its data from
  /// one origin is what keeps the web build free of CORS configuration.
  final Directory? _webRoot;

  int get port => _server.port;
  String get baseUrl => 'http://127.0.0.1:$port';

  /// [port] 0 lets the OS pick, so two catalogues can run at once; the web
  /// server pins one so the URL is predictable. [hostname] defaults to
  /// loopback — pass an address only if something off-machine must reach it.
  static Future<FakeAriaServer> start({
    int port = 0,
    Directory? webRoot,
    InternetAddress? hostname,
  }) async {
    final server = await HttpServer.bind(
      hostname ?? InternetAddress.loopbackIPv4,
      port,
    );
    final fake = FakeAriaServer._(server, webRoot);
    unawaited(fake._serve());
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final req in _server) {
      final res = req.response;
      try {
        if (req.uri.path.startsWith('/api/')) {
          _route(req.uri, res);
        } else {
          await _static(req.uri, res);
        }
      } catch (_) {
        res.statusCode = HttpStatus.internalServerError;
      }
      await res.close();
    }
  }

  /// Serves the built catalogue. Unknown paths fall back to index.html so a
  /// deep link still boots the app rather than 404ing.
  Future<void> _static(Uri uri, HttpResponse res) async {
    final root = _webRoot;
    if (root == null) {
      res.statusCode = HttpStatus.notFound;
      return;
    }
    final rel = uri.path == '/' ? 'index.html' : uri.path.substring(1);
    var file = File('${root.path}/$rel');
    if (!file.existsSync()) file = File('${root.path}/index.html');
    if (!file.existsSync()) {
      res.statusCode = HttpStatus.notFound;
      return;
    }
    res.headers.contentType = _contentTypeFor(file.path);
    await res.addStream(file.openRead());
  }

  static ContentType _contentTypeFor(String path) => switch (
      path.substring(path.lastIndexOf('.') + 1)) {
        'html' => ContentType.html,
        'js' || 'mjs' => ContentType('text', 'javascript', charset: 'utf-8'),
        'json' => ContentType.json,
        'css' => ContentType('text', 'css', charset: 'utf-8'),
        'wasm' => ContentType('application', 'wasm'),
        'png' => ContentType('image', 'png'),
        'svg' => ContentType('image', 'svg+xml'),
        'ttf' => ContentType('font', 'ttf'),
        'otf' => ContentType('font', 'otf'),
        'woff2' => ContentType('font', 'woff2'),
        _ => ContentType.binary,
      };

  void _route(Uri uri, HttpResponse res) {
    final path = uri.path;

    // ---- images: /api/art/<albumId>, /api/people/img/<name>, and the
    // external-cover proxy. All answered with a generated cover so the seed
    // is stable per subject — the same album is the same colour every run.
    if (path.startsWith('/api/art/')) {
      return _png(res, _seed(path.split('/').last));
    }
    if (path.startsWith('/api/people/img/')) {
      // Portraits are dimmer and lower-contrast than covers so an avatar
      // never reads as a mis-cropped album tile.
      return _png(res, _seed(path.split('/').last), portrait: true);
    }
    if (path == '/api/extalbum/img') {
      return _png(res, _seed(uri.queryParameters['u'] ?? ''));
    }

    // ---- JSON. Unknown routes answer [] rather than 404: an unlisted
    // endpoint should leave a widget empty, never wedge it in an error state
    // that has nothing to do with the component being catalogued.
    // Path-parameter routes. One album, one artist and one composer are
    // enriched no matter which id is asked for: the catalogue's question is
    // what an enriched page looks like, not which row the server holds.
    if (path.endsWith('/info') && path.startsWith('/api/album/')) {
      return _json(res, fixtureAlbumInfoJson);
    }
    if (path.startsWith('/api/artist/')) {
      return _json(res, fixtureArtistInfoJson);
    }
    if (path.startsWith('/api/composer/')) {
      return _json(res, fixtureComposerInfoJson);
    }
    if (path.startsWith('/api/lyrics/')) {
      return _json(res, fixtureLyricsJson);
    }
    if (path.startsWith('/api/albums/') && path.endsWith('/match')) {
      return _json(res, fixtureDecisionJson.first);
    }
    if (path.startsWith('/api/albums/') && path.endsWith('/booklets')) {
      return _json(res, {'booklets': const ['booklet.pdf']});
    }
    // A real PDF, not a placeholder: the booklet screen hands the URL to
    // pdfrx, which renders the file itself. Anything that is not a PDF puts
    // the viewer in its error state — and an error state whose text is a
    // stack trace makes a golden that only matches the machine that wrote it.
    if (path.startsWith('/api/albums/') && path.contains('/booklet/')) {
      res.headers.contentType = ContentType('application', 'pdf');
      res.add(_pdf());
      return;
    }
    if (path.startsWith('/api/playlists/') && path.endsWith('/tracks')) {
      return _json(res, fixtureTrackJson);
    }
    if (path.startsWith('/api/edits/')) {
      return _json(res, {
        'original': {'album': 'Kind of Blue', 'albumArtist': 'Miles Davis'},
        'overrides': const <String, Object>{},
      });
    }

    final body = switch (path) {
      '/api/status' => {
          'tracks': fixtureTracks.length,
          'albums': 4,
          'version': 'widgetbook',
        },
      '/api/tracks' => fixtureTrackJson,
      '/api/tags' => fixtureTagJson,
      '/api/playlists' => fixturePlaylistJson,
      '/api/profiles' => fixtureProfileJson,
      '/api/people' => fixturePeopleJson,
      '/api/genres' => fixtureGenreTreeJson,
      '/api/settings' => {'listenbrainzToken': ''},
      '/api/enrich/status' => fixtureEnrichStatusJson,
      '/api/stats' => fixtureStatsJson,
      '/api/plays/counts' => {'counts': fixturePlayCounts},
      '/api/mixes' => fixtureMixesJson,
      '/api/newreleases' => fixtureNewReleaseJson,
      '/api/listenlater' => fixtureListenLaterJson,
      '/api/extalbum' => fixtureExtAlbumJson,
      '/api/library/health' => fixtureHealthJson,
      '/api/library/duplicates' => fixtureDuplicateJson,
      '/api/match/review' => fixtureDecisionJson,
      '/api/radio' => fixtureStationJson,
      '/api/eq/opra' => fixtureOpraJson,
      _ => const <Object>[],
    };
    _json(res, body);
  }

  void _json(HttpResponse res, Object body) {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
  }

  /// Stable non-cryptographic hash — the same id must yield the same cover on
  /// every run, or scrolling a grid would reshuffle colours on each rebuild.
  static int _seed(String s) {
    var h = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0xffffffff;
    }
    return h;
  }

  void _png(HttpResponse res, int seed, {bool portrait = false}) {
    res.headers.contentType = ContentType('image', 'png');
    // Immutable per subject, like real server art — lets Flutter's ImageCache
    // do its job instead of refetching on every scroll.
    res.headers.set(HttpHeaders.cacheControlHeader, 'max-age=86400');
    res.add(_cover(seed, portrait: portrait));
  }
}

// ------------------------------------------------------------------ booklet

/// A one-page PDF reading "Album booklet", built here rather than shipped as
/// a binary fixture so the byte offsets in the xref table are computed and
/// cannot rot.
Uint8List _pdf() {
  const content = 'BT /F1 24 Tf 60 500 Td (Album booklet) Tj ET\n';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 595] '
        '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    '<< /Length ${content.length} >>\nstream\n${content}endstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];

  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (final (i, body) in objects.indexed) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n$body\nendobj\n');
  }

  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final off in offsets) {
    out.write('${off.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n');

  // Latin-1: every byte above is ASCII, and offsets are counted in bytes.
  return Uint8List.fromList(latin1.encode(out.toString()));
}

// ---------------------------------------------------------------- cover art

/// A 240px diagonal two-tone gradient, hue picked from [seed].
///
/// Generated rather than shipped as fixture files: a handful of embedded PNGs
/// would repeat across a 24-tile grid and make the layout look wrong in a way
/// the layout is not. Gradients also compress to a few KB, so the encoder
/// below stays cheap.
Uint8List _cover(int seed, {bool portrait = false}) {
  const size = 240;
  final hue = (seed % 360).toDouble();
  // Second stop rotated round the wheel, not merely lightened — a real cover
  // has two colours in it.
  final (r1, g1, b1) = _hsl(hue, portrait ? 0.18 : 0.52, portrait ? 0.62 : 0.46);
  final (r2, g2, b2) =
      _hsl((hue + 48) % 360, portrait ? 0.14 : 0.44, portrait ? 0.42 : 0.22);

  // Raw scanlines: one filter byte (0 = None) then RGB triples.
  final raw = Uint8List(size * (1 + size * 3));
  var o = 0;
  for (var y = 0; y < size; y++) {
    raw[o++] = 0;
    for (var x = 0; x < size; x++) {
      final t = (x + y) / (2 * (size - 1));
      raw[o++] = (r1 + (r2 - r1) * t).round();
      raw[o++] = (g1 + (g2 - g1) * t).round();
      raw[o++] = (b1 + (b2 - b1) * t).round();
    }
  }
  return _encodePng(size, size, raw);
}

/// HSL -> 0-255 RGB. Saturation and lightness are the knobs the cover palette
/// actually varies; hue comes from the seed.
(double, double, double) _hsl(double h, double s, double l) {
  final c = (1 - (2 * l - 1).abs()) * s;
  final x = c * (1 - ((h / 60) % 2 - 1).abs());
  final m = l - c / 2;
  final (r, g, b) = switch (h ~/ 60) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  return ((r + m) * 255, (g + m) * 255, (b + m) * 255);
}

// ------------------------------------------------------------- PNG encoding

/// Minimal 8-bit truecolour PNG writer: signature, IHDR, one IDAT, IEND.
///
/// Hand-rolled because the alternative is a new dependency (`image`) pulled in
/// to draw a rectangle. dart:io already ships the only hard part — zlib.
Uint8List _encodePng(int width, int height, Uint8List raw) {
  final out = BytesBuilder();
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final ihdr = Uint8List(13);
  final hv = ByteData.view(ihdr.buffer);
  hv.setUint32(0, width);
  hv.setUint32(4, height);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // colour type 2 = truecolour RGB
  // ihdr[10..12] = 0: deflate, adaptive filtering, no interlace.
  out.add(_chunk('IHDR', ihdr));

  out.add(_chunk('IDAT', Uint8List.fromList(zlib.encode(raw))));
  out.add(_chunk('IEND', Uint8List(0)));
  return out.takeBytes();
}

/// length + type + data + CRC32(type + data), all big-endian.
Uint8List _chunk(String type, Uint8List data) {
  final typeBytes = ascii.encode(type);
  final out = Uint8List(12 + data.length);
  final view = ByteData.view(out.buffer);
  view.setUint32(0, data.length);
  out.setRange(4, 8, typeBytes);
  out.setRange(8, 8 + data.length, data);
  view.setUint32(8 + data.length, _crc32(typeBytes, data));
  return out;
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> a, List<int> b) {
  var c = 0xFFFFFFFF;
  for (final byte in a) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  for (final byte in b) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
