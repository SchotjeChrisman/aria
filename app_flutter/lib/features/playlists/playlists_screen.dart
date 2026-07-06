import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../widgets/empty_state.dart';
import 'name_dialog.dart';
import 'providers.dart';
import 'smart_editor.dart';

/// Legacy renderPlaylists(): list + create buttons.
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
          const SizedBox(height: AriaSpace.s4),
          switch (pls) {
            AsyncData(:final value) when value.isEmpty => const EmptyState(
              message:
                  'No playlists yet — make one, or pick "Add to playlist…" '
                  'on any track.',
            ),
            AsyncData(:final value) => Column(
              children: [for (final pl in value) _PlaylistRow(playlist: pl)],
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

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({required this.playlist});

  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final n = playlist.trackIds?.length ?? 0;
    return InkWell(
      onTap: () => context.push('/playlists/${playlist.id}'),
      borderRadius: BorderRadius.circular(AriaRadius.md),
      hoverColor: c.bgHover,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AriaSpace.s3,
          vertical: AriaSpace.s3,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (playlist.isSmart)
              const SmartBadge()
            else
              Text(
                '$n track${n == 1 ? '' : 's'}',
                style: TextStyle(color: c.fgDim, fontSize: 12.5),
              ),
          ],
        ),
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
        border: Border.all(color: c.accent),
        borderRadius: BorderRadius.circular(AriaRadius.pill),
      ),
      child: Text(
        'SMART',
        style: TextStyle(fontSize: 10, letterSpacing: 1.2, color: c.accent),
      ),
    );
  }
}
