import 'package:aria/core/connection.dart';
import 'package:aria/widgets/album_card.dart';
import 'package:aria/widgets/unowned_album_card.dart';
import 'package:flutter/material.dart';
import 'package:aria/core/library_providers.dart';
import 'package:aria/features/listen_later/providers.dart';
import 'package:aria/features/release/release_page.dart';
import 'package:aria/features/release/routes.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake at the client level — no HTTP.
class _FakeClient extends AriaClient {
  _FakeClient({this.saved = const []}) : super(baseUrl: 'http://s');

  final List<ListenLaterAlbum> saved;

  /// Records what the app actually sent, so the deezerId hint is provably
  /// forwarded rather than silently dropped.
  final adds = <Map<String, Object?>>[];
  final removes = <String>[];

  @override
  Future<List<ListenLaterAlbum>> listenLater({String? profileId}) async =>
      saved;

  @override
  Future<ListenLaterAlbum> addListenLater({
    required String artist,
    required String title,
    String? profileId,
    int? deezerId,
  }) async {
    adds.add({'artist': artist, 'title': title, 'deezerId': deezerId});
    return ListenLaterAlbum(
      id: 'rg:x',
      artist: artist,
      title: title,
      type: 'album',
      addedAt: 't',
    );
  }

  @override
  Future<void> removeListenLater(String id, {String? profileId}) async =>
      removes.add(id);
}

ListenLaterAlbum _entry(String id, String artist, String title) =>
    ListenLaterAlbum(
      id: id,
      artist: artist,
      title: title,
      type: 'album',
      addedAt: '2026-01-01T00:00:00.000Z',
    );

Track _track({required String albumArtist, required String album}) => Track(
      id: 'sha-$album',
      title: 'One',
      artist: albumArtist,
      albumArtist: albumArtist,
      album: album,
      albumId: 'alb-$album',
    );

void main() {
  /// Container with the client faked and, optionally, a stub library.
  ProviderContainer withOverrides(AriaClient client, {List<Track>? library}) {
    final c = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        if (library != null)
          libraryTracksProvider.overrideWith((ref) async => library),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('listenLaterProvider surfaces the saved list', () async {
    final c = withOverrides(
      _FakeClient(saved: [_entry('rg:1', 'Coldplay', 'Moon Music')]),
    );
    final got = await c.read(listenLaterProvider.future);
    expect(got.map((e) => e.title), ['Moon Music']);
  });

  test('the deezerId hint reaches the server so it can skip a name search',
      () async {
    final fake = _FakeClient();
    final c = withOverrides(fake);
    await c.read(apiClientProvider).addListenLater(
          artist: 'Coldplay',
          title: 'Moon Music',
          deezerId: 650278821,
        );
    expect(fake.adds.single['deezerId'], 650278821);
  });

  // The route carries artist+title, so it has to survive the punctuation real
  // album titles contain — a naive path join would break on the slash.
  test('releasePath round-trips titles containing slashes and spaces', () {
    const artist = 'AC/DC';
    const title = 'Rock or Bust (Deluxe)';
    final path = releasePath(artist, title, deezerId: 7);
    expect(path, contains('deezerId=7'));
    final segs = Uri.parse(path).pathSegments;
    expect(Uri.decodeComponent(segs[1]), artist);
    expect(Uri.decodeComponent(segs[2]), title);
  });

  // UnownedAlbumCard shares grids with AlbumCard (artist discography) and grid
  // delegates tuned for AlbumCard's height (Listen Later). A third text line
  // silently overflows those tiles at narrow widths, which the analyzer cannot
  // see — so pin the two cards to the same height.
  testWidgets('is no taller than AlbumCard, so shared grids do not overflow',
      (tester) async {
    Future<double> heightOf(Widget card) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(_FakeClient())],
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 146, child: card),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getSize(find.byType(Column).first).height;
    }

    final plain = await heightOf(
      const AlbumCard(title: 'Moon Music', subtitle: 'Coldplay · 2024'),
    );
    final unowned = await heightOf(
      const UnownedAlbumCard(
        artist: 'Coldplay',
        title: 'Moon Music',
        subtitle: '2024 · Not in library',
      ),
    );
    expect(unowned, lessThanOrEqualTo(plain),
        reason: 'a taller card overflows the grid cells AlbumCard was sized for');
    expect(tester.takeException(), isNull);
  });

  group('ownedAlbumProvider — the release page hands off once you own it', () {
    test('matches an owned album despite an edition suffix', () async {
      final c = withOverrides(
        _FakeClient(),
        library: [
          _track(albumArtist: 'Coldplay', album: 'Moon Music (Deluxe Edition)'),
        ],
      );
      final owned = await c.read(
        ownedAlbumProvider(const ReleaseRef('Coldplay', 'Moon Music')).future,
      );
      expect(owned, isNotNull);
      expect(owned!.title, 'Moon Music (Deluxe Edition)');
    });

    test('does not match a different album by the same artist', () async {
      final c = withOverrides(
        _FakeClient(),
        library: [_track(albumArtist: 'Coldplay', album: 'Parachutes')],
      );
      final owned = await c.read(
        ownedAlbumProvider(const ReleaseRef('Coldplay', 'Moon Music')).future,
      );
      expect(owned, isNull);
    });

    test('does not match the same title by a different artist', () async {
      final c = withOverrides(
        _FakeClient(),
        library: [_track(albumArtist: 'Someone Else', album: 'Moon Music')],
      );
      final owned = await c.read(
        ownedAlbumProvider(const ReleaseRef('Coldplay', 'Moon Music')).future,
      );
      expect(owned, isNull);
    });
  });
}
