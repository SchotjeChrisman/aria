import 'package:aria/features/review/match_detail_dialog.dart';
import 'package:aria/features/review/review_screen.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// The identification review queue. Its two row states are not two styles of
/// the same thing: `review` found releases and could not choose, `local`
/// found nothing to choose from, and only the first has a picker behind it.

Widget reviewSectionHeaderStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'ReviewSectionHeader',
        note: 'Title, count and a line saying what the section is asking of '
            'you — the queue is two questions, and the header is what tells '
            'them apart.',
        child: Column(
          children: [
            ReviewSectionHeader(
              title: 'Needs a decision',
              blurb: 'MusicBrainz offered more than one release and the '
                  'matcher could not separate them.',
              count: 1,
            ),
            ReviewSectionHeader(
              title: 'Nothing found',
              blurb: 'No release worth offering. These retry on their own.',
              count: 1,
            ),
            ReviewSectionHeader(
              title: 'All settled',
              blurb: 'Nothing waiting.',
              count: 0,
            ),
          ],
        ),
      ),
    ],
  );
}

Widget decisionTileStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'DecisionTile',
        note: 'One album in the queue. Tapping opens the detail dialog, which '
            'is why the tile is handed the page\'s WidgetRef rather than '
            'reading providers itself — the dialog outlives the tile.',
        child: Consumer(
          builder: (context, ref, _) => Column(
            children: [
              for (final d in fixtureDecisions)
                Variant(
                  label: '${d.state} · ${d.reason}',
                  child: DecisionTile(decision: d, pageRef: ref),
                ),
            ],
          ),
        ),
      ),
    ],
  );
}

Widget matchDetailDialogStory(BuildContext context) {
  final showLocal = context.knobs
      .boolean(label: 'nothing-found row', initialValue: false);

  return StoryPage(
    children: [
      Section(
        title: 'MatchDetailDialog',
        note: 'The evidence behind one decision: every candidate release with '
            'its distance, and the per-component penalty that produced it. '
            'The nothing-found variant has no picker at all, because there is '
            'nothing to pick.',
        child: SizedBox(
          height: 560,
          child: Consumer(
            builder: (context, ref, _) => MatchDetailDialog(
              ref: ref,
              decision: showLocal ? localDecision : reviewDecision,
            ),
          ),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final reviewEntries = <Entry>[
  Entry(
    component: 'ReviewSectionHeader',
    key: 'review-section-header',
    builder: reviewSectionHeaderStory,
  ),
  Entry(
    component: 'DecisionTile',
    key: 'decision-tile',
    builder: decisionTileStory,
  ),
  Entry(
    component: 'MatchDetailDialog',
    key: 'match-detail-dialog',
    builder: matchDetailDialogStory,
  ),
];
