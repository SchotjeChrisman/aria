import 'package:aria/core/theme.dart';
import 'package:aria/features/radio/radio_page.dart';
import 'package:flutter/material.dart';

import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// Internet radio: a stream URL, a name, and no library behind it. Nothing
/// here reads a track — the cards drive the player directly, which in the
/// catalogue is a silent no-op.

Widget radioCardStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'RadioCard',
        note: 'Built-in stations cannot be deleted, so their context menu is '
            'shorter than a user station\'s. The genre line falls back to '
            '"Radio" when the station carries none.',
        child: Wrap(
          spacing: AriaSpace.s5,
          runSpacing: AriaSpace.s5,
          children: [
            for (final s in fixtureStations)
              Variant(
                width: 190,
                label: s.builtin ? 'built-in' : 'user station',
                child: RadioCard(station: s),
              ),
          ],
        ),
      ),
    ],
  );
}

Widget stationGroupsStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'StationGroups',
        note: 'Stations grouped by genre, genres alphabetical, untagged ones '
            'last under "Other".',
        child: StationGroups(stations: fixtureStations),
      ),
      const Section(
        title: 'Nothing added',
        child: StationGroups(stations: []),
      ),
    ],
  );
}

Widget stationFormStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'StationForm',
        note: 'Name and URL are required; genre is what StationGroups groups '
            'on. Saving POSTs to the stub server, so the station really '
            'appears in the list above.',
        child: StationForm(onDone: () {}),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final radioEntries = <Entry>[
  Entry(component: 'RadioCard', key: 'radio-card', builder: radioCardStory),
  Entry(
    component: 'StationGroups',
    key: 'station-groups',
    builder: stationGroupsStory,
  ),
  Entry(
    component: 'StationForm',
    key: 'station-form',
    builder: stationFormStory,
  ),
];
