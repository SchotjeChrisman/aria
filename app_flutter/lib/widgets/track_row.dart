import 'package:flutter/material.dart';
import '../core/phosphor_icons.dart';

import '../core/formats.dart';
import '../core/theme.dart';
import 'format_badge.dart';

/// Album/playlist track row (legacy .track-row): number column, title +
/// optional dim subtitle, format badge, tabular duration. The current track
/// renders fully in accent with a ▶ marker instead of its number.
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    this.number,
    required this.title,
    this.subtitle,
    this.duration,
    this.format,
    this.bitsPerSample,
    this.sampleRate,
    this.lossless = false,
    this.downloaded = false,
    this.isCurrent = false,
    this.onTap,
    this.onSecondary,
  });

  /// Track number; null hides the column's digits.
  final int? number;
  final String title;
  final String? subtitle;

  /// Seconds.
  final num? duration;

  final String? format;
  final int? bitsPerSample;
  final int? sampleRate;
  final bool lossless;

  /// Shows a small offline-available check. Callers watch the downloads
  /// index with `select` so only the affected row rebuilds.
  final bool downloaded;

  final bool isCurrent;
  final VoidCallback? onTap;

  /// Right-click / long-press at the pointer's global position.
  final void Function(Offset globalPosition)? onSecondary;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final fg = isCurrent ? c.accent : c.fg;
    final dim = isCurrent ? c.accent : c.fgDim;

    return GestureDetector(
      onSecondaryTapUp: onSecondary == null
          ? null
          : (d) => onSecondary!(d.globalPosition),
      onLongPressStart: onSecondary == null
          ? null
          : (d) => onSecondary!(d.globalPosition),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AriaRadius.md),
          hoverColor: c.bgHover,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AriaSpace.s3,
                vertical: 10,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(
                      isCurrent ? '▶' : (number?.toString() ?? ''),
                      style: TextStyle(
                        color: dim,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(color: fg),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitle != null && subtitle!.isNotEmpty)
                          Text(
                            subtitle!,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: dim),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (downloaded) ...[
                    const SizedBox(width: 14),
                    Icon(PhosphorIconsRegular.checkCircle, size: 14, color: dim),
                  ],
                  const SizedBox(width: 14),
                  FormatBadge(
                    format: format,
                    bitsPerSample: bitsPerSample,
                    sampleRate: sampleRate,
                    // legacy: the current row is accent across every column
                    lossless: lossless || isCurrent,
                  ),
                  const SizedBox(width: 14),
                  Text(
                    formatDuration(duration),
                    style: TextStyle(
                      color: dim,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
