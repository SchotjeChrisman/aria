import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Horizontal scroller with a section header — home-screen rows of albums,
/// artists, new releases.
class Shelf extends StatelessWidget {
  const Shelf({
    super.key,
    required this.title,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.itemWidth,
    this.mobileColumns = 3,
    this.onSeeAll,
  });

  /// Reference card width the legacy shelf hardcoded; call-site [height]
  /// values were designed against it, so band-derived widths shift the
  /// viewport height by the same delta.
  static const double _designWidth = 168;

  final String title;

  /// Viewport height as designed for a [_designWidth]-wide card; band-sized
  /// shelves shift it by the actual card-width delta.
  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// Explicit card width. Null (default) sizes cards from the band-fixed
  /// column count with a half-card peek, so every phone shows the same
  /// shelf layout. Shelves whose cards hold fixed-size content (e.g.
  /// avatar discs) pass an explicit width.
  final double? itemWidth;

  /// Full cards shown on a mobile-width band (no peek). Album shelves keep 3;
  /// denser content (artist avatars) passes more.
  final int mobileColumns;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (onSeeAll != null)
              TextButton(
                onPressed: onSeeAll,
                child: Text(
                  'All',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
        const SizedBox(height: AriaSpace.s3),
        LayoutBuilder(
          // Genuinely local constraint: the shelf's own width (minus
          // rail/padding) drives the card size, not the window width.
          builder: (context, box) {
            const gap = AriaSpace.s3;
            // Band-fixed visible cards. Mobile shows exactly 3 full cards
            // (no peek — requested); wider bands keep the half-card peek that
            // signals scrollability. gridColumns stays 2 on mobile (it drives
            // the 2-col grid pages), so shelf count is decided here.
            final band = AriaBreakpoint.of(context);
            final n = band == AriaBreakpoint.mobile
                ? mobileColumns
                : band.gridColumns;
            final peek = band == AriaBreakpoint.mobile ? 0.0 : 0.5;
            // Gaps rendered between the visible cards: one per full card when a
            // half-card peeks after them, one fewer when the row ends flush
            // (peek == 0) — else the cards under-fill and leave a gap of slack
            // at the right edge.
            final gaps = peek > 0 ? n : n - 1;
            final w = itemWidth ?? (box.maxWidth - gaps * gap) / (n + peek);
            return SizedBox(
              height: itemWidth == null ? height + (w - _designWidth) : height,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: itemCount,
                separatorBuilder: (_, _) => const SizedBox(width: gap),
                itemBuilder: (context, i) =>
                    SizedBox(width: w, child: itemBuilder(context, i)),
              ),
            );
          },
        ),
      ],
    );
  }
}
