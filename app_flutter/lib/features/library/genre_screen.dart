import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/theme.dart';
import '../../widgets/album_card.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/shelf.dart';
import '../../widgets/track_actions.dart';
import 'genre_card.dart';
import 'library_providers.dart';
import 'person_card.dart';

/// One genre page (legacy renderGenre): parent crumb, child pills, artists
/// shelf ordered by track count in the genre, albums newest first.
class GenreScreen extends ConsumerWidget {
  const GenreScreen({super.key, required this.genre});

  final String genre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tracksProvider);
    return Scaffold(
      body: SafeArea(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => const EmptyState(
            message: 'Cannot reach the server.',
            icon: Icons.cloud_off,
          ),
          data: (_) => _GenreBody(genre: genre),
        ),
      ),
    );
  }
}

class _GenreBody extends ConsumerWidget {
  const _GenreBody({required this.genre});

  final String genre;

  void _back(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/library');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final api = ref.watch(apiClientProvider);
    final idx = ref.watch(genreIndexProvider);
    final parents = ref.watch(genreParentsProvider);
    final albumById = ref.watch(albumByIdProvider);
    final people = ref.watch(peopleProvider).value ?? const <String, String>{};

    final scope = genreScope(genre, parents, idx);
    final trs = [for (final g in scope) ...idx[g]!.tracks];

    final backRow = Align(
      alignment: Alignment.centerLeft,
      child: IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: 'Back',
        onPressed: () => _back(context),
      ),
    );

    if (trs.isEmpty) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AriaSpace.s4,
              AriaSpace.s4,
              AriaSpace.s4,
              0,
            ),
            child: backRow,
          ),
          const Expanded(
            child: EmptyState(
              message: 'Nothing in this genre.',
              icon: Icons.category_outlined,
            ),
          ),
        ],
      );
    }

    final parent = parents[genre];
    final kids = genreChildren(parents, genre).where(idx.containsKey).toList();

    final albumIds = LinkedHashSet<String>.from(trs.map((t) => t.albumId));
    final perArtist = <String, int>{};
    for (final t in trs) {
      final n = displayArtist(t);
      perArtist[n] = (perArtist[n] ?? 0) + 1;
    }
    final artistNames = perArtist.keys.toList()
      ..sort((a, b) => perArtist[b]! - perArtist[a]!);
    final albums = [
      for (final id in albumIds)
        if (albumById[id] != null) albumById[id]!,
    ]..sort((x, y) => (y.year ?? 0) - (x.year ?? 0));

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AriaSpace.s6,
              AriaSpace.s4,
              AriaSpace.s6,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                backRow,
                if (parent != null)
                  GestureDetector(
                    onTap: () => context.push(
                      '/library/genre/${Uri.encodeComponent(parent)}',
                    ),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Text(
                        '$parent ›',
                        style: TextStyle(fontSize: 12.5, color: c.fgDim),
                      ),
                    ),
                  ),
                Text(genre, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: AriaSpace.s1),
                Text(
                  '${countLabel(artistNames.length, 'artist')} · '
                  '${countLabel(albumIds.length, 'album')} · '
                  '${countLabel(trs.length, 'track')}',
                  style: TextStyle(fontSize: 12.5, color: c.fgDim),
                ),
                if (kids.isNotEmpty) ...[
                  const SizedBox(height: AriaSpace.s3),
                  Wrap(
                    spacing: AriaSpace.s2,
                    runSpacing: AriaSpace.s2,
                    children: [for (final k in kids) GenrePill(genre: k)],
                  ),
                ],
                const SizedBox(height: AriaSpace.s6),
                if (artistNames.isNotEmpty) ...[
                  Shelf(
                    title: 'Artists',
                    height: 208,
                    itemWidth: 150,
                    itemCount: artistNames.length,
                    itemBuilder: (context, i) {
                      final n = artistNames[i];
                      return PersonCard(
                        name: n,
                        imageUrl: people[n],
                        onTap: () =>
                            context.push('/artist/${Uri.encodeComponent(n)}'),
                      );
                    },
                  ),
                  const SizedBox(height: AriaSpace.s6),
                ],
                Text('Albums', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AriaSpace.s3),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AriaSpace.s6,
            0,
            AriaSpace.s6,
            AriaSpace.s6,
          ),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 190,
              mainAxisSpacing: AriaSpace.s5,
              crossAxisSpacing: AriaSpace.s5,
              childAspectRatio: 0.72,
            ),
            itemCount: albums.length,
            itemBuilder: (context, i) {
              final a = albums[i];
              return AlbumCard(
                title: a.title,
                subtitle: a.year != null
                    ? '${a.albumArtist} · ${a.year}'
                    : a.albumArtist,
                artUrl: a.hasArt ? api.artUrl(a.id) : null,
                onTap: () {
                  if (selectionTapHandled(
                    ref,
                    albumSelectionItem(a.id, a.tracks),
                  )) {
                    return;
                  }
                  context.push('/album/${a.id}');
                },
                onSecondary: (pos) => showAriaContextMenu(
                  context,
                  pos,
                  albumMenuItems(
                    context,
                    ref,
                    albumId: a.id,
                    tracks: a.tracks,
                    artistName: a.albumArtist,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
