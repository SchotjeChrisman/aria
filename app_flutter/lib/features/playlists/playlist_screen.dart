import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formats.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/selection_highlight.dart';
import '../../widgets/track_actions.dart';
import '../../widgets/track_row.dart';
import 'name_dialog.dart';
import 'playlists_screen.dart';
import 'providers.dart';
import 'smart_editor.dart';

/// Legacy renderPlaylist(): header + tools + track rows.
class PlaylistScreen extends ConsumerWidget {
  const PlaylistScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pls = ref.watch(playlistsProvider);
    final tracks = ref.watch(playlistTracksProvider(id));
    final currentId = ref.watch(currentTrackProvider)?.id;

    final body = switch (pls) {
      AsyncData(:final value) => _build(
        context,
        ref,
        _find(value, id),
        tracks,
        currentId,
      ),
      AsyncError() => const EmptyState(message: 'Playlist unavailable.'),
      _ => const Center(child: CircularProgressIndicator()),
    };
    return Scaffold(appBar: AppBar(), body: body);
  }

  static Playlist? _find(List<Playlist> pls, String id) {
    for (final p in pls) {
      if (p.id == id) return p;
    }
    return null;
  }

  Widget _build(
    BuildContext context,
    WidgetRef ref,
    Playlist? pl,
    AsyncValue<List<Track>> tracksAsync,
    String? currentId,
  ) {
    if (pl == null) return const EmptyState(message: 'Playlist not found.');
    final list = tracksAsync.value;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AriaSpace.s6,
        0,
        AriaSpace.s6,
        AriaSpace.s6,
      ),
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                pl.name,
                style: Theme.of(context).textTheme.titleLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (pl.isSmart) ...[
              const SizedBox(width: AriaSpace.s3),
              const SmartBadge(),
            ],
          ],
        ),
        if (list != null) ...[
          const SizedBox(height: AriaSpace.s2),
          Text(
            '${list.length} track${list.length == 1 ? '' : 's'} · '
            '${formatDuration(list.fold<double>(0, (s, t) => s + (t.duration ?? 0)))}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: AriaSpace.s4),
        Wrap(
          spacing: AriaSpace.s3,
          runSpacing: AriaSpace.s2,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Play all'),
              onPressed: list == null || list.isEmpty
                  ? null
                  : () => ref.read(queueProvider.notifier).playQueue(list, 0),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.shuffle, size: 16),
              label: const Text('Shuffle'),
              onPressed: list == null || list.isEmpty
                  ? null
                  : () => ref
                        .read(queueProvider.notifier)
                        .playQueue(List.of(list)..shuffle(), 0),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Rename'),
              onPressed: () => _rename(context, ref, pl),
            ),
            if (pl.isSmart)
              OutlinedButton.icon(
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('Edit rules'),
                onPressed: () => showSmartEditor(context, playlist: pl),
              ),
            OutlinedButton.icon(
              icon: Icon(
                Icons.close,
                size: 16,
                color: Theme.of(context).colorScheme.error,
              ),
              label: Text(
                'Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onPressed: () => _delete(context, ref, pl),
            ),
          ],
        ),
        const SizedBox(height: AriaSpace.s5),
        ...switch (tracksAsync) {
          AsyncData(:final value) when value.isEmpty => [
            EmptyState(
              message: pl.isSmart
                  ? 'No tracks match these rules.'
                  : 'Empty — pick "Add to playlist…" on any track to add '
                        'it here.',
            ),
          ],
          AsyncData(:final value) => [
            for (final (i, t) in value.indexed)
              _trackRow(context, ref, pl, value, i, t, currentId),
          ],
          AsyncError() => [const EmptyState(message: 'Playlist unavailable.')],
          _ => const [
            Padding(
              padding: EdgeInsets.all(AriaSpace.s10),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
        },
      ],
    );
  }

  Widget _trackRow(
    BuildContext context,
    WidgetRef ref,
    Playlist pl,
    List<Track> list,
    int i,
    Track t,
    String? currentId,
  ) {
    final row = TrackRow(
      number: i + 1,
      title: t.title ?? 'Unknown',
      subtitle: [
        t.artist,
        t.album,
      ].where((s) => s != null && s.isNotEmpty).join(' · '),
      duration: t.duration,
      format: t.format,
      bitsPerSample: t.bitsPerSample,
      sampleRate: t.sampleRate,
      lossless: t.lossless,
      isCurrent: t.id == currentId,
      onTap: () {
        if (selectionTapHandled(ref, trackSelectionItem(t))) return;
        ref.read(queueProvider.notifier).playQueue(list, i);
      },
      // Legacy trackCtx everywhere, plus this page's remove.
      onSecondary: (pos) => showAriaContextMenu(
        context,
        pos,
        trackMenuItems(
          context,
          ref,
          t,
          extra: [
            if (!pl.isSmart)
              AriaMenuItem(
                'Remove from playlist',
                () => ref
                    .read(playlistsProvider.notifier)
                    .removeTrack(pl.id, t.id),
                icon: Icons.close,
                destructive: true,
              ),
          ],
        ),
      ),
    );
    if (pl.isSmart) {
      return SelectionHighlight(kind: 'track', itemKey: t.id, child: row);
    }
    // Manual playlists get the legacy row ✕ (removes ALL occurrences
    // server-side). GAP: TrackRow has no trailing-action slot.
    return SelectionHighlight(
      kind: 'track',
      itemKey: t.id,
      child: Row(
        children: [
          Expanded(child: row),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'Remove from playlist',
            onPressed: () =>
                ref.read(playlistsProvider.notifier).removeTrack(pl.id, t.id),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, Playlist pl) async {
    final name = await promptName(
      context,
      title: 'Rename playlist',
      initial: pl.name,
      placeholder: 'Playlist name',
    );
    if (name == null) return;
    await ref.read(playlistsProvider.notifier).rename(pl.id, name);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Playlist pl) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete playlist "${pl.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(playlistsProvider.notifier).deletePlaylist(pl.id);
    if (context.mounted && context.canPop()) context.pop();
  }
}
