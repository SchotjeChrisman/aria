import 'package:aria/core/theme.dart';
import 'package:aria/features/stats/charts.dart';
import 'package:aria/features/stats/stats_page.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// The stats page's three drawing primitives. All three take their data as
/// arguments, so none of them needs the server — the page above them is what
/// talks to `/api/stats`.

Widget barChartStory(BuildContext context) {
  final height = context.knobs.double
      .slider(label: 'height', initialValue: 90, min: 48, max: 200);

  final daily = [
    for (final v in [3, 0, 7, 12, 5, 0, 0, 9, 14, 2, 6, 8, 1, 0])
      ChartPoint(value: v, tip: '$v plays'),
  ];

  return StoryPage(
    children: [
      Section(
        title: 'BarChart',
        note: 'Bar height is relative to the series maximum with a 3% floor, '
            'so a zero day is still a visible tick rather than nothing at '
            'all — a gap in the row would read as missing data.',
        child: BarChart(title: 'Plays per day', points: daily, height: height),
      ),
      Section(
        title: 'Edge cases',
        child: Column(
          children: [
            Variant(
              label: 'single bar',
              child: BarChart(
                title: 'One day',
                points: const [ChartPoint(value: 4)],
              ),
            ),
            Variant(
              label: 'all zero',
              child: BarChart(
                title: 'Nothing played',
                points: List.filled(14, const ChartPoint(value: 0)),
              ),
            ),
            const Variant(
              label: 'no points',
              child: BarChart(title: 'No data', points: []),
            ),
          ],
        ),
      ),
    ],
  );
}

Widget miniListStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'MiniList',
        note: 'Numbered top-5 with a right-aligned count column. Rows with an '
            'onTap are the only ones that respond — the counts column is not '
            'a link.',
        child: MiniList(
          title: 'Most played tracks',
          rows: [
            for (final t in fixtureStats.topTracks.take(5))
              MiniListRow(
                label:
                    fixtureTracks.firstWhere((x) => x.id == t.id).title ?? '',
                sub: fixtureTracks.firstWhere((x) => x.id == t.id).artist ?? '',
                n: t.count,
                onTap: () {},
              ),
          ],
        ),
      ),
      Section(
        title: 'Without sub-lines',
        child: MiniList(
          title: 'Most played artists',
          rows: [
            for (final a in fixtureStats.topArtists)
              MiniListRow(label: a.name, n: a.count),
          ],
        ),
      ),
      const Section(
        title: 'Empty',
        note: 'Nothing played yet — the box keeps its title so the page does '
            'not reflow once the first play lands.',
        child: MiniList(title: 'Most played albums', rows: []),
      ),
    ],
  );
}

Widget statTileStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'StatTile',
        note: 'A big number over a label. The number is pre-formatted by the '
            'caller — the tile never rounds or abbreviates, so "1.2k" is a '
            'decision the page made.',
        child: Wrap(
          spacing: AriaSpace.s4,
          runSpacing: AriaSpace.s4,
          children: [
            StatTile(num_: '${fixtureStats.totalPlays}', label: 'plays'),
            StatTile(
              num_: '${(fixtureStats.totalSeconds / 3600).round()}h',
              label: 'listened',
            ),
            StatTile(num_: '${fixtureStats.uniqueTracks}', label: 'tracks'),
            const StatTile(num_: '0', label: 'this week'),
          ],
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final statsEntries = <Entry>[
  Entry(component: 'BarChart', key: 'bar-chart', builder: barChartStory),
  Entry(component: 'MiniList', key: 'mini-list', builder: miniListStory),
  Entry(component: 'StatTile', key: 'stat-tile', builder: statTileStory),
];
