import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import 'library_providers.dart';
import 'person_card.dart';

/// Dedicated cover art for a genre: a deep duotone gradient in the genre's
/// hue family with an oversized icon bleeding off the corner. Every genre
/// gets consistent, intentional art regardless of how many albums it holds;
/// unmapped genres fall back to a hue derived from the name.
class GenreArt extends StatelessWidget {
  const GenreArt({super.key, required this.genre});

  final String genre;

  static const _art = <String, (Color, Color, IconData)>{
    'Blues': (Color(0xFF2C3E6B), Color(0xFF141B38), Icons.nightlife),
    'Rock': (Color(0xFF6B2A2A), Color(0xFF2A1215), Icons.graphic_eq),
    'Pop': (Color(0xFF7A2E6E), Color(0xFF32173F), Icons.auto_awesome),
    'Classical': (Color(0xFF7A5A2E), Color(0xFF32250F), Icons.piano),
    'Jazz': (Color(0xFF8A6A2F), Color(0xFF1E2E2E), Icons.mic_external_on),
    'Soul/R&B': (Color(0xFF6E2E52), Color(0xFF2A1230), Icons.favorite),
    'Country': (Color(0xFF7A452A), Color(0xFF2E2415), Icons.landscape),
    'Folk': (Color(0xFF3E5A34), Color(0xFF16241A), Icons.forest),
    'Metal': (Color(0xFF48505E), Color(0xFF16181E), Icons.bolt),
    'Christian & Gospel': (Color(0xFF8A7038), Color(0xFF1E2440), Icons.church),
    'Electronic': (Color(0xFF1F6E7A), Color(0xFF101C38), Icons.equalizer),
    'Hip-Hop': (Color(0xFF9A5A20), Color(0xFF201612), Icons.headphones),
    'Reggae': (Color(0xFF2E5A28), Color(0xFF6B5A16), Icons.wb_sunny),
    'Latin': (Color(0xFF9A3A2E), Color(0xFF5A1430), Icons.celebration),
    'World': (Color(0xFF2E6E5A), Color(0xFF4A3A20), Icons.public),
    'New Age': (Color(0xFF5A4A8A), Color(0xFF1E3238), Icons.spa),
    'Easy Listening': (Color(0xFF6E4A5A), Color(0xFF241820), Icons.radio),
    'Stage & Screen': (
      Color(0xFF6E1E2E),
      Color(0xFF140A10),
      Icons.theater_comedy,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final (top, bottom, icon) =
        _art[genre] ??
        () {
          // ponytail: unmapped genre -> stable hue from the name
          final hue = (genre.hashCode % 360).toDouble().abs();
          return (
            HSLColor.fromAHSL(1, hue, 0.42, 0.30).toColor(),
            HSLColor.fromAHSL(1, hue, 0.42, 0.14).toColor(),
            Icons.music_note,
          );
        }();

    return ClipRRect(
      borderRadius: BorderRadius.circular(AriaRadius.md),
      child: LayoutBuilder(
        builder: (_, box) => DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [top, bottom],
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            fit: StackFit.expand,
            children: [
              Positioned(
                right: -box.maxWidth * 0.18,
                bottom: -box.maxWidth * 0.20,
                child: Icon(
                  icon,
                  size: box.maxWidth * 0.85,
                  color: Colors.white.withValues(alpha: 0.12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Genre tile (legacy genreCard()): dedicated genre art, artist/album counts,
/// tap-through pills for library-present child genres.
class GenreCard extends ConsumerWidget {
  const GenreCard({super.key, required this.genre});

  final String genre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final idx = ref.watch(genreIndexProvider);
    final parents = ref.watch(genreParentsProvider);

    final scope = genreScope(genre, parents, idx);
    final albumIds = {for (final g in scope) ...idx[g]!.albumIds}.toList();
    final artistCount = {for (final g in scope) ...idx[g]!.artistNames}.length;
    final kids = genreChildren(parents, genre).where(idx.containsKey).toList();

    return GestureDetector(
      onTap: () => context.push('/library/genres/${Uri.encodeComponent(genre)}'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: GenreArt(genre: genre)),
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
