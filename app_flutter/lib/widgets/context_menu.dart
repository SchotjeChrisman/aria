import 'package:flutter/material.dart';

import '../core/theme.dart';

/// One entry in a context menu (legacy ctxMenu row()).
class AriaMenuItem {
  const AriaMenuItem(
    this.label,
    this.onTap, {
    this.icon,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool destructive;
}

/// Right-click / long-press menu at [globalPosition]. Wire it from a
/// widget's onSecondary callback:
///
///   onSecondary: (pos) => showAriaContextMenu(context, pos, [
///     AriaMenuItem('Play now', play, icon: Icons.play_arrow),
///     AriaMenuItem('Add to queue', add, icon: Icons.playlist_add),
///   ]),
Future<void> showAriaContextMenu(
  BuildContext context,
  Offset globalPosition,
  List<AriaMenuItem> items,
) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final c = AriaColors.of(context);
  final picked = await showMenu<AriaMenuItem>(
    context: context,
    position: RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final item in items)
        PopupMenuItem<AriaMenuItem>(
          value: item,
          height: 40,
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(
                  item.icon,
                  size: 18,
                  color: item.destructive
                      ? Theme.of(context).colorScheme.error
                      : c.fgDim,
                ),
                const SizedBox(width: 10),
              ],
              Text(
                item.label,
                style: item.destructive
                    ? TextStyle(color: Theme.of(context).colorScheme.error)
                    : null,
              ),
            ],
          ),
        ),
    ],
  );
  picked?.onTap();
}
