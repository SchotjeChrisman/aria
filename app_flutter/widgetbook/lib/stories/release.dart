import 'package:aria/features/release/release_page.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// An album nobody here owns. The cover is the whole component: it carries
/// the save-for-later action, and it is the one place a proxy-then-CDN image
/// chain is visible on its own.

Widget releaseCoverStory(BuildContext context) {
  final size = context.knobs.double
      .slider(label: 'size', initialValue: 220, min: 120, max: 320);

  return StoryPage(
    children: [
      Section(
        title: 'ReleaseCover',
        note: 'The server\'s caching proxy first, the raw CDN URL second — '
            'Deezer drops covers under burst load and rotates URLs, so a '
            'single-source image would be blank half the time.',
        child: Align(
          alignment: Alignment.centerLeft,
          child: ReleaseCover(
            album: fixtureExtAlbum,
            ref_: const ReleaseRef('Vijay Iyer', 'Compassion', deezerId: 1000),
            size: size,
          ),
        ),
      ),
      Section(
        title: 'Sizes in use',
        note: '220 on a wide layout, 160 when the page stacks.',
        child: Wrap(
          spacing: 24,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            for (final s in [160.0, 220.0])
              Variant(
                label: '${s.toInt()}px',
                child: ReleaseCover(
                  album: fixtureExtAlbum,
                  ref_: const ReleaseRef('Vijay Iyer', 'Compassion'),
                  size: s,
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final releaseEntries = <Entry>[
  Entry(
    component: 'ReleaseCover',
    key: 'release-cover',
    builder: releaseCoverStory,
  ),
];
