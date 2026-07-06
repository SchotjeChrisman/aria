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
    this.itemWidth = 168,
    this.onSeeAll,
  });

  final String title;

  /// Fixed height of the scroller viewport (cards size themselves to it).
  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double itemWidth;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
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
                  style: TextStyle(fontSize: 12.5, color: c.fgDim),
                ),
              ),
          ],
        ),
        const SizedBox(height: AriaSpace.s3),
        SizedBox(
          height: height,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: itemCount,
            separatorBuilder: (_, _) => const SizedBox(width: AriaSpace.s6),
            itemBuilder: (context, i) =>
                SizedBox(width: itemWidth, child: itemBuilder(context, i)),
          ),
        ),
      ],
    );
  }
}
