import 'package:aria/core/phosphor_icons.dart';
import 'package:aria/features/home/home_screen.dart';
import 'package:flutter/material.dart';

import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// The home screen's blocks. Three of them draw play history, which is
/// bucketed against the wall clock — those are rendered by the test but not
/// golden-matched, because their pixels legitimately change every day.

Widget statStripStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'LibraryStatStrip',
        note: 'Track, album, artist and hour counts, all derived from the '
            'track list it is handed. Nothing here is fetched — the strip is '
            'a projection of the library the page already loaded.',
        child: LibraryStatStrip(
          tracks: fixtureTracks,
          albumCount: fixtureAlbums.length,
        ),
      ),
      const Section(
        title: 'Empty library',
        child: LibraryStatStrip(tracks: [], albumCount: 0),
      ),
    ],
  );
}

Widget mixesShelfStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'MixesShelf',
        note: 'Daily, weekly, monthly and yearly, each with a fixed icon and '
            'colour. A mix whose track list came back empty is dropped rather '
            'than shown as an empty banner.',
        child: MixesShelf(),
      ),
    ],
  );
}

Widget mixBannerStory(BuildContext context) {
  final mixes = <(String, (IconData, Color))>[
    (
      'Daily Mix',
      (PhosphorIconsRegular.sun, const Color(0xFF7C4DFF)),
    ),
    (
      'Weekly Mix',
      (PhosphorIconsRegular.calendarBlank, const Color(0xFF00897B)),
    ),
    (
      'Monthly Mix',
      (PhosphorIconsRegular.calendarDots, const Color(0xFFEF6C00)),
    ),
    (
      'Yearly Mix',
      (PhosphorIconsRegular.trophy, const Color(0xFF3949AB)),
    ),
  ];

  return StoryPage(
    children: [
      Section(
        title: 'MixBanner',
        note: 'The icon and colour are passed in, not derived from the mix — '
            'the shelf owns that table so the four banners cannot drift apart.',
        child: Column(
          children: [
            for (final (i, (title, looks)) in mixes.indexed)
              Variant(
                label: title,
                child: SizedBox(
                  width: 420,
                  child: MixBanner(
                    mix: (
                      id: 'mix-$i',
                      title: title,
                      subtitle: '${fixtureTracks.length} tracks',
                      tracks: fixtureTracks,
                    ),
                    looks: looks,
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

Widget albumShelfStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'AlbumShelf',
        note: 'A titled row of album cards. subFor overrides the sub-line per '
            'album — how Most Played shows "N plays" where the others show '
            'the artist.',
        child: AlbumShelf(title: 'Recently added', albums: fixtureAlbums),
      ),
      Section(
        title: 'With a subtitle override',
        child: AlbumShelf(
          title: 'Most played',
          albums: fixtureAlbums,
          subFor: {
            for (final a in fixtureStats.topAlbums) a.albumId: '${a.count} plays',
          },
        ),
      ),
    ],
  );
}

Widget artistShelfStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ArtistShelf',
        note: 'Avatar discs rather than cards, so this shelf passes an '
            'explicit item width instead of letting the band decide.',
        child: ArtistShelf(title: 'Artists', names: fixtureArtists),
      ),
      Section(
        title: 'With play counts',
        child: ArtistShelf(
          title: 'Most listened',
          names: [for (final a in fixtureStats.topArtists) a.name],
          subFor: {
            for (final a in fixtureStats.topArtists) a.name: '${a.count} plays',
          },
        ),
      ),
    ],
  );
}

Widget listeningStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ListeningSection',
        note: 'The listening block: week and month totals, the top artist, '
            'and the day chart. Everything comes off one Stats object.',
        child: ListeningSection(stats: fixtureStats),
      ),
    ],
  );
}

Widget ranksCardStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'RanksCard',
        note: 'Top tracks, albums and artists over a switchable window. The '
            'period buttons refetch `/api/plays/counts` — the card ranks by '
            'time listened, which needs durations as well as counts.',
        child: RanksCard(),
      ),
    ],
  );
}

Widget weeklyTimeBoxStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'WeeklyTimeBox',
        note: 'Five weeks of totals beside a weekday dot grid. Both columns '
            'share a row height and a header stand-in so their rows line up — '
            'the alignment is the whole point of the component.',
        child: WeeklyTimeBox(
          weekSecs: const [12400, 9800, 15200, 4300, 7600],
          dayGrid: const [
            [3600, 0, 1800, 5400, 0, 900, 700],
            [0, 2400, 3000, 0, 1200, 2600, 600],
            [4800, 1200, 0, 3600, 2400, 1800, 1400],
            [0, 0, 900, 1200, 600, 900, 700],
            [1800, 1200, 900, 0, 2400, 600, 700],
          ],
        ),
      ),
      const Section(
        title: 'Nothing listened',
        child: WeeklyTimeBox(
          weekSecs: [0, 0, 0, 0, 0],
          dayGrid: [
            [0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0],
          ],
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final homeEntries = <Entry>[
  Entry(
    component: 'LibraryStatStrip',
    key: 'stat-strip',
    builder: statStripStory,
  ),
  Entry(component: 'MixesShelf', key: 'mixes-shelf', builder: mixesShelfStory),
  Entry(component: 'MixBanner', key: 'mix-banner', builder: mixBannerStory),
  Entry(component: 'AlbumShelf', key: 'album-shelf', builder: albumShelfStory),
  Entry(
    component: 'ArtistShelf',
    key: 'artist-shelf',
    builder: artistShelfStory,
  ),
  Entry(
    component: 'ListeningSection',
    key: 'listening-section',
    builder: listeningStory,
    golden: false,
  ),
  Entry(
    component: 'RanksCard',
    key: 'ranks-card',
    builder: ranksCardStory,
    golden: false,
  ),
  Entry(
    component: 'WeeklyTimeBox',
    key: 'weekly-time-box',
    builder: weeklyTimeBoxStory,
  ),
];
