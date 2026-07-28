import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/connection.dart';
import '../core/phosphor_icons.dart';
import '../core/theme.dart';
import '../features/release/routes.dart';
import 'context_menu.dart';

/// Card for an album the library doesn't have — New Releases, Listen Later,
/// artist discography ghosts. Covers are remote CDN URLs, so it loads through
/// the server's caching proxy and falls back to the raw URL, then to a
/// placeholder.
///
/// Deliberately not [AlbumCard]: that one takes a local albumId's art URL and
/// routes to /album/:id, neither of which exists for an album nobody owns.
class UnownedAlbumCard extends ConsumerWidget {
  const UnownedAlbumCard({
    super.key,
    required this.artist,
    required this.title,
    required this.subtitle,
    this.cover,
    this.deezerId,
    this.menuItems,
  });

  final String artist;
  final String title;
  final String subtitle;
  final String? cover;
  final int? deezerId;

  /// Right-click / long-press actions. Null shows no menu.
  final List<AriaMenuItem> Function(BuildContext)? menuItems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final placeholder = Center(
      child: Icon(PhosphorIconsRegular.vinylRecord, color: c.fgDim),
    );

    Widget art = placeholder;
    if (cover != null && cover!.isNotEmpty) {
      final proxy = ref.watch(apiClientProvider).extAlbumImgUrl(cover!);
      art = LayoutBuilder(
        // Band-sized cards have no fixed extent — decode at the laid-out size
        // rather than the full remote cover.
        builder: (context, box) {
          final w =
              (box.maxWidth * MediaQuery.devicePixelRatioOf(context)).round();
          return Image.network(
            proxy,
            fit: BoxFit.cover,
            cacheWidth: w,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => Image.network(
              cover!,
              fit: BoxFit.cover,
              cacheWidth: w,
              errorBuilder: (_, _, _) => placeholder,
            ),
          );
        },
      );
    }

    return GestureDetector(
      onTap: () =>
          context.push(releasePath(artist, title, deezerId: deezerId)),
      onSecondaryTapUp: menuItems == null
          ? null
          : (d) =>
              showAriaContextMenu(context, d.globalPosition, menuItems!(context)),
      onLongPressStart: menuItems == null
          ? null
          : (d) =>
              showAriaContextMenu(context, d.globalPosition, menuItems!(context)),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: c.bgRaised,
                  borderRadius: BorderRadius.circular(AriaRadius.md),
                  border: Border.all(color: c.lineStrong),
                ),
                clipBehavior: Clip.antiAlias,
                child: art,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            // Exactly two text lines, like AlbumCard. The grids these cards
            // share (artist discography, Listen Later) pin cell height with a
            // childAspectRatio tuned for a two-line block, so a third line
            // overflows the tile at narrow widths. "Not in library" therefore
            // rides in the subtitle, which call sites compose.
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}
