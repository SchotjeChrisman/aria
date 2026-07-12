import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/connection.dart';
import '../core/formats.dart';
import '../core/theme.dart';

/// Round artist avatar: photo when available, otherwise initials on a tinted
/// disc (legacy initials() fallback). A known portrait loads via the LAN
/// proxy first, then the raw CDN URL, then initials — so a proxy-less server
/// or a single un-cacheable portrait still shows a face.
class ArtistAvatar extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
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

    // Always try the by-name LAN proxy: it resolves portraits from the server's
    // people map regardless of whether the caller loaded a CDN url, so an
    // enriched artist shows a face on every screen (not just the ones that pass
    // imageUrl). Proxy 404 (un-enriched name) falls to the CDN url if known,
    // then initials. Raw CDN url second.
    final urls = [
      ref.watch(apiClientProvider).peopleImgUrl(name),
      ?imageUrl,
    ];

    return Container(
      width: size,
      height: size,
      // Borderless like album covers; the grey disc alone carries the initials
      // fallback and is hidden once a portrait loads over it.
      decoration: BoxDecoration(
        color: c.bgHover,
        shape: BoxShape.circle,
      ),
      clipBehavior: Clip.antiAlias,
      child: _ChainImage(
        urls: urls,
        fallback: fallback,
        // Decode at display resolution — portraits can be huge.
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
      ),
    );
  }
}

/// Loads each URL in order, advancing on load error; shows [fallback] once all
/// candidates fail.
class _ChainImage extends StatefulWidget {
  const _ChainImage({
    required this.urls,
    required this.fallback,
    required this.cacheWidth,
  });

  final List<String> urls;
  final Widget fallback;
  final int cacheWidth;

  @override
  State<_ChainImage> createState() => _ChainImageState();
}

class _ChainImageState extends State<_ChainImage> {
  int _i = 0;

  @override
  void didUpdateWidget(_ChainImage old) {
    super.didUpdateWidget(old);
    // Recycled tile (shelf/grid) points at a new person — restart the chain.
    if (!listEquals(old.urls, widget.urls)) _i = 0;
  }

  @override
  Widget build(BuildContext context) {
    if (_i >= widget.urls.length) return widget.fallback;
    final url = widget.urls[_i];
    return Image.network(
      url,
      // Fresh element per candidate: without a key the reused Image keeps the
      // failed candidate's state and never loads the next URL.
      key: ValueKey(url),
      fit: BoxFit.cover,
      cacheWidth: widget.cacheWidth,
      errorBuilder: (_, _, _) {
        // Can't setState during build; advance next frame. Blank (not initials)
        // meanwhile so we don't flash initials between candidates.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _i < widget.urls.length) setState(() => _i++);
        });
        return _i + 1 >= widget.urls.length
            ? widget.fallback
            : const SizedBox.shrink();
      },
    );
  }
}
