import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router.dart';
import '../../core/theme.dart';
import 'settings_providers.dart';

/// Section headings and the one line explaining why each is worth knowing.
/// Kinds the server adds later fall through to their raw name rather than
/// vanishing from the page.
const _issueLabels = <String, (String, String)>{
  'unmatched': (
    'Unidentified albums',
    'No MusicBrainz release was confident enough. Open the album to choose one.',
  ),
  'lowSeparation': (
    'Close calls',
    'Matched, but a rival release scored nearly as well. Worth a glance.',
  ),
  'missingArt': ('Missing artwork', 'No cover, from the files or from enrichment.'),
  'missingMbid': ('No MusicBrainz ID', 'Nothing links these albums to a release.'),
  'suspect': (
    'Suspect files',
    'The decoded audio contradicts the file extension — usually a transcode '
        'wearing a lossless name.',
  ),
  'clipping': (
    'Clipping',
    'True peak above 0 dBFS. The samples fit; the reconstructed waveform does not.',
  ),
  'unanalysed': (
    'Not analysed yet',
    'Loudness and duplicate detection need a decode pass. Rescan to start one.',
  ),
};

/// Read-only view of what the identification and analysis passes could not
/// settle. Nothing on this page writes anything — least of all to a file.
class HealthScreen extends ConsumerWidget {
  const HealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(healthProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library health'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(healthProvider);
              ref.invalidate(duplicatesProvider);
            },
          ),
        ],
      ),
      body: health.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: ariaPagePadding(context),
            child: Text('Could not load library health.\n$e'),
          ),
        ),
        data: (h) => ListView(
          padding: ariaPagePadding(context),
          children: [
            HealthCounts(health: h),
            const SizedBox(height: AriaSpace.s4),
            if (h.clean)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AriaSpace.s4),
                child: Text('Nothing to report — every album is identified '
                    'and every file has been analysed.'),
              ),
            for (final issue in h.issues)
              if (issue.count > 0) IssueTile(issue: issue),
            const SizedBox(height: AriaSpace.s4),
            const DuplicatesSection(),
          ],
        ),
      ),
    );
  }
}

class HealthCounts extends StatelessWidget {
  const HealthCounts({super.key, required this.health});

  final LibraryHealth health;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final tracks = health.count('tracks');
    // Percentages of nothing are not informative; on an empty library the
    // counts alone say everything there is to say.
    String of(int n) =>
        tracks == 0 ? '$n' : '$n of $tracks (${(100 * n / tracks).round()}%)';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${health.count('albums')} albums, $tracks tracks', style: style),
        Text('Analysed: ${of(health.count('analysed'))}', style: style),
        Text('Fingerprinted: ${of(health.count('fingerprinted'))}', style: style),
        Text(
          'Identified by AcoustID: ${of(health.count('identified'))}',
          style: style,
        ),
      ],
    );
  }
}

class IssueTile extends StatelessWidget {
  const IssueTile({super.key, required this.issue});

  final HealthIssue issue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, blurb) = _issueLabels[issue.kind] ?? (issue.kind, '');
    final hidden = issue.count - issue.items.length;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: AriaSpace.s3),
      title: Text('$title · ${issue.count}'),
      subtitle: blurb.isEmpty ? null : Text(blurb, style: theme.textTheme.bodySmall),
      children: [
        for (final item in issue.items)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: AriaSpace.s3),
            title: Text(item.title.isEmpty ? '(untitled)' : item.title),
            subtitle: Text(
              [item.subtitle, item.detail].where((s) => s.isNotEmpty).join(' · '),
            ),
            // Every issue is actionable in the same place: the album page,
            // which owns re-identify and metadata edits.
            onTap: item.albumId.isEmpty
                ? null
                : () => pushInShell(context, '/album/${item.albumId}'),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(left: AriaSpace.s3, top: AriaSpace.s2),
            child: Text('…and $hidden more', style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}

class DuplicatesSection extends ConsumerWidget {
  const DuplicatesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dupes = ref.watch(duplicatesProvider);
    return dupes.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: AriaSpace.s3),
        child: LinearProgressIndicator(minHeight: 2),
      ),
      error: (e, _) => Text('Could not load duplicates.', style: theme.textTheme.bodySmall),
      data: (groups) {
        if (groups.isEmpty) {
          return Text('No duplicates found.', style: theme.textTheme.bodySmall);
        }
        return ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Duplicates · ${groups.length}'),
          subtitle: Text(
            'Identical audio, or the same recording through a different '
            'encoder. Listed only — nothing is deleted.',
            style: theme.textTheme.bodySmall,
          ),
          children: [
            for (final g in groups) DupeGroupTile(group: g),
          ],
        );
      },
    );
  }
}

class DupeGroupTile extends StatelessWidget {
  const DupeGroupTile({super.key, required this.group});

  final DuplicateGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = group.tracks.first;
    return Padding(
      padding: const EdgeInsets.only(left: AriaSpace.s3, bottom: AriaSpace.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${first.title} — ${group.exact ? 'identical audio' : 'same recording'}',
            style: theme.textTheme.labelMedium,
          ),
          for (final t in group.tracks)
            InkWell(
              onTap: t.albumId.isEmpty
                  ? null
                  : () => pushInShell(context, '/album/${t.albumId}'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AriaSpace.s1),
                child: Text(
                  '${t.album} · ${_quality(t)}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// What actually distinguishes two copies: the container plus the numbers a
  /// user would keep one over the other for.
  static String _quality(DuplicateTrack t) {
    final bits = [
      t.format.toUpperCase(),
      if (t.sampleRate != null) '${(t.sampleRate! / 1000).toStringAsFixed(1)} kHz',
      if (t.bitsPerSample != null) '${t.bitsPerSample}-bit',
      if (!t.lossless) 'lossy',
    ];
    return bits.join(' · ');
  }
}
