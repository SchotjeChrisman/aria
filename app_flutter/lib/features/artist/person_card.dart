import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../widgets/artist_avatar.dart';

/// Person card for shelves/grids (legacy artistCard): round portrait or
/// initials, name, dim sub-line.
class PersonCard extends StatelessWidget {
  const PersonCard({
    super.key,
    required this.name,
    this.subtitle,
    this.imageUrl,
    this.onTap,
  });

  final String name;
  final String? subtitle;
  final String? imageUrl;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AriaRadius.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ArtistAvatar(name: name, imageUrl: imageUrl, size: 120),
          const SizedBox(height: AriaSpace.s2),
          Text(
            name,
            style: const TextStyle(fontWeight: FontWeight.w500),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          if (subtitle != null && subtitle!.isNotEmpty)
            Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
        ],
      ),
    );
  }
}
