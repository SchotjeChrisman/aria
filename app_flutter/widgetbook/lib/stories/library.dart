import 'package:aria/core/theme.dart';
import 'package:aria/features/library/albums_section.dart';
import 'package:aria/features/library/artists_section.dart';
import 'package:aria/features/library/composers_section.dart';
import 'package:aria/features/library/genre_card.dart';
import 'package:aria/features/library/genres_section.dart';
import 'package:aria/features/library/library_sort.dart';
import 'package:aria/features/library/person_card.dart';
import 'package:aria/features/library/track_filters.dart';
import 'package:aria/features/library/tracks_section.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import '../api.dart';
import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// The library browser. Four of its five sections are slivers rather than
/// widgets — the whole page is one scroll view so the filter row scrolls away
/// with the grid — which is why they are mounted in a CustomScrollView here.

/// Gives a sliver section the scroll view and the bounded height it needs.
Widget _sliverHost(Widget sliver, {double height = 520}) => SizedBox(
      height: height,
      child: CustomScrollView(slivers: [sliver]),
    );

Widget albumsSectionStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'AlbumsSection',
        note: 'Filter row, sort dropdown and the album grid, all reading the '
            'live filter/sort notifiers — the pills really filter the fixture '
            'library.',
        child: _sliverHost(const AlbumsSection()),
      ),
    ],
  );
}

Widget artistsSectionStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ArtistsSection',
        note: 'Portrait grid. Missing faces are warmed once per screen life '
            'in a single bounded request, not per scroll — the initials you '
            'see are what a cold cache looks like.',
        child: _sliverHost(const ArtistsSection()),
      ),
    ],
  );
}

Widget composersSectionStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ComposersSection',
        note: 'Same grid as artists, over composer tags rather than artist '
            'credits — a composer with no tracks tagged to them does not '
            'appear at all.',
        child: _sliverHost(const ComposersSection()),
      ),
    ],
  );
}

Widget genresSectionStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'GenresSection',
        note: 'Top-level genres only; children are reached through the genre '
            'page. The server\'s genre tree decides what is a parent.',
        child: _sliverHost(const GenresSection()),
      ),
    ],
  );
}

Widget tracksSectionStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'TracksSection',
        note: 'The sortable table: click a header to sort, click it again to '
            'flip. Unlike the other sections this one is a Column with its '
            'own scrolling body, so it needs a bounded height.',
        child: const SizedBox(height: 520, child: TracksSection()),
      ),
    ],
  );
}

Widget genreCardStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'GenreCard',
        note: 'Generated art plus album and artist counts, computed over the '
            'genre and everything under it — a parent genre counts its '
            'children\'s albums.',
        child: Wrap(
          spacing: AriaSpace.s5,
          runSpacing: AriaSpace.s5,
          children: [
            for (final g in ['Jazz', 'Classical', 'Modal Jazz'])
              SizedBox(
                width: 190,
                height: 230,
                child: GenreCard(genre: g),
              ),
          ],
        ),
      ),
    ],
  );
}

Widget genreArtStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'GenreArt',
        note: 'A two-tone gradient and an icon per genre, from a fixed table. '
            'Anything not in the table falls back to a neutral pair, so a '
            'genre the table has never heard of still gets a tile.',
        child: Wrap(
          spacing: AriaSpace.s4,
          runSpacing: AriaSpace.s4,
          children: [
            for (final g in [
              'Jazz',
              'Classical',
              'Rock',
              'Metal',
              'Folk',
              'Vaporwave',
            ])
              Variant(
                label: g,
                child: SizedBox.square(
                  dimension: 120,
                  child: GenreArt(genre: g),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

Widget genrePillStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'GenrePill',
        note: 'An outlined genre link, used wherever a track or album lists '
            'its genres. No fill — these sit in dense rows and a filled chip '
            'would out-shout the title beside it.',
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            GenrePill(genre: 'Jazz'),
            GenrePill(genre: 'Modal Jazz'),
            GenrePill(genre: 'Classical'),
            GenrePill(genre: 'Christian & Gospel'),
          ],
        ),
      ),
    ],
  );
}

Widget libraryPersonCardStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'PersonCard',
        note: 'The artists and composers grids\' card. Its onSecondary hands '
            'back the pointer position so the caller can open the artist '
            'context menu where the click happened.',
        child: Wrap(
          spacing: AriaSpace.s5,
          runSpacing: AriaSpace.s5,
          children: [
            for (final name in fixtureArtists.take(4))
              PersonCard(
                name: name,
                subtitle: '2 albums',
                imageUrl: storybookClient.peopleImgUrl(name),
                onTap: () {},
                onSecondary: (_) {},
              ),
          ],
        ),
      ),
    ],
  );
}

Widget sortDropdownStory(BuildContext context) {
  const options = [
    SortOption('artist', 'Artist'),
    SortOption('title', 'Title'),
    SortOption('year', 'Year'),
    SortOption('added', 'Recently added'),
  ];

  return StoryPage(
    children: [
      Section(
        title: 'SortDropdown',
        note: 'A controlled component: it renders the value it is given and '
            'reports changes. The persisted sort lives in a notifier, not in '
            'here.',
        child: Align(
          alignment: Alignment.centerLeft,
          child: SortDropdown(
            options: options,
            // Driven from the knob panel rather than local state: the
            // component is controlled, and a story that owned the value
            // would be demonstrating the story's state, not the widget's.
            value: context.knobs.object.dropdown(
              label: 'value',
              options: [for (final o in options) o.key],
            ),
            onChanged: (_) {},
          ),
        ),
      ),
    ],
  );
}

Widget trackTableStory(BuildContext context) {
  const sort = TracksSort('artist', 1);

  return StoryPage(
    children: [
      Section(
        title: 'TrackCells',
        note: 'The column geometry, and nothing else — one Row with the nine '
            'column widths. Both the header and every body row are built '
            'through it, which is what keeps them aligned.',
        child: TrackCells(
          builder: (key) => Text(
            key,
            style: Theme.of(context).textTheme.labelMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      const Section(
        title: 'TrackHeaderRow',
        note: 'Sortable headers. The active column carries the direction '
            'caret; clicking it flips, clicking another starts ascending.',
        child: TrackHeaderRow(sort: sort),
      ),
      Section(
        title: 'TrackTableRow',
        note: 'Alternating rows, the playing one accented, play counts only '
            'when the sort or filter asked for them.',
        child: Column(
          children: [
            for (final (i, t) in fixtureTracks.take(6).indexed)
              TrackTableRow(
                track: t,
                index: i,
                plays: fixturePlayCounts[t.id],
                isCurrent: i == 2,
                onTap: () {},
                onSecondary: (_) {},
              ),
          ],
        ),
      ),
    ],
  );
}

Widget trackFilterDialogStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'TrackFilterDialog',
        note: 'Every track filter in one dialog: multi-selects for genre, '
            'artist and format, year and added-within ranges, and the '
            'any-vs-all combinator that decides how they compose.',
        child: const SizedBox(height: 640, child: TrackFilterDialog()),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final libraryEntries = <Entry>[
  Entry(
    folder: 'Sections',
    component: 'AlbumsSection',
    key: 'albums-section',
    builder: albumsSectionStory,
  ),
  Entry(
    folder: 'Sections',
    component: 'ArtistsSection',
    key: 'artists-section',
    builder: artistsSectionStory,
  ),
  Entry(
    folder: 'Sections',
    component: 'ComposersSection',
    key: 'composers-section',
    builder: composersSectionStory,
  ),
  Entry(
    folder: 'Sections',
    component: 'GenresSection',
    key: 'genres-section',
    builder: genresSectionStory,
  ),
  Entry(
    folder: 'Sections',
    component: 'TracksSection',
    key: 'tracks-section',
    builder: tracksSectionStory,
  ),
  Entry(
    folder: 'Genres',
    component: 'GenreCard',
    key: 'genre-card',
    builder: genreCardStory,
  ),
  Entry(
    folder: 'Genres',
    component: 'GenreArt',
    key: 'genre-art',
    builder: genreArtStory,
  ),
  Entry(
    folder: 'Genres',
    component: 'GenrePill',
    key: 'genre-pill',
    builder: genrePillStory,
  ),
  Entry(
    component: 'PersonCard',
    key: 'library-person-card',
    builder: libraryPersonCardStory,
  ),
  Entry(
    component: 'SortDropdown',
    key: 'sort-dropdown',
    builder: sortDropdownStory,
  ),
  Entry(
    folder: 'Track table',
    component: 'Table rows',
    key: 'track-table',
    builder: trackTableStory,
  ),
  Entry(
    folder: 'Track table',
    component: 'TrackFilterDialog',
    key: 'track-filter-dialog',
    builder: trackFilterDialogStory,
  ),
];
