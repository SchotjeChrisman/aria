import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../widgets/empty_state.dart';
import 'albums_section.dart';
import 'artists_section.dart';
import 'composers_section.dart';
import 'genres_section.dart';
import 'library_providers.dart';
import 'tracks_section.dart';

/// Each section is its own page/route (like the legacy sidebar).
/// [LibraryHubScreen] fronts them on narrow layouts.
enum LibrarySection {
  albums('Albums', Icons.album_outlined, Icons.album),
  artists('Artists', Icons.person_outline, Icons.person),
  tracks('Tracks', Icons.music_note_outlined, Icons.music_note),
  genres('Genres', Icons.category_outlined, Icons.category),
  composers('Composers', Icons.piano_outlined, Icons.piano);

  const LibrarySection(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  String get path => '/library/$name';
}

/// Mobile front page linking to the per-section library pages.
class LibraryHubScreen extends StatelessWidget {
  const LibraryHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(AriaSpace.s6),
              child: Text(
                'Library',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            for (final s in LibrarySection.values)
              ListTile(
                leading: Icon(s.icon),
                title: Text(s.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go(s.path),
              ),
          ],
        ),
      ),
    );
  }
}

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key, required this.section});

  final LibrarySection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tracksProvider);
    ref.watch(queueRestoreProvider);
    return Scaffold(
      body: SafeArea(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => EmptyState(
            message: 'Cannot reach the server — check Settings.',
            icon: Icons.cloud_off,
            action: OutlinedButton(
              onPressed: () => ref.invalidate(tracksProvider),
              child: const Text('Retry'),
            ),
          ),
          data: (tracks) {
            if (tracks.isEmpty) {
              return EmptyState(
                message: 'The library is empty — scan it from Settings.',
                icon: Icons.library_music_outlined,
                action: OutlinedButton(
                  onPressed: () => ref.invalidate(tracksProvider),
                  child: const Text('Refresh'),
                ),
              );
            }
            return _LibraryBody(section: section);
          },
        ),
      ),
    );
  }
}

class _LibraryBody extends ConsumerWidget {
  const _LibraryBody({required this.section});

  final LibrarySection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackCount = ref.watch(loadedTracksProvider).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: ariaPagePadding(context, top: AriaSpace.s6, bottom: 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                section.label,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(width: AriaSpace.s3),
              // legacy #lib-count
              Text(
                '$trackCount tracks',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: AriaSpace.s4),
        Expanded(
          child: switch (section) {
            LibrarySection.albums => const AlbumsSection(),
            LibrarySection.artists => const ArtistsSection(),
            LibrarySection.tracks => const TracksSection(),
            LibrarySection.genres => const GenresSection(),
            LibrarySection.composers => const ComposersSection(),
          },
        ),
      ],
    );
  }
}
