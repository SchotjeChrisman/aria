import 'package:flutter/material.dart';

import '../core/formats.dart';
import '../core/theme.dart';

/// Round artist avatar: photo when available, otherwise initials on a tinted
/// disc (legacy initials() fallback).
class ArtistAvatar extends StatelessWidget {
  const ArtistAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.size = 48,
  });

  final String name;
  final String? imageUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);

    final fallback = Center(
      child: Text(
        initials(name),
        style: TextStyle(
          fontSize: size * 0.34,
          letterSpacing: 0.5,
          color: c.fgDim,
        ),
      ),
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.bgHover,
        shape: BoxShape.circle,
        border: Border.all(color: c.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: imageUrl == null
          ? fallback
          : Image.network(
              imageUrl!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}
