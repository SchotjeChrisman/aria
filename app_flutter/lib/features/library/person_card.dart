import 'package:flutter/material.dart';

import '../../widgets/artist_avatar.dart';

/// Artist/composer grid tile (legacy .artist-card): round face filling the
/// art box, name + dim sub-line. Sized by its parent (grid tile or shelf).
class PersonCard extends StatelessWidget {
  const PersonCard({
    super.key,
    required this.name,
    this.subtitle,
    this.imageUrl,
    this.onTap,
    this.onSecondary,
  });

  final String name;
  final String? subtitle;
  final String? imageUrl;
  final VoidCallback? onTap;

  /// Right-click / long-press at the pointer's global position — feed it to
  /// showAriaContextMenu.
  final void Function(Offset globalPosition)? onSecondary;

  @override
  Widget build(BuildContext context) {
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
              child: LayoutBuilder(
                builder: (_, box) => Center(
                  child: ArtistAvatar(
                    name: name,
                    imageUrl: imageUrl,
                    size: box.maxWidth,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              name,
              style: const TextStyle(fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(
                subtitle!,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }
}

/// "3 albums", "1 work".
String countLabel(int n, String word) => '$n $word${n == 1 ? '' : 's'}';
