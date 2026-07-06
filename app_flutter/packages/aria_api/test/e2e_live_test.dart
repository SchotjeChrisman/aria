// Live contract test: real AriaClient against the real server container.
// Run with: dart test test/e2e_live_test.dart  (requires server on $ARIA_E2E_URL)
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:aria_api/aria_api.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  final url = Platform.environment['ARIA_E2E_URL'];
  if (url == null) {
    test('skipped: ARIA_E2E_URL not set', () {});
    return;
  }
  final client = AriaClient(baseUrl: url);
  tearDownAll(client.close);

  test('status reports scanned library', () async {
    final s = await client.status();
    expect(s.tracks, 3);
  });

  test('tracks parse with format info and stable ids', () async {
    final tracks = await client.tracks();
    expect(tracks, hasLength(3));
    final hires = tracks.firstWhere((t) => t.bitsPerSample == 24);
    expect(hires.sampleRate, 96000);
    expect(hires.lossless, isTrue);
    expect(hires.id, hasLength(40)); // sha1 hex
  });

  test('stream URL serves ranged audio', () async {
    final tracks = await client.tracks();
    final res = await http.get(
      Uri.parse(client.streamUrl(tracks.first.id)),
      headers: {'Range': 'bytes=0-99'},
    );
    expect(res.statusCode, 206);
    expect(res.bodyBytes, hasLength(100));
  });

  test('playlist roundtrip', () async {
    final p = await client.createPlaylist(profileId: 'default', name: 'e2e');
    final tracks = await client.tracks();
    await client.addPlaylistTrack(p.id, tracks.first.id);
    final got = await client.playlistTracks(p.id);
    expect(got.single.id, tracks.first.id);
    await client.deletePlaylist(p.id);
  });
}
