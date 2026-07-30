import 'package:aria/core/library_providers.dart';
import 'package:aria/features/library/library_providers.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Track t(
  String albumId, {
  String? albumArtist,
  String? orchestra,
  List<Performer> performers = const [],
}) => Track(
  id: '$albumId-1',
  albumId: albumId,
  albumArtist: albumArtist,
  orchestra: orchestra,
  performers: performers,
);

Future<Map<String, int>> artists(List<Track> library) async {
  final c = ProviderContainer(
    overrides: [libraryTracksProvider.overrideWith((ref) async => library)],
  );
  addTearDown(c.dispose);
  await c.read(libraryTracksProvider.future);
  return {for (final a in c.read(artistsProvider)) a.name: a.albumIds.length};
}

void main() {
  test('credited names browse only past 2 distinct albums', () async {
    final got = await artists([
      t('a1', albumArtist: 'Esther Yoo', orchestra: 'Royal Philharmonic'),
      t('a2', albumArtist: 'Nicola Benedetti', orchestra: 'Royal Philharmonic'),
      // one-album guest: real credit, but noise in a browse list
      t('a3', albumArtist: 'Hilary Hahn', performers: const [
        Performer(name: 'Guest Cellist', role: 'cello'),
      ]),
    ]);
    // credited on two albums -> browsable, counting both
    expect(got['Royal Philharmonic'], 2);
    // credited once -> excluded
    expect(got.containsKey('Guest Cellist'), isFalse);
    // album artists stay regardless of how few albums they have
    expect(got['Hilary Hahn'], 1);
    expect(got['Esther Yoo'], 1);
  });

  // Regression: albumIds drives the "N albums" subtitle and the "most albums"
  // sort. Folding credited appearances into it would silently restate the count
  // for every existing artist, on a screen this change is not about.
  test('an album artist album count ignores albums it only appears on', () async {
    final got = await artists([
      t('a1', albumArtist: 'Knopfler'),
      t('a2', albumArtist: 'Someone Else', performers: const [
        Performer(name: 'Knopfler', role: 'guitar'),
      ]),
      t('a3', albumArtist: 'Someone Else', performers: const [
        Performer(name: 'Knopfler', role: 'guitar'),
      ]),
    ]);
    expect(got['Knopfler'], 1,
        reason: 'appearances on a2/a3 must not inflate the fronted-album count');
    expect(got['Someone Else'], 2);
  });
}
