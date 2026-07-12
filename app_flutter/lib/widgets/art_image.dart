import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/downloads.dart';
import '../core/formats.dart';
import '../core/theme.dart';

/// albumId from a server art URL ("…/api/art/{albumId}"), null for anything
/// else (external covers, no URL).
/// ponytail: parsed from the URL so 15+ call sites don't grow an albumId
/// param — if art ever needs auth/query strings, pass the id explicitly.
String? _artAlbumId(String url) {
  // Strip any query string (?v=… / ?source=…) so cache-bust/slot params don't
  // land in the parsed id and break the offline-file lookup.
  final segs = Uri.tryParse(url.split('?').first)?.pathSegments;
  if (segs == null || segs.length < 3) return null;
  return segs[segs.length - 2] == 'art' && segs[segs.length - 3] == 'api'
      ? segs.last
      : null;
}

/// Album/artist art with the legacy fallback chain: network image → locally
/// downloaded cover (offline) → tinted square showing initials of
/// [fallbackText] (legacy .art .initials). Uses Flutter's in-memory
/// ImageCache; server art is immutable per albumId so no disk cache layer is
/// needed yet.
class ArtImage extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final decodeEdge = size ?? decodeSize;
    final localArtOf = ref.watch(localArtResolverProvider);

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
        // Fallback/placeholder box needs a load-bearing edge to be visible on
        // the pure-white canvas; a real cover clips over it so it stays hidden
        // on the happy path (no shadow — dense art grids would look noisy).
        border: Border.all(color: c.lineStrong),
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
              // Network failed (offline?): downloaded cover, then initials.
              // The file stat runs only on error, never on the happy path.
              errorBuilder: (_, _, _) {
                final albumId = _artAlbumId(url!);
                final local = albumId == null ? null : localArtOf(albumId);
                return local == null
                    ? fallback
                    : Image.file(
                        File(local),
                        fit: fit,
                        errorBuilder: (_, _, _) => fallback,
                      );
              },
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
