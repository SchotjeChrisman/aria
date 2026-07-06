import 'package:flutter/material.dart';

import '../core/formats.dart';
import '../core/theme.dart';

/// Legacy fmtBadge rendered as text: "FLAC 24/96", "MP3". Lossless sources
/// get the accent color (legacy .c-format.lossless); lossy stay dim. Hi-res
/// material (>16-bit or >48 kHz) is weighted slightly heavier.
class FormatBadge extends StatelessWidget {
  const FormatBadge({
    super.key,
    this.format,
    this.bitsPerSample,
    this.sampleRate,
    this.lossless = false,
  });

  final String? format;
  final int? bitsPerSample;
  final int? sampleRate;
  final bool lossless;

  @override
  Widget build(BuildContext context) {
    final text = formatBadgeText(
      format: format,
      bitsPerSample: bitsPerSample,
      sampleRate: sampleRate,
    );
    if (text.isEmpty) return const SizedBox.shrink();
    final c = AriaColors.of(context);
    final hiRes = isHiRes(bitsPerSample: bitsPerSample, sampleRate: sampleRate);
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        height: 1.4,
        letterSpacing: 0.55,
        fontWeight: hiRes ? FontWeight.w600 : FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: lossless ? c.lossless : c.fgDim,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
