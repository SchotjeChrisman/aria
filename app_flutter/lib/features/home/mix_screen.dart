import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/downloads.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/track_actions.dart';
import '../../widgets/track_row.dart';
import 'mixes.dart';

/// A single home mix: title, Play all, and the ranked track list. Mirrors
/// PlaylistScreen's layout, reusing TrackRow.
class MixScreen extends ConsumerWidget {
  const MixScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mixesProvider);
    final currentId = ref.watch(currentTrackProvider)?.id;

    final body = switch (async) {
      AsyncError() => const EmptyState(message: 'Mixes unavailable.'),
      AsyncData() => _build(context, ref, homeMixById(ref, id), currentId),
      _ => const Center(child: CircularProgressIndicator()),
    };
    final tracks = switch (async) {
      AsyncData() => homeMixById(ref, id)?.tracks ?? const <Track>[],
      _ => const <Track>[],
    };
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: 'Save as playlist',
            onPressed: tracks.isEmpty
                ? null
                : () => showAddToPlaylistMenu(context, tracks: tracks),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _build(
    BuildContext context,
    WidgetRef ref,
    HomeMix? mix,
    String? currentId,
  ) {
    if (mix == null) return const EmptyState(message: 'Mix not found.');
    final list = mix.tracks;

    return ListView(
      padding: ariaPagePadding(context, top: 0),
      children: [
        Text(mix.title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AriaSpace.s2),
        Text(mix.subtitle, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AriaSpace.s4),
        Row(
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Play all'),
              onPressed: list.isEmpty
                  ? null
                  : () => ref.read(queueProvider.notifier).playQueue(list, 0),
            ),
            const SizedBox(width: AriaSpace.s2),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.shuffle, size: 18),
              label: const Text('Shuffle'),
              onPressed: list.isEmpty
                  ? null
                  : () => ref.read(queueProvider.notifier).playQueue(
                        List.of(list)..shuffle(),
                        0,
                      ),
            ),
          ],
        ),
        const SizedBox(height: AriaSpace.s5),
        if (list.isEmpty)
          const EmptyState(message: 'This mix is empty.')
        else
          for (final (i, t) in list.indexed)
            _row(context, ref, list, i, t, currentId),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    WidgetRef ref,
    List<Track> list,
    int i,
    Track t,
    String? currentId,
  ) {
    return TrackRow(
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
      downloaded: ref.watch(
        downloadsProvider.select((s) => s.index.containsKey(t.id)),
      ),
      isCurrent: t.id == currentId,
      onTap: () => ref.read(queueProvider.notifier).playQueue(list, i),
      onSecondary: (pos) =>
          showAriaContextMenu(context, pos, trackMenuItems(context, ref, t)),
    );
  }
}
