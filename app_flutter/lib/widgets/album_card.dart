import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'art_image.dart';

/// Grid album tile (legacy .album-card): square art, 500-weight title,
/// dim 12.5px subtitle, both single-line ellipsized.
class AlbumCard extends StatelessWidget {
  const AlbumCard({
    super.key,
    required this.title,
    this.subtitle,
    this.artUrl,
    this.onTap,
    this.onSecondary,
  });

  final String title;
  final String? subtitle;
  final String? artUrl;
  final VoidCallback? onTap;

  /// Right-click / long-press, at the pointer's global position — feed it to
  /// showAriaContextMenu.
  final void Function(Offset globalPosition)? onSecondary;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return GestureDetector(
      onTap: onTap,
      onSecondaryTapUp: onSecondary == null
          ? null
          : (d) => onSecondary!(d.globalPosition),
      onLongPressStart: onSecondary == null
          ? null
          : (d) => onSecondary!(d.globalPosition),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ArtImage(url: artUrl, fallbackText: title),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(
                subtitle!,
                style: TextStyle(fontSize: 12.5, height: 1.45, color: c.fgDim),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }
}
