import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/phosphor_icons.dart';

import '../../core/connection.dart';
import '../../core/theme.dart';
import '../review/providers.dart';
import 'settings_providers.dart';

/// Library maintenance: rescan and metadata enrichment.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      body: ListView(
        padding: ariaPagePadding(context),
        children: const [_LibraryTools(), _HealthTile(), _ReviewTile()],
      ),
    );
  }
}

/// Entry to the diagnostics; the report itself is /settings/health.
///
/// The count is the point. This tile said only "Library health" for a release
/// and the owner of the library never found out the page existed; a tile that
/// states how many things are wrong advertises itself.
class _HealthTile extends ConsumerWidget {
  const _HealthTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final issues = ref.watch(healthProvider).value?.issues
        .fold<int>(0, (a, i) => a + i.count);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Library health'),
      subtitle: const Text(
        'Unidentified albums, missing artwork, suspect files, duplicates',
      ),
      trailing: (issues == null || issues == 0)
          ? null
          : Text('$issues', style: Theme.of(context).textTheme.labelMedium),
      onTap: () => context.push('/settings/health'),
    );
  }
}

/// The other half: health says what is wrong, this is where identity gets
/// resolved. Counts only the albums still awaiting an answer.
class _ReviewTile extends ConsumerWidget {
  const _ReviewTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(reviewCountProvider);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Match review'),
      subtitle: const Text(
        'Albums the matcher could not identify on its own',
      ),
      trailing: n == 0
          ? null
          : Text('$n', style: Theme.of(context).textTheme.labelMedium),
      onTap: () => context.push('/settings/review'),
    );
  }
}

class _LibraryTools extends ConsumerWidget {
  const _LibraryTools();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(scanControllerProvider);
    final enrich = ref.watch(enrichStatusProvider).value;
    final theme = Theme.of(context);

    final enrichBusy = enrich != null && enrich.phase != 'idle';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: scan.running
                  ? null
                  : () => ref.read(scanControllerProvider.notifier).start(),
              icon: const Icon(PhosphorIconsRegular.arrowClockwise, size: 18),
              label: Text(scan.running ? 'Scanning…' : 'Rescan library'),
            ),
            const SizedBox(width: AriaSpace.s3),
            if (scan.running)
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: scan.total > 0 ? scan.done / scan.total : null,
                        minHeight: 4,
                      ),
                    ),
                    const SizedBox(width: AriaSpace.s2),
                    Text(
                      scan.total > 0 ? '${scan.done}/${scan.total}' : '…',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              )
            else if (scan.error != null)
              Expanded(
                child: Text(
                  'Scan failed.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              )
            else if (scan.lastTracks != null)
              Text(
                '${scan.lastTracks} tracks.',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
        const SizedBox(height: AriaSpace.s3),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: enrichBusy
                  ? null
                  : () async {
                      try {
                        await ref.read(apiClientProvider).kickEnrich();
                      } catch (_) {
                        /* status poll shows reality */
                      }
                    },
              icon: const Icon(PhosphorIconsRegular.sparkle, size: 18),
              label: const Text('Enrich metadata'),
            ),
            const SizedBox(width: AriaSpace.s3),
            Text(
              enrichBusy
                  ? '✨ ${enrich.phase} ${enrich.done}/${enrich.total}'
                  : 'Enrichment idle.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }
}
