import 'package:aria/features/library/library_providers.dart';
import 'package:aria/features/library/track_filters.dart';
import 'package:aria/features/search/translit.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_test/flutter_test.dart';

Track t({
  String id = 't1',
  String? artist,
  String? albumArtist,
  String? composer,
  String? format,
  List<String> genres = const [],
  int? year,
  bool lossless = false,
  String? releaseType,
  String? addedAt,
  List<Performer> performers = const [],
}) => Track(
  id: id,
  albumId: 'al',
  artist: artist,
  albumArtist: albumArtist,
  composer: composer,
  format: format,
  genres: genres,
  year: year,
  lossless: lossless,
  releaseType: releaseType,
  addedAt: addedAt,
  performers: performers,
);

const emptyTags = TagNameIndex({}, {}, {});

bool pass(
  Track track,
  TrackFilters f, {
  Map<String, String?> parents = const {},
  TagNameIndex tagIndex = emptyTags,
  Map<String, int>? counts,
}) => trackPassesFilters(
  track,
  f,
  genreParents: parents,
  tagIndex: tagIndex,
  playCounts: counts,
);

void main() {
  group('trackPassesFilters', () {
    test('multi-select OR passes on any hit, AND needs all', () {
      final track = t(
        artist: 'Miles Davis',
        performers: const [Performer(name: 'John Coltrane')],
      );
      const orF = TrackFilters(
        strings: {
          'credited': MultiFilter(vals: ['coltrane', 'nobody']),
        },
      );
      const andF = TrackFilters(
        strings: {
          'credited': MultiFilter(vals: ['coltrane', 'nobody'], mode: 'all'),
        },
      );
      const andOk = TrackFilters(
        strings: {
          'credited': MultiFilter(vals: ['coltrane', 'miles'], mode: 'all'),
        },
      );
      expect(pass(track, orF), isTrue);
      expect(pass(track, andF), isFalse);
      expect(pass(track, andOk), isTrue);
    });

    test('genre matches exactly, including ancestors', () {
      final track = t(genres: const ['Blues Rock']);
      const parents = {'Blues Rock': 'Blues', 'Blues': null};
      const blues = TrackFilters(
        strings: {
          'genre': MultiFilter(vals: ['Blues']),
        },
      );
      const pop = TrackFilters(
        strings: {
          'genre': MultiFilter(vals: ['Blue']), // exact: no substring match
        },
      );
      expect(pass(track, blues, parents: parents), isTrue);
      expect(pass(track, pop, parents: parents), isFalse);
    });

    test('year range, lossless and release type', () {
      final track = t(year: 1972, lossless: true, releaseType: 'Album');
      expect(pass(track, const TrackFilters(yearFrom: 1970)), isTrue);
      expect(pass(track, const TrackFilters(yearTo: 1971)), isFalse);
      expect(pass(track, const TrackFilters(lossless: 'true')), isTrue);
      expect(pass(track, const TrackFilters(lossless: 'false')), isFalse);
      expect(pass(track, const TrackFilters(type: 'Live')), isFalse);
    });

    test('played filter passes everything until counts land', () {
      final track = t();
      const f = TrackFilters(played: 'played');
      expect(pass(track, f, counts: null), isTrue); // counts not loaded yet
      expect(pass(track, f, counts: const {}), isFalse);
      expect(pass(track, f, counts: const {'t1': 3}), isTrue);
      expect(
        pass(track, const TrackFilters(played: 'never'), counts: const {}),
        isTrue,
      );
    });

    test('added-within-days uses addedAt', () {
      final recent = t(addedAt: DateTime.now().toIso8601String());
      final old = t(addedAt: '2001-01-01T00:00:00Z');
      const f = TrackFilters(added: 30);
      expect(pass(recent, f), isTrue);
      expect(pass(old, f), isFalse);
      expect(pass(t(), f), isFalse); // no addedAt at all
    });

    test('activeCount counts one per active group (legacy badge)', () {
      const f = TrackFilters(
        strings: {
          'albumArtist': MultiFilter(vals: ['x']),
          'genre': MultiFilter(vals: ['y']),
        },
        yearFrom: 1990,
        lossless: 'true',
      );
      expect(f.activeCount, 4);
      expect(const TrackFilters().isEmpty, isTrue);
    });
  });

  group('translit search', () {
    test('latin query hits cyrillic values', () {
      expect(matchesQuery('Чайковский', 'chajkovskij'), isTrue);
      expect(matchesQuery('Дмитрий Шостакович', 'shostakovich'), isTrue);
    });

    test('greek values romanize', () {
      expect(matchesQuery('Μίκης Θεοδωράκης', 'theodorakis'), isTrue);
    });

    test('plain contains still works and latin-only skips the pass', () {
      expect(matchesQuery('Miles Davis', 'davis'), isTrue);
      expect(translit('Miles Davis'), isNull);
      expect(matchesQuery('Miles Davis', 'coltrane'), isFalse);
    });
  });
}
