import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/phosphor_icons.dart';

import '../../core/formats.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../library/tracks_section.dart' show TrackTable;
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

    final body = switch (pls) {
      AsyncData(:final value) => _build(context, ref, _find(value, id), tracks),
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
  ) {
    if (pl == null) return const EmptyState(message: 'Playlist not found.');
    final list = tracksAsync.value;

    // Header above, then the library's Tracks table below it — same columns,
    // same sortable header, same rows. The table scrolls on its own, so the
    // page is a Column rather than the ListView it used to be.
    //
    // The header is capped and scrolls inside that cap: it is unshrinkable
    // (a Wrap of five buttons that gains rows as the window narrows), so on a
    // short window a plain Column overflows it instead of scrolling it, the
    // way the old ListView did.
    return LayoutBuilder(
      builder: (context, cons) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: cons.maxHeight * 0.6),
            child: SingleChildScrollView(
              child: Padding(
                // Flat s6, not ariaPagePadding: the table's columns are laid out on
                // a flat s6 too, and ariaPagePadding's centering inset would push
                // this header inboard of its own column header on a wide window.
                padding: const EdgeInsets.symmetric(horizontal: AriaSpace.s6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
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
                          icon: const Icon(PhosphorIconsFill.play, size: 18),
                          label: const Text('Play all'),
                          onPressed: list == null || list.isEmpty
                              ? null
                              : () => ref
                                    .read(queueProvider.notifier)
                                    .playQueue(list, 0),
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(
                            PhosphorIconsRegular.shuffle,
                            size: 16,
                          ),
                          label: const Text('Shuffle'),
                          onPressed: list == null || list.isEmpty
                              ? null
                              : () => ref
                                    .read(queueProvider.notifier)
                                    .playQueue(List.of(list)..shuffle(), 0),
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(
                            PhosphorIconsRegular.pencilSimple,
                            size: 16,
                          ),
                          label: const Text('Rename'),
                          onPressed: () => _rename(context, ref, pl),
                        ),
                        if (pl.isSmart)
                          OutlinedButton.icon(
                            icon: const Icon(
                              PhosphorIconsRegular.faders,
                              size: 16,
                            ),
                            label: const Text('Edit rules'),
                            onPressed: () =>
                                showSmartEditor(context, playlist: pl),
                          ),
                        OutlinedButton.icon(
                          icon: Icon(
                            PhosphorIconsRegular.x,
                            size: 16,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          label: Text(
                            'Delete',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          onPressed: () => _delete(context, ref, pl),
                        ),
                      ],
                    ),
                    const SizedBox(height: AriaSpace.s5),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: switch (tracksAsync) {
              AsyncData(:final value) => TrackTable(
                tracks: value,
                emptyMessage: pl.isSmart
                    ? 'No tracks match these rules.'
                    : 'Empty — pick "Add to playlist…" on any track to add '
                          'it here.',
                // Legacy trackCtx everywhere, plus this page's remove (which
                // drops ALL occurrences server-side).
                menuExtra: pl.isSmart
                    ? null
                    : (t) => [
                        AriaMenuItem(
                          'Remove from playlist',
                          () => ref
                              .read(playlistsProvider.notifier)
                              .removeTrack(pl.id, t.id),
                          icon: PhosphorIconsRegular.x,
                          destructive: true,
                        ),
                      ],
              ),
              AsyncError() => const EmptyState(
                message: 'Playlist unavailable.',
              ),
              _ => const Center(child: CircularProgressIndicator()),
            },
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
