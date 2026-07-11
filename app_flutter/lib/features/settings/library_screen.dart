import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/theme.dart';
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
        children: const [_LibraryTools()],
      ),
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
              icon: const Icon(Icons.refresh, size: 18),
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
              icon: const Icon(Icons.auto_awesome, size: 18),
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
