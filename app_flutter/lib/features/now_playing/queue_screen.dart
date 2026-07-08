import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/formats.dart';
import '../../core/player_providers.dart';
import '../../core/playlists_providers.dart';
import '../../core/theme.dart';
import '../../widgets/art_image.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/tag_picker.dart';
import '../../widgets/track_actions.dart';
import 'providers.dart';
import 'transport_bar.dart';

/// Play queue (legacy #queue-panel / renderQueue): played history dimmed
/// above the accented current row, drag handle to reorder (qMove semantics),
/// per-row remove (qRemove semantics), clear, save-as-playlist.
class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(queueProvider);
    final c = AriaColors.of(context);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: c.bg,
        elevation: 0,
        title: Text(
          q.tracks.isEmpty ? 'Queue' : 'Queue — ${q.tracks.length} tracks',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        actions: [
          if (q.tracks.isNotEmpty) ...[
            TextButton.icon(
              icon: const Icon(Icons.playlist_add, size: 18),
              label: const Text('Save as playlist'),
              onPressed: () => _saveAsPlaylist(context, ref),
            ),
            IconButton(
              icon: const Icon(Icons.clear_all),
              tooltip: 'Clear queue',
              onPressed: ref.read(queueProvider.notifier).clear,
            ),
          ],
          const SizedBox(width: AriaSpace.s2),
        ],
      ),
      body: q.tracks.isEmpty
          ? const EmptyState(
              message: 'Queue is empty.',
              icon: Icons.queue_music,
            )
          : ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.only(bottom: AriaSpace.s8),
              itemCount: q.tracks.length,
              // onReorderItem's newIndex is post-removal; core move() wants
              // the pre-move insertion index (legacy qMove dest semantics).
              onReorderItem: (oldIndex, newIndex) {
                final dest = newIndex > oldIndex ? newIndex + 1 : newIndex;
                ref.read(queueProvider.notifier).move([oldIndex], dest);
              },
              itemBuilder: (context, i) => _QueueRow(
                // Same track can be queued twice; the index keeps keys unique.
                key: ValueKey('q$i-${q.tracks[i].id}'),
                track: q.tracks[i],
                index: i,
                isCurrent: i == q.index,
                isPlayed: i < q.index,
              ),
            ),
      bottomNavigationBar: const TransportBar(),
    );
  }

  Future<void> _saveAsPlaylist(BuildContext context, WidgetRef ref) async {
    final tracks = ref.read(queueProvider).tracks;
    if (tracks.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);

    final ctrl = TextEditingController();
    final String? name;
    try {
      name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Save queue as playlist'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 60,
            decoration: const InputDecoration(hintText: 'Playlist name'),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(ctrl.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;

    try {
      // Core playlists notifier scopes to the reactive active profile —
      // switching profiles re-attributes new playlists immediately.
      final notifier = ref.read(playlistsProvider.notifier);
      final pl = await notifier.createManual(trimmed);
      await notifier.addTracks(pl.id, [for (final t in tracks) t.id]);
      messenger.showSnackBar(
        SnackBar(content: Text('Saved ${tracks.length} tracks to "$trimmed"')),
      );
    } on StateError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not save playlist.')),
      );
    }
  }
}

class _QueueRow extends ConsumerWidget {
  const _QueueRow({
    super.key,
    required this.track,
    required this.index,
    required this.isCurrent,
    required this.isPlayed,
  });

  final Track track;
  final int index;
  final bool isCurrent;
  final bool isPlayed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final notifier = ref.read(queueProvider.notifier);
    final fg = isCurrent ? c.accent : c.fg;
    final dim = isCurrent ? c.accent : c.fgDim;

    final row = Row(
      children: [
        ReorderableDragStartListener(
          index: index,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AriaSpace.s2),
            child: Icon(Icons.drag_indicator, size: 18, color: c.fgDim),
          ),
        ),
        ArtImage(
          url: ref.read(apiClientProvider).artUrl(track.albumId),
          fallbackText: track.album,
          size: 40,
          borderRadius: AriaRadius.sm,
        ),
        const SizedBox(width: AriaSpace.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${isCurrent ? '▶ ' : ''}${trackTitleLine(track)}',
                style: TextStyle(color: fg),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                trackSubLine(track),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall!.copyWith(color: dim),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: AriaSpace.s3),
        Text(
          formatDuration(track.duration),
          style: TextStyle(
            color: dim,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 16),
          color: c.fgDim,
          tooltip: 'Remove',
          onPressed: () => notifier.removeIndices([index]),
        ),
      ],
    );

    return GestureDetector(
      onSecondaryTapUp: (d) => _menu(context, ref, d.globalPosition),
      onLongPressStart: (d) => _menu(context, ref, d.globalPosition),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // Legacy dblclick-to-play; tap is the natural port with selection
          // handled by the context menu instead.
          onTap: () => notifier.playAt(index),
          hoverColor: c.bgHover,
          child: Opacity(
            opacity: isPlayed ? 0.55 : 1, // legacy .q-played
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AriaSpace.s2,
                vertical: 6,
              ),
              child: row,
            ),
          ),
        ),
      ),
    );
  }

  // Legacy queueCtx: Play now / Move next / Remove / Add to playlist / tag /
  // Go to album / Go to artist.
  void _menu(BuildContext context, WidgetRef ref, Offset pos) {
    final notifier = ref.read(queueProvider.notifier);
    showAriaContextMenu(context, pos, [
      AriaMenuItem(
        'Play now',
        () => notifier.playAt(index),
        icon: Icons.play_arrow,
      ),
      AriaMenuItem(
        'Move next',
        // legacy: insert right after the current track
        () => notifier.move([index], ref.read(queueProvider).index + 1),
        icon: Icons.queue_play_next,
      ),
      AriaMenuItem(
        'Add to playlist…',
        () => showAddToPlaylistMenu(context, tracks: [track]),
        icon: Icons.playlist_add_check,
      ),
      AriaMenuItem(
        'Tags…',
        () => showTagPicker(context, kind: 'track', key: track.id),
        icon: Icons.sell_outlined,
      ),
      AriaMenuItem(
        'Go to album',
        // go, not push: see now_playing_screen — this screen is above the
        // shell, the destinations are inside shell branches.
        () => context.go(albumPath(track.albumId)),
        icon: Icons.album_outlined,
      ),
      if ((track.artist ?? '').isNotEmpty)
        AriaMenuItem(
          'Go to artist',
          () => context.go(artistPath(track.artist!)),
          icon: Icons.person_outline,
        ),
      AriaMenuItem(
        'Remove from queue',
        () => notifier.removeIndices([index]),
        icon: Icons.close,
        destructive: true,
      ),
    ]);
  }
}
