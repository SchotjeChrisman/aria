import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../widgets/artist_avatar.dart';

/// Roon-style credit card for the album Credits shelf: portrait, name, role —
/// each one a door to the person's page (legacy personCard).
class CreditCard extends StatelessWidget {
  const CreditCard({
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
    final c = AriaColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AriaRadius.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ArtistAvatar(name: name, imageUrl: imageUrl, size: 108),
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
              style: TextStyle(fontSize: 12.5, color: c.fgDim),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
        ],
      ),
    );
  }
}
