import 'package:aria/core/phosphor_icons.dart';
import 'package:aria/core/quality.dart';
import 'package:aria/features/settings/about_screen.dart';
import 'package:aria/features/settings/account_screen.dart';
import 'package:aria/features/settings/data_screen.dart';
import 'package:aria/features/settings/eq_browse.dart';
import 'package:aria/features/settings/eq_screen.dart';
import 'package:aria/features/settings/health_screen.dart';
import 'package:aria/features/settings/library_screen.dart';
import 'package:aria/features/settings/playback_screen.dart';
import 'package:aria/features/settings/quality_selector.dart';
import 'package:aria/features/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// Settings is mostly tiles: a row that states the current value and opens
/// the thing that changes it. Almost all of them read a provider rather than
/// taking arguments, so these stories are one line each and the state comes
/// from the stub.

Widget settingsTileStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'SettingsTile',
        note: 'Icon, title, one line of explanation, and a route. The '
            'subtitle says what the page is for — not what it contains, which '
            'the page itself will say.',
        child: Column(
          children: [
            SettingsTile(
              icon: PhosphorIconsRegular.speakerHigh,
              title: 'Playback',
              subtitle: 'Output device, exclusive mode, EQ and loudness.',
              slug: 'playback',
            ),
            SettingsTile(
              icon: PhosphorIconsRegular.vinylRecord,
              title: 'Library',
              subtitle: 'Scanning, health and the identification queue.',
              slug: 'library',
            ),
            SettingsTile(
              icon: PhosphorIconsRegular.downloadSimple,
              title: 'Data',
              subtitle: 'Downloads, offline copies and network usage.',
              slug: 'data',
            ),
          ],
        ),
      ),
    ],
  );
}

Widget accountFieldsStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'ServerUrlField',
        note: 'Editing this repoints the whole app. It tests the URL before '
            'saving it, so a typo fails here rather than everywhere else.',
        child: ServerUrlField(),
      ),
      Section(
        title: 'ListenBrainzField',
        note: 'A token field: loads what the server holds, and an empty save '
            'clears it. The token is never shown back in full.',
        child: ListenBrainzField(),
      ),
    ],
  );
}

Widget libraryTilesStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'HealthTile',
        note: 'Summarises `/api/library/health` in one line and links to the '
            'detail page. Clean libraries say so rather than hiding the row.',
        child: HealthTile(),
      ),
      Section(
        title: 'ReviewTile',
        note: 'How many albums the matcher could not settle. Reads the same '
            'queue the review screen does.',
        child: ReviewTile(),
      ),
      Section(
        title: 'LibraryTools',
        note: 'Scan, enrich, and the progress they report while running.',
        child: LibraryTools(),
      ),
    ],
  );
}

Widget healthStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'HealthCounts',
        note: 'Tracks, albums, analysed, fingerprinted, identified — read by '
            'key, so a server that adds a counter needs no app release.',
        child: HealthCounts(health: fixtureHealth),
      ),
      Section(
        title: 'IssueTile',
        note: 'One issue kind, expandable to the affected albums. The count '
            'is the true total; the item list is capped at 100 server-side, '
            'which is why they are two different numbers.',
        child: Column(
          children: [
            for (final issue in fixtureHealth.issues)
              Variant(
                label: '${issue.kind} · ${issue.count}',
                child: IssueTile(issue: issue),
              ),
          ],
        ),
      ),
    ],
  );
}

Widget duplicatesStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'DupeGroupTile',
        note: 'Exact means the decoded audio is byte-identical. The other '
            'kind is AcoustID agreeing it is the same recording, which may be '
            'a re-encode — or a compilation you meant to keep.',
        child: Column(
          children: [
            for (final g in fixtureDuplicates)
              Variant(
                label: g.exact ? 'byte-identical' : 'same recording',
                child: DupeGroupTile(group: g),
              ),
          ],
        ),
      ),
      const Section(
        title: 'DuplicatesSection',
        note: 'The whole list, read from `/api/library/duplicates`. Read-only '
            'by design — nothing on this page deletes a file.',
        child: DuplicatesSection(),
      ),
    ],
  );
}

Widget playbackTilesStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'ExclusiveToggle',
        note: 'Hands the output device to the app alone. Platform-dependent, '
            'so the tile explains what it will and will not do here.',
        child: ExclusiveToggle(),
      ),
      Section(
        title: 'EqTile',
        note: 'Current EQ preset and a way in. Off is a state worth showing '
            'plainly — bit-perfect is the default and the tile says so.',
        child: EqTile(),
      ),
      Section(
        title: 'LoudnessTile',
        note: 'Off, match tracks, or match albums, each with the sentence '
            'that explains what it costs — this is the setting most likely to '
            'be chosen for the wrong reason.',
        child: LoudnessTile(),
      ),
    ],
  );
}

Widget qualitySelectorStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'QualitySelector',
        note: 'Original is the untouched file; the other two are server-side '
            'Opus. Controlled — the caller owns the value, because streaming '
            'and downloading keep separate ones.',
        child: Column(
          children: [
            for (final tier in QualityTier.values)
              Variant(
                label: tier.wire,
                child: QualitySelector(
                  label: 'On Wi-Fi',
                  value: tier,
                  onChanged: (_) {},
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

Widget dataStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'DataUsageSection',
        note: 'Streamed and downloaded bytes since the counter was last '
            'reset, split by network.',
        child: DataUsageSection(),
      ),
      Section(
        title: 'DownloadsTile',
        note: 'How much is stored offline and how many tracks that is.',
        child: DownloadsTile(),
      ),
      Section(
        title: 'LogsTile',
        note: 'Opens the on-device log. Present in About rather than under '
            'Data because it is a diagnostic, not a setting.',
        child: LogsTile(),
      ),
    ],
  );
}

Widget eqSearchListStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'EqSearchList',
        note: 'The pattern behind all three EQ browse screens: a search box '
            'over a long list, capped at 50 rows because the box is how you '
            'narrow it, not the scrollbar.',
        child: SizedBox(
          height: 460,
          child: EqSearchList(
            title: 'Headphones',
            hint: 'Search vendors',
            pinned: () => [
              const ListTile(title: Text('Recently used')),
            ],
            builder: (query) => [
              for (final p in fixtureOpraProducts)
                if (p.product.toLowerCase().contains(query.toLowerCase()))
                  ListTile(title: Text(p.product), subtitle: Text(p.vendor)),
            ],
          ),
        ),
      ),
    ],
  );
}

Widget customEqStory(BuildContext context) {
  final existing =
      context.knobs.boolean(label: 'edit a preset', initialValue: true);

  return StoryPage(
    children: [
      Section(
        title: 'CustomEqDialog',
        note: 'A parametric band editor: type, frequency, gain, and Q or '
            'slope depending on the type — a low-pass has no Q, and the form '
            'drops the field rather than disabling it.',
        child: SizedBox(
          height: 620,
          child: CustomEqDialog(preset: existing ? fixtureEqProfile : null),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final settingsEntries = <Entry>[
  Entry(
    component: 'SettingsTile',
    key: 'settings-tile',
    builder: settingsTileStory,
  ),
  Entry(
    folder: 'Account',
    component: 'Account fields',
    key: 'account-fields',
    builder: accountFieldsStory,
  ),
  Entry(
    folder: 'Library',
    component: 'Library tiles',
    key: 'library-tiles',
    builder: libraryTilesStory,
  ),
  Entry(
    folder: 'Library',
    component: 'Health',
    key: 'health',
    builder: healthStory,
  ),
  Entry(
    folder: 'Library',
    component: 'Duplicates',
    key: 'duplicates',
    builder: duplicatesStory,
  ),
  Entry(
    folder: 'Playback',
    component: 'Playback tiles',
    key: 'playback-tiles',
    builder: playbackTilesStory,
  ),
  Entry(
    folder: 'Playback',
    component: 'QualitySelector',
    key: 'quality-selector',
    builder: qualitySelectorStory,
  ),
  Entry(
    folder: 'Playback',
    component: 'EqSearchList',
    key: 'eq-search-list',
    builder: eqSearchListStory,
  ),
  Entry(
    folder: 'Playback',
    component: 'CustomEqDialog',
    key: 'custom-eq-dialog',
    builder: customEqStory,
  ),
  Entry(folder: 'Data', component: 'Data tiles', key: 'data', builder: dataStory),
];
