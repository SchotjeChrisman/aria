import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/theme.dart';
import 'library_providers.dart';
import 'person_card.dart';

/// Genre tile (legacy genreCard()): 2×2 art mosaic from the genre's albums,
/// artist/album counts, tap-through pills for library-present child genres.
class GenreCard extends ConsumerWidget {
  const GenreCard({super.key, required this.genre});

  final String genre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final api = ref.watch(apiClientProvider);
    final idx = ref.watch(genreIndexProvider);
    final parents = ref.watch(genreParentsProvider);

    final scope = genreScope(genre, parents, idx);
    final albumIds = {for (final g in scope) ...idx[g]!.albumIds}.toList();
    final artistCount = {for (final g in scope) ...idx[g]!.artistNames}.length;
    final kids = genreChildren(parents, genre).where(idx.containsKey).toList();

    Widget cell(int i) {
      if (i >= albumIds.length) return ColoredBox(color: c.bgHover);
      return Image.network(
        api.artUrl(albumIds[i]),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => ColoredBox(color: c.bgHover),
      );
    }

    return GestureDetector(
      onTap: () => context.push('/library/genres/${Uri.encodeComponent(genre)}'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AriaRadius.md),
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(child: cell(0)),
                          const SizedBox(width: 2),
                          Expanded(child: cell(1)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(child: cell(2)),
                          const SizedBox(width: 2),
                          Expanded(child: cell(3)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              genre,
              style: const TextStyle(fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${countLabel(artistCount, 'artist')} · ${countLabel(albumIds.length, 'album')}',
              style: TextStyle(fontSize: 12.5, height: 1.45, color: c.fgDim),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (kids.isNotEmpty) ...[
              const SizedBox(height: AriaSpace.s1),
              SizedBox(
                height: 26,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: kids.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: AriaSpace.s1),
                  itemBuilder: (_, i) => GenrePill(genre: kids[i]),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Small tap-through pill for a child genre (legacy .genre-pill).
class GenrePill extends StatelessWidget {
  const GenrePill({super.key, required this.genre});

  final String genre;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return GestureDetector(
      onTap: () => context.push('/library/genres/${Uri.encodeComponent(genre)}'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: c.line),
          borderRadius: BorderRadius.circular(AriaRadius.pill),
        ),
        child: Text(genre, style: TextStyle(fontSize: 11.5, color: c.fgDim)),
      ),
    );
  }
}
