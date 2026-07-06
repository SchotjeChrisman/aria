import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';

/// The Roon signature (legacy updateSignalPath): source format → processing
/// → output. The output leg shows what mpv is actually decoding
/// (audio-params) — the bit-perfect story, not a guess from tags.
class SignalPath extends ConsumerWidget {
  const SignalPath({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final radio = track == null ? ref.watch(radioPlaybackProvider) : null;
    if (track == null && radio == null) return const SizedBox.shrink();
    final fmt = ref.watch(playbackFormatProvider).value;
    final c = AriaColors.of(context);

    final String text;
    final bool lossless;
    if (radio != null) {
      // Legacy updateSignalPath radio branch: the stream codec is opaque;
      // FLAC in the URL is the honest tell.
      lossless = radio.url.toLowerCase().contains('flac');
      text = 'STREAM → mpv';
    } else {
      final src = formatBadgeText(
        format: track!.format,
        bitsPerSample: track.bitsPerSample,
        sampleRate: track.sampleRate,
      );
      final mid = track.lossless ? 'lossless' : 'lossy source';
      var out = 'mpv';
      if (fmt?.sampleRate != null) {
        final k = (fmt!.sampleRate! / 1000).toString().replaceFirst(
          RegExp(r'\.0$'),
          '',
        );
        final bits = fmt.bitDepth != null ? '${fmt.bitDepth}/' : '';
        out = '$bits$k → mpv';
      }
      lossless = track.lossless;
      text = '${src.isEmpty ? 'AUDIO' : src} → $mid → $out';
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: lossless ? c.lossless : c.lossy,
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: c.fgDim,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
