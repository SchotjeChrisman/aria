import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'match_detail_dialog.dart';
import 'providers.dart';

/// Why the matcher stopped, and what that means for the person reading it.
/// Reasons the server adds later fall through to their raw name rather than
/// vanishing from the page — same rule as the health screen's issue labels.
const _reasonLabels = <String, (String, String)>{
  'low-separation': (
    'Close call',
    'A rival release scored nearly as well. Pick the right one.',
  ),
  'weak-match': (
    'Weak match',
    'The best release still disagrees with your tags in several places.',
  ),
  'no-candidates': (
    'Nothing found',
    'MusicBrainz returned no release for these tags.',
  ),
  'no-plausible-candidate': (
    'Nothing close enough',
    'Everything MusicBrainz offered is too far off to be this album.',
  ),
  'indistinguishable-siblings': (
    'Too many near-identical releases',
    'Several releases fit equally badly — usually a sign the album is not in '
        'MusicBrainz at all.',
  ),
  'pinned': ('Pinned', 'You chose this release; the matcher leaves it alone.'),
  'ok': ('Matched', ''),
};

/// The albums the matcher declined to decide. This is the other half of the
/// health report: health says what is wrong, this is where it gets resolved.
class ReviewScreen extends ConsumerWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(reviewQueueProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Match review'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(reviewQueueProvider),
          ),
        ],
      ),
      body: queue.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: ariaPagePadding(context),
            child: Text('Could not load the review queue.\n$e'),
          ),
        ),
        data: (all) {
          // The split is not cosmetic. `review` means the matcher found
          // releases and could not choose — there is something to pick.
          // `local` means it found nothing worth offering, and on a real
          // library that is the majority: a picker would render empty.
          final undecided = all.where((d) => d.state == 'review').toList();
          final unfound = all.where((d) => d.state != 'review').toList();
          return ListView(
            padding: ariaPagePadding(context),
            children: [
              if (all.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AriaSpace.s4),
                  child: Text(
                    'Nothing needs review — every album the matcher looked at '
                    'it was sure about.',
                  ),
                ),
              if (undecided.isNotEmpty) ...[
                _SectionHeader(
                  title: 'Needs review',
                  blurb:
                      'The matcher found releases for these but would not pick '
                      'one on its own.',
                  count: undecided.length,
                ),
                for (final d in undecided) _DecisionTile(decision: d),
                const SizedBox(height: AriaSpace.s6),
              ],
              if (unfound.isNotEmpty) ...[
                _SectionHeader(
                  title: 'No match found',
                  blurb:
                      'MusicBrainz had nothing for these. Your tags are being '
                      'used as-is, and the server retries on its own.',
                  count: unfound.length,
                ),
                for (final d in unfound) _DecisionTile(decision: d),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.blurb,
    required this.count,
  });

  final String title;
  final String blurb;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AriaColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AriaSpace.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$title · $count', style: theme.textTheme.titleMedium),
          Text(
            blurb,
            style: theme.textTheme.bodySmall?.copyWith(color: c.fgDim),
          ),
        ],
      ),
    );
  }
}

class _DecisionTile extends ConsumerWidget {
  const _DecisionTile({required this.decision});

  final MatchDecision decision;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = decision;
    final (label, _) = _reasonLabels[d.reason] ?? (d.reason, '');
    final sub = [
      label,
      // A null distance is "never scored", which is the opposite of 0 — the
      // best possible score. Printing 0.00 here would claim these uncertain
      // albums are perfect matches.
      if (d.distance != null) 'distance ${d.distance!.toStringAsFixed(2)}',
      if (d.candidates.isNotEmpty) '${d.candidates.length} candidates',
      if (d.pinned) 'pinned',
    ].where((s) => s.isNotEmpty).join(' · ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        [d.albumArtist, d.album].where((s) => s.isNotEmpty).join(' — '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => showMatchDetail(context, ref, d),
    );
  }
}
