import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/library_providers.dart';
import '../../core/theme.dart';
import '../../widgets/art_image.dart';
import '../../widgets/empty_state.dart';
import 'name_dialog.dart';
import 'providers.dart';
import 'smart_editor.dart';

/// Legacy renderPlaylists(): create buttons + a grid of playlist tiles, each
/// fronted by a collage of album art from its tracks.
class PlaylistsScreen extends ConsumerWidget {
  const PlaylistsScreen({super.key});

  Future<void> _newManual(BuildContext context, WidgetRef ref) async {
    final name = await promptName(
      context,
      title: 'New playlist',
      placeholder: 'Playlist name',
    );
    if (name == null) return;
    try {
      await ref.read(playlistsProvider.notifier).createManual(name);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is AriaApiException ? e.message : 'Could not create playlist.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pls = ref.watch(playlistsProvider);
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(AriaSpace.s6),
        children: [
          Text('Playlists', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AriaSpace.s4),
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Playlist'),
                onPressed: () => _newManual(context, ref),
              ),
              const SizedBox(width: AriaSpace.s3),
              OutlinedButton.icon(
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Smart playlist'),
                onPressed: () => showSmartEditor(context),
              ),
            ],
          ),
          const SizedBox(height: AriaSpace.s5),
          switch (pls) {
            AsyncData(:final value) when value.isEmpty => const EmptyState(
              message:
                  'No playlists yet — make one, or pick "Add to playlist…" '
                  'on any track.',
            ),
            AsyncData(:final value) => GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: AriaBreakpoint.of(context).gridColumns,
                mainAxisSpacing: AriaSpace.s5,
                crossAxisSpacing: AriaSpace.s5,
                // Tablet-floor tiles (~103px at a 600px window) need a
                // taller cell: the ~49px text block under the square art
                // doesn't shrink with the tile.
                childAspectRatio:
                    AriaBreakpoint.of(context) == AriaBreakpoint.tablet
                    ? 0.67
                    : 0.72,
              ),
              itemCount: value.length,
              itemBuilder: (context, i) => _PlaylistTile(playlist: value[i]),
            ),
            AsyncError() => const EmptyState(message: 'Playlists unavailable.'),
            _ => const Padding(
              padding: EdgeInsets.all(AriaSpace.s10),
              child: Center(child: CircularProgressIndicator()),
            ),
          },
        ],
      ),
    );
  }
}

/// Grid tile: 2×2 album-art collage (fewer arts fall back to one image or a
/// placeholder icon), name + count/SMART underneath.
class _PlaylistTile extends ConsumerWidget {
  const _PlaylistTile({required this.playlist});

  final Playlist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final n = playlist.trackIds?.length ?? 0;

    // Distinct album arts, in playlist order, from the loaded library.
    final byId = ref.watch(trackByIdProvider);
    final api = ref.read(apiClientProvider);
    final albumIds = <String>{};
    for (final id in playlist.trackIds ?? const <String>[]) {
      final t = byId[id];
      if (t != null) albumIds.add(t.albumId);
      if (albumIds.length == 4) break;
    }
    final urls = [for (final a in albumIds) api.artUrl(a)];

    final Widget art;
    if (urls.length >= 4) {
      art = Column(
        children: [
          for (var row = 0; row < 2; row++)
            Expanded(
              child: Row(
                children: [
                  for (var col = 0; col < 2; col++)
                    Expanded(
                      child: ArtImage(
                        url: urls[row * 2 + col],
                        // Quarter of a ~190px grid tile.
                        decodeSize: 95,
                        borderRadius: 0,
                      ),
                    ),
                ],
              ),
            ),
        ],
      );
    } else if (urls.isNotEmpty) {
      art = ArtImage(url: urls.first, decodeSize: 190, borderRadius: 0);
    } else {
      art = Container(
        color: c.bgRaised,
        child: Icon(
          playlist.isSmart ? Icons.auto_awesome : Icons.queue_music,
          size: 36,
          color: c.fgDim,
        ),
      );
    }

    return InkWell(
      onTap: () => context.push('/playlists/${playlist.id}'),
      borderRadius: BorderRadius.circular(AriaRadius.md),
      hoverColor: c.bgHover,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AriaRadius.md),
              child: art,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            playlist.name,
            style: const TextStyle(fontWeight: FontWeight.w500),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (playlist.isSmart)
            const Padding(padding: EdgeInsets.only(top: 2), child: SmartBadge())
          else
            Text(
              '$n track${n == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

/// Legacy .pl-badge: small accent "SMART" pill.
class SmartBadge extends StatelessWidget {
  const SmartBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c.lineStrong),
        borderRadius: BorderRadius.circular(AriaRadius.pill),
      ),
      child: Text(
        'SMART',
        style: TextStyle(fontSize: 10, letterSpacing: 1.2, color: c.fgDim),
      ),
    );
  }
}
