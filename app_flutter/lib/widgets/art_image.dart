import 'package:flutter/material.dart';

import '../core/formats.dart';
import '../core/theme.dart';

/// Album/artist art with the legacy fallback chain: network image → tinted
/// square showing initials of [fallbackText] (legacy .art .initials).
/// Uses Flutter's in-memory ImageCache; server art is immutable per albumId
/// so no disk cache layer is needed yet.
class ArtImage extends StatelessWidget {
  const ArtImage({
    super.key,
    this.url,
    this.fallbackText,
    this.size,
    this.decodeSize,
    this.borderRadius = AriaRadius.md,
    this.fit = BoxFit.cover,
  });

  final String? url;
  final String? fallbackText;

  /// Square edge length; null fills the parent.
  final double? size;

  /// Decode-resolution hint (logical px) for when [size] is null and the
  /// widget fills the parent (e.g. a grid tile extent). Layout is unaffected.
  final double? decodeSize;
  final double borderRadius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final decodeEdge = size ?? decodeSize;

    final fallback = Center(
      child: Text(
        initials(fallbackText),
        style: TextStyle(
          fontSize: (size ?? 96) * 0.3,
          letterSpacing: 1,
          color: c.fgDim,
        ),
        maxLines: 1,
        overflow: TextOverflow.clip,
      ),
    );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.bgRaised,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: c.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null
          ? fallback
          : Image.network(
              url!,
              fit: fit,
              // Decode at display resolution when the size is known — full
              // covers in small grids waste memory and jank scrolling.
              cacheWidth: decodeEdge == null
                  ? null
                  : (decodeEdge * MediaQuery.devicePixelRatioOf(context))
                        .round(),
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => fallback,
              frameBuilder: (_, child, frame, wasSync) => wasSync
                  ? child
                  : AnimatedOpacity(
                      opacity: frame == null ? 0 : 1,
                      duration: const Duration(milliseconds: 150),
                      child: child,
                    ),
            ),
    );
  }
}
