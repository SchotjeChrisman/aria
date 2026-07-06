import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Centered dim message (legacy .empty), optional icon.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message, this.icon, this.action});

  final String message;
  final IconData? icon;

  /// Optional call-to-action below the message (e.g. "Scan library").
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: 60,
          horizontal: AriaSpace.s6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 40, color: c.fgDim),
              const SizedBox(height: AriaSpace.s4),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.fgDim),
            ),
            if (action != null) ...[
              const SizedBox(height: AriaSpace.s5),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
