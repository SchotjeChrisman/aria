import 'package:flutter/material.dart';
import '../core/phosphor_icons.dart';

import '../core/theme.dart';

/// Snaps horizontal scrolling to multiples of [itemExtent] (card width + gap),
/// so a flick settles with a card aligned to the shelf's left edge instead of
/// stopping mid-card. Chains onto the platform's default physics.
class _SnapPhysics extends ScrollPhysics {
  const _SnapPhysics({required this.itemExtent, super.parent});

  final double itemExtent;

  @override
  _SnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _SnapPhysics(itemExtent: itemExtent, parent: buildParent(ancestor));

  double _snapTarget(ScrollMetrics position, double velocity) {
    final tol = toleranceFor(position);
    var item = position.pixels / itemExtent;
    // Bias toward the next/prev card when there's real flick velocity.
    if (velocity < -tol.velocity) {
      item = item.floorToDouble();
    } else if (velocity > tol.velocity) {
      item = item.ceilToDouble();
    } else {
      item = item.roundToDouble();
    }
    return (item * itemExtent)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    // Leave over-scroll (past the ends) to the parent's spring.
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tol = toleranceFor(position);
    final target = _snapTarget(position, velocity);
    if ((target - position.pixels).abs() < tol.distance) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tol,
    );
  }

  @override
  bool get allowImplicitScrolling => false;
}

/// Horizontal scroller with a section header — home-screen rows of albums,
/// artists, new releases. The header carries a pair of slide arrows that page
/// the row left/right (they no-op when there's nothing to scroll).
class Shelf extends StatefulWidget {
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
  State<Shelf> createState() => _ShelfState();
}

class _ShelfState extends State<Shelf> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Page by most of a viewport; clamp inside the scrollable's own extent.
  void _slide(int dir) {
    if (!_controller.hasClients) return;
    final p = _controller.position;
    final target = (_controller.offset + dir * p.viewportDimension * 0.85)
        .clamp(0.0, p.maxScrollExtent);
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    Widget arrow(IconData icon, int dir) => IconButton(
      icon: Icon(icon, size: 16),
      color: c.fgDim,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: () => _slide(dir),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            arrow(PhosphorIconsRegular.caretLeft, -1),
            arrow(PhosphorIconsRegular.caretRight, 1),
            if (widget.onSeeAll != null)
              TextButton(
                onPressed: widget.onSeeAll,
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
                ? widget.mobileColumns
                : band.gridColumns + widget.extraColumns;
            final w =
                widget.itemWidth ?? (box.maxWidth - (n - 1) * gap) / n;
            return SizedBox(
              height: widget.itemWidth == null
                  ? widget.height + (w - Shelf._designWidth)
                  : widget.height,
              child: ListView.separated(
                controller: _controller,
                scrollDirection: Axis.horizontal,
                // Snap to card boundaries so a touch flick lands on a card
                // edge, not mid-card.
                physics: _SnapPhysics(itemExtent: w + gap),
                itemCount: widget.itemCount,
                separatorBuilder: (_, _) => const SizedBox(width: gap),
                itemBuilder: (context, i) =>
                    SizedBox(width: w, child: widget.itemBuilder(context, i)),
              ),
            );
          },
        ),
      ],
    );
  }
}
