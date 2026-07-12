import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/phosphor_icons.dart';

import '../../core/theme.dart';
import '../../widgets/empty_state.dart';
import 'genre_card.dart';
import 'library_providers.dart';

/// Genres browse (legacy renderGenres): every genre rolled up to its
/// top-level parent, biggest first.
class GenresSection extends ConsumerWidget {
  const GenresSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final idx = ref.watch(genreIndexProvider);
    final parents = ref.watch(genreParentsProvider);

    if (idx.isEmpty) {
      return const EmptyState(
        message: 'No genres in the library.',
        icon: PhosphorIconsRegular.squaresFour,
      );
    }

    final tops = <String>{};
    for (final g0 in idx.keys) {
      var g = g0;
      final seen = <String>{g};
      while (true) {
        final p = parents[g];
        if (p == null || !seen.add(p)) break;
        g = p;
      }
      tops.add(g);
    }
    int size(String g) => genreScope(
      g,
      parents,
      idx,
    ).fold(0, (s, x) => s + idx[x]!.tracks.length);
    final list = tops.toList()..sort((a, b) => size(b) - size(a));

    return GridView.builder(
      padding: ariaPagePadding(context, top: AriaSpace.s4),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        // Genre cards are wider than album tiles (legacy 260px extent), so
        // they get their own band counts instead of the shared 2/4/6.
        crossAxisCount: switch (AriaBreakpoint.of(context)) {
          AriaBreakpoint.mobile => 2,
          AriaBreakpoint.tablet => 3,
          AriaBreakpoint.desktop => 5,
        },
        mainAxisSpacing: AriaSpace.s5,
        crossAxisSpacing: AriaSpace.s5,
        childAspectRatio: 0.78,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) => GenreCard(genre: list[i]),
    );
  }
}
