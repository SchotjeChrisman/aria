import 'package:aria/features/search/search_page.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import '../fixtures.dart';
import 'catalogue.dart';
import 'foundations.dart' show Section, StoryPage;

/// Search results come back as three lists — artists, albums, tracks — and
/// the widget draws whichever of them are non-empty, in that order.

Widget searchResultsStory(BuildContext context) {
  final artists = context.knobs.boolean(label: 'artists', initialValue: true);
  final albums = context.knobs.boolean(label: 'albums', initialValue: true);
  final tracks = context.knobs.boolean(label: 'tracks', initialValue: true);

  return StoryPage(
    children: [
      Section(
        title: 'SearchResultsList',
        note: 'Each section is drawn only when it has hits, so a query that '
            'only matches track titles shows one list and no empty headings. '
            'Toggle the knobs to see each combination.',
        child: SizedBox(
          height: 620,
          child: SearchResultsList(
            results: SearchResults(
              artists: artists ? fixtureArtists.take(4).toList() : const [],
              albums: albums ? fixtureAlbums : const [],
              tracks: tracks ? fixtureTracks : const [],
            ),
          ),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final searchEntries = <Entry>[
  Entry(
    component: 'SearchResultsList',
    key: 'search-results',
    builder: searchResultsStory,
  ),
];
