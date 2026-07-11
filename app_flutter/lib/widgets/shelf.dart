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
    this.extraColumns = 0,
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

  /// Added to the non-mobile band column count. Person shelves pass 1 so their
  /// cards are one column denser (smaller) than album cards, matching the
  /// person grids.
  final int extraColumns;
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
            // Match the grid's crossAxisSpacing (s5) so a shelf card and a
            // grid card come out the same width at the same column count and
            // side padding (both s6).
            const gap = AriaSpace.s5;
            // Band-fixed visible cards, all fully visible — no half-card peek
            // (cutoff cards are unwanted). Non-mobile bands use gridColumns so
            // the shelf lines up with the grid pages; mobile keeps its own
            // count (gridColumns stays 2 there to drive the 2-col grids).
            final band = AriaBreakpoint.of(context);
            final n = band == AriaBreakpoint.mobile
                ? mobileColumns
                : band.gridColumns + extraColumns;
            final w = itemWidth ?? (box.maxWidth - (n - 1) * gap) / n;
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
