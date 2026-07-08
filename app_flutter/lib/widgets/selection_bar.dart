import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/player_providers.dart';
import '../core/selection.dart';
import '../core/theme.dart';
import 'tag_picker.dart';
import 'track_actions.dart';

/// Legacy #select-bar: appears while multi-select is active (context menu
/// "Select…"), gathering items across views; bulk Play / Play next / Add to
/// queue / Tag all / Add all to playlist / Done. Mounted by the shell above
/// the transport bar.
class SelectionBar extends ConsumerWidget {
  const SelectionBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sel = ref.watch(selectionProvider);
    if (!sel.active) return const SizedBox.shrink();
    final c = AriaColors.of(context);
    final notifier = ref.read(selectionProvider.notifier);
    final queue = ref.read(queueProvider.notifier);

    // Legacy act(): run on the gathered tracks, then leave select mode.
    void act(void Function(List<Track> ts) fn) {
      final ts = sel.tracks;
      if (ts.isEmpty) return;
      fn(ts);
      notifier.exit();
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AriaSpace.s4,
        vertical: AriaSpace.s1,
      ),
      decoration: BoxDecoration(
        color: c.bgRaised,
        border: Border(top: BorderSide(color: c.accent)),
      ),
      child: Row(
        children: [
          Text(
            '${sel.items.length} selected',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: c.accent),
          ),
          const SizedBox(width: AriaSpace.s3),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => act((ts) => queue.playQueue(ts, 0)),
                    child: const Text('Play'),
                  ),
                  TextButton(
                    onPressed: () => act(queue.queueNext),
                    child: const Text('Play next'),
                  ),
                  TextButton(
                    onPressed: () => act(queue.queueAdd),
                    child: const Text('Add to queue'),
                  ),
                  TextButton(
                    onPressed: sel.items.isEmpty
                        ? null
                        : () => showBulkTagMenu(context, items: sel.tagItems),
                    child: const Text('Tag all…'),
                  ),
                  TextButton(
                    onPressed: sel.items.isEmpty
                        ? null
                        : () => showAddToPlaylistMenu(
                            context,
                            tracks: sel.tracks,
                          ),
                    child: const Text('Add to playlist…'),
                  ),
                ],
              ),
            ),
          ),
          TextButton(onPressed: notifier.exit, child: const Text('Done')),
        ],
      ),
    );
  }
}
