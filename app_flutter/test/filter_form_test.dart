import 'package:aria/features/library/track_filters.dart';
import 'package:aria/features/playlists/smart_filter.dart';
import 'package:aria/widgets/filter_form.dart';
import 'package:aria/widgets/multi_select_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// Every filter row, populated. Anything a consumer drops shows up below.
FilterDraft _full() {
  final d = FilterDraft()
    ..match = 'any'
    ..favourites = true
    ..yearFrom = 1969
    ..yearTo = 1971
    ..lossless = 'true'
    ..releaseType = 'Album'
    ..played = 'never'
    ..addedDays = 30
    ..minSampleRate = 96000
    ..minBits = 24
    ..loudnessFrom = -14
    ..loudnessTo = -6.5
    ..minDynamicRange = 8
    ..suspect = 'false';
  d.strings['albumArtist']!
    ..vals.add('The Beatles')
    ..mode = 'all';
  d.strings['genre']!.vals.add('Jazz');
  return d;
}

void main() {
  group('the two filter forms are one form', () {
    testWidgets('every row is rendered, once', (tester) async {
      await tester.pumpWidget(
        _app(FilterForm(draft: FilterDraft(), options: const {})),
      );

      for (final label in [
        'Match all fields',
        'Favourites only',
        ...filterStringFields.map((f) => f.$2),
        'Year',
        'Quality',
        'Release type',
        'Played',
        'Added (days)',
        'Minimum sample rate',
        'Minimum bit depth',
        'Loudness (LUFS)',
        'Dynamic range over (LU)',
        'Suspect files',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    test('the Tracks filter keeps every row of the shared draft', () {
      final f = filtersOf(_full());
      expect(f.combine, 'any');
      expect(f.favourites, isTrue);
      expect(f.yearFrom, 1969);
      expect(f.yearTo, 1971);
      expect(f.lossless, 'true');
      expect(f.type, 'Album');
      expect(f.played, 'never');
      expect(f.added, 30);
      expect(f.minSampleRate, 96000);
      expect(f.minBits, 24);
      expect(f.loudnessFrom, -14);
      expect(f.loudnessTo, -6.5);
      expect(f.minDynamicRange, 8);
      expect(f.suspect, 'false');
      expect(f.stringFilter('albumArtist').vals, ['The Beatles']);
      expect(f.stringFilter('albumArtist').mode, 'all');
      expect(f.stringFilter('genre').vals, ['Jazz']);
      // One badge count per group: the two multi-selects, the year pair as
      // one, and the eleven scalars.
      expect(f.activeCount, 14);
    });

    test('the smart editor keeps every row of the same draft', () {
      final r = stateToRules(_full()).rules!;
      expect(r.match, 'any');
      final fields = {for (final rule in r.rules) rule.field};
      expect(fields, {
        'albumArtist',
        'genre',
        'year',
        'lossless',
        'releaseType',
        'playCount',
        'addedDays',
        'favourite',
        'sampleRate',
        'bitsPerSample',
        'loudness',
        'dynamicRange',
        'suspect',
      });
      // Rules the server would reject are rules the editor cannot save.
      expect(r.isValid, isTrue);
    });

    test('Tracks filters round-trip through the shared draft', () {
      final before = filtersOf(_full());
      final after = filtersOf(draftOf(before));
      expect(after.activeCount, before.activeCount);
      expect(after.combine, before.combine);
      expect(after.minDynamicRange, before.minDynamicRange);
      expect(after.stringFilter('albumArtist').vals, ['The Beatles']);
      expect(after.stringFilter('albumArtist').mode, 'all');
    });
  });
}
