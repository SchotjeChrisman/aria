import 'package:flutter/material.dart';

import '../core/theme.dart';

/// One pill in a FilterBar.
class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// Optional badge count, e.g. active-rule tally on a smart filter.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Material(
      color: selected ? c.bgHover : Colors.transparent,
      shape: StadiumBorder(
        side: BorderSide(color: selected ? c.lineStrong : c.line),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            count != null && count! > 0 ? '$label ($count)' : label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: selected ? c.fg : c.fgDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal row of filter pills, scrollable when it overflows
/// (legacy filter chips above the album grid).
class FilterBar extends StatelessWidget {
  const FilterBar({super.key, required this.children, this.trailing});

  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (i, child) in children.indexed) ...[
                  if (i > 0) const SizedBox(width: AriaSpace.s2),
                  child,
                ],
              ],
            ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: AriaSpace.s3),
          trailing!,
        ],
      ],
    );
  }
}
