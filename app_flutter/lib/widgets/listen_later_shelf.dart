import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/phosphor_icons.dart';
import '../features/listen_later/providers.dart';
import 'context_menu.dart';
import 'shelf.dart';
import 'unowned_album_card.dart';

/// Home shelf of albums saved to hear later. Renders nothing when the list is
/// empty, like New Releases — an empty shelf is noise on the home screen, and
/// the nav item is always there for the full list.
class ListenLaterShelf extends ConsumerWidget {
  const ListenLaterShelf({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(listenLaterProvider).value ?? const [];
    if (items.isEmpty) return const SizedBox.shrink();

    return Shelf(
      title: 'Listen Later',
      height: 236,
      itemCount: items.length > 20 ? 20 : items.length,
      onSeeAll: () => context.go('/listen-later'),
      itemBuilder: (context, i) {
        final e = items[i];
        return UnownedAlbumCard(
          artist: e.artist,
          title: e.title,
          // Everything on this shelf is unowned by definition, so the label
          // would be noise — the artist is the useful line.
          subtitle: e.artist,
          cover: e.cover,
          deezerId: e.deezerId,
          menuItems: (ctx) => [
            AriaMenuItem(
              'Remove',
              () => removeFromListenLater(ctx, ref, id: e.id, title: e.title),
              icon: PhosphorIconsRegular.trash,
              destructive: true,
            ),
          ],
        );
      },
    );
  }
}
