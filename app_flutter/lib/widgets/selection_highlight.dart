import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/selection.dart';
import '../core/theme.dart';

/// Accent border + tint over any row/card while it is in the active
/// multi-select (legacy .sel-on highlight). Painted as a foreground
/// decoration so wrapping never shifts layout.
class SelectionHighlight extends ConsumerWidget {
  const SelectionHighlight({
    super.key,
    required this.kind,
    required this.itemKey,
    required this.child,
  });

  final String kind;
  final String itemKey;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(
      selectionProvider.select((s) => s.active && s.contains(kind, itemKey)),
    );
    if (!selected) return child;
    final c = AriaColors.of(context);
    return Container(
      foregroundDecoration: BoxDecoration(
        color: c.accent.withValues(alpha: 0.10),
        border: Border.all(color: c.accent, width: 1.5),
        borderRadius: BorderRadius.circular(AriaRadius.md),
      ),
      child: child,
    );
  }
}
