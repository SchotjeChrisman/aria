import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/downloads.dart';
import '../../core/formats.dart';
import '../../core/library_providers.dart';
import '../../core/theme.dart';

/// Storage management for offline downloads: total size, the in-flight
/// download with progress, and the downloaded tracks with per-item remove.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dl = ref.watch(downloadsProvider);
    final byId = ref.watch(trackByIdProvider);
    final totalBytes = dl.index.values.fold<int>(0, (s, e) => s + e.bytes);

    // Stable order: album, then title, unknown tracks last by id.
    final ids = dl.index.keys.toList()
      ..sort((a, b) {
        final ta = byId[a], tb = byId[b];
        final k = (ta?.album ?? '￿').compareTo(tb?.album ?? '￿');
        return k != 0
            ? k
            : (ta?.title ?? a).compareTo(tb?.title ?? b);
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          if (dl.index.isNotEmpty || dl.queue.isNotEmpty)
            TextButton(
              onPressed: () =>
                  ref.read(downloadsProvider.notifier).removeAll(),
              child: const Text('Remove all'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AriaSpace.s4, AriaSpace.s4,
            AriaSpace.s4, AriaSpace.s4 + transportFloatInset),
        children: [
          Text(
            '${dl.index.length} track${dl.index.length == 1 ? '' : 's'} · '
            '${formatBytes(totalBytes)}'
            '${dl.queue.isEmpty ? '' : ' · ${dl.queue.length} queued'}',
            style: theme.textTheme.bodySmall,
          ),
          if (dl.active != null) ...[
            const SizedBox(height: AriaSpace.s4),
            Text(
              'Downloading ${byId[dl.active!]?.title ?? dl.active}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AriaSpace.s2),
            LinearProgressIndicator(value: dl.progress, minHeight: 4),
          ],
          const SizedBox(height: AriaSpace.s3),
          if (dl.index.isEmpty && dl.active == null)
            Padding(
              padding: const EdgeInsets.only(top: AriaSpace.s6),
              child: Text(
                'Nothing downloaded yet — use "Download" in a track or '
                'album menu.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          for (final id in ids) _row(context, ref, id, byId[id], dl.index[id]!),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    WidgetRef ref,
    String id,
    Track? t,
    DownloadEntry e,
  ) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        t?.title ?? id,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if ((t?.artist ?? '').isNotEmpty) t!.artist!,
          if ((t?.album ?? '').isNotEmpty) t!.album!,
          formatBytes(e.bytes),
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 18),
        tooltip: 'Remove download',
        onPressed: () => ref.read(downloadsProvider.notifier).remove(id),
      ),
    );
  }
}
