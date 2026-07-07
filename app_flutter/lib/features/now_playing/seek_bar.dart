import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formats.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import 'providers.dart';

/// Seek slider + time labels with the shared drag latch. This widget is the
/// ONLY place that watches [playbackPositionProvider], so mpv's time-pos
/// ticks repaint just this strip — TransportBar and the expanded now-playing
/// controls no longer rebuild per tick (same isolation pattern as
/// _SyncedLyrics in lyrics_view.dart).
class SeekBar extends ConsumerStatefulWidget {
  const SeekBar({
    super.key,
    this.showTimes = true,
    this.live = false,
    this.thumbRadius = 6,
  });

  /// Elapsed/total labels around the slider (hidden on cramped layouts).
  final bool showTimes;

  /// Radio stream: disabled slider, nothing watched — live has no seek.
  final bool live;

  /// 6 on the transport bar, 7 on the expanded now-playing screen.
  final double thumbRadius;

  @override
  ConsumerState<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<SeekBar> {
  /// Non-null while the user drags the seek slider; the engine position
  /// keeps ticking underneath but must not fight the thumb.
  double? _dragPos;

  @override
  Widget build(BuildContext context) {
    if (widget.live) return _slider(pos: 0, dur: 0);
    final pos = ref.watch(playbackPositionProvider).value ?? 0;
    final dur = ref.watch(currentDurationProvider);
    final slider = _slider(pos: pos, dur: dur);
    if (!widget.showTimes) return slider;
    return Row(
      children: [
        TimeLabel(_dragPos ?? pos),
        Expanded(child: slider),
        TimeLabel(dur),
      ],
    );
  }

  /// Legacy seek bars are thin; Material's defaults are chunky.
  Widget _slider({required double pos, required double dur}) {
    final enabled = dur > 0;
    final max = enabled ? dur : 1.0;
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 3,
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: widget.thumbRadius,
        ),
        overlayShape: RoundSliderOverlayShape(
          overlayRadius: widget.thumbRadius * 2,
        ),
      ),
      child: Slider(
        value: (_dragPos ?? pos).clamp(0.0, max),
        max: max,
        onChanged: enabled ? (v) => setState(() => _dragPos = v) : null,
        onChangeEnd: enabled
            ? (v) {
                ref.read(ariaPlayerProvider).seek(v);
                setState(() => _dragPos = null);
              }
            : null,
      ),
    );
  }
}

/// Tabular-figure m:ss label (the _time() helper both screens duplicated).
class TimeLabel extends StatelessWidget {
  const TimeLabel(this.seconds, {super.key});

  final double seconds;

  @override
  Widget build(BuildContext context) {
    return Text(
      formatDuration(seconds),
      style: TextStyle(
        fontSize: 12,
        color: AriaColors.of(context).fgDim,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
