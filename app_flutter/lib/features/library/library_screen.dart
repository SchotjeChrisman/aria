import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filter_bar.dart';
import 'albums_section.dart';
import 'artists_section.dart';
import 'composers_section.dart';
import 'genres_section.dart';
import 'library_providers.dart';
import 'tracks_section.dart';

/// Legacy nav split Albums/Artists/Tracks/Genres/Composers into separate
/// sidebar views; here they are sections of the one Library tab.
enum LibrarySection {
  albums('Albums'),
  artists('Artists'),
  tracks('Tracks'),
  genres('Genres'),
  composers('Composers');

  const LibrarySection(this.label);
  final String label;
}

class LibrarySectionNotifier extends Notifier<LibrarySection> {
  @override
  LibrarySection build() => LibrarySection.albums;

  void set(LibrarySection s) => state = s;
}

final librarySectionProvider =
    NotifierProvider<LibrarySectionNotifier, LibrarySection>(
      LibrarySectionNotifier.new,
    );

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

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
            return const _LibraryBody();
          },
        ),
      ),
    );
  }
}

class _LibraryBody extends ConsumerWidget {
  const _LibraryBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final section = ref.watch(librarySectionProvider);
    final trackCount = ref.watch(loadedTracksProvider).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AriaSpace.s6,
            AriaSpace.s6,
            AriaSpace.s6,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
                    style: TextStyle(fontSize: 12.5, color: c.fgDim),
                  ),
                ],
              ),
              const SizedBox(height: AriaSpace.s4),
              FilterBar(
                children: [
                  for (final s in LibrarySection.values)
                    FilterPill(
                      label: s.label,
                      selected: s == section,
                      onTap: () =>
                          ref.read(librarySectionProvider.notifier).set(s),
                    ),
                ],
              ),
            ],
          ),
        ),
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
