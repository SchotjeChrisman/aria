import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/formats.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/art_image.dart';
import '../../widgets/format_badge.dart';
import 'providers.dart';
import 'signal_path.dart';

/// Persistent bottom transport (legacy #now-bar): art + title/artist,
/// prev/play/next, seek with times, volume, format badge (actual stream
/// format), signal path, lyrics/queue buttons. Mount below the router shell.
class TransportBar extends ConsumerStatefulWidget {
  const TransportBar({super.key});

  @override
  ConsumerState<TransportBar> createState() => _TransportBarState();
}

class _TransportBarState extends ConsumerState<TransportBar> {
  /// Non-null while the user drags the seek slider; the engine position
  /// keeps ticking underneath but must not fight the thumb.
  double? _dragPos;

  @override
  Widget build(BuildContext context) {
    // Keep the engine initialized and the play-report latch alive for the
    // app's lifetime — this bar is always mounted.
    final init = ref.watch(playerInitProvider);
    ref.watch(playReporterProvider);

    // Audio output died (e.g. exclusive access denied because another app
    // holds the device) — the engine already stopped; tell the user why.
    ref.listen(audioErrorProvider, (_, next) {
      final detail = next.value;
      if (detail == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            'Playback stopped — the audio device is unavailable ($detail). '
            'Close other audio apps, or turn off Exclusive output in '
            'Settings.',
          ),
        ),
      );
    });

    final c = AriaColors.of(context);
    final track = ref.watch(currentTrackProvider);
    // Radio owns the bar when no library track does (legacy updateNowBar).
    final radio = track == null ? ref.watch(radioPlaybackProvider) : null;
    final playing =
        ref.watch(playbackStateProvider).value == PlaybackState.playing;
    final pos = ref.watch(playbackPositionProvider).value ?? 0;
    final dur = ref.watch(currentDurationProvider);
    final fmt = ref.watch(playbackFormatProvider).value;
    final volume = ref.watch(volumeProvider);
    final queue = ref.read(queueProvider.notifier);
    final player = ref.watch(ariaPlayerProvider);
    final unavailable = init.hasValue && !player.isAvailable;

    final bar = Container(
      height: 84,
      padding: const EdgeInsets.symmetric(horizontal: AriaSpace.s3),
      decoration: BoxDecoration(
        color: c.bgRaised,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final showSignal = w >= 1000;
          final showVolume = w >= 760;
          final showBadge = w >= 560;

          return Row(
            children: [
              Expanded(
                flex: 3,
                child: radio != null
                    ? _radioMeta(context, radio)
                    : _nowMeta(context, track),
              ),
              const SizedBox(width: AriaSpace.s3),
              Expanded(
                flex: 4,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.skip_previous),
                          color: c.fg,
                          tooltip: 'Previous',
                          // Live stream: no track skipping (legacy).
                          onPressed: track == null ? null : queue.prev,
                        ),
                        IconButton.filled(
                          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                          tooltip: 'Play/Pause',
                          onPressed: track == null && radio == null
                              ? null
                              : queue.togglePlay,
                        ),
                        if (radio != null)
                          IconButton(
                            icon: const Icon(Icons.stop),
                            color: c.fg,
                            tooltip: 'Stop station',
                            onPressed: ref
                                .read(radioPlaybackProvider.notifier)
                                .stop,
                          )
                        else
                          IconButton(
                            icon: const Icon(Icons.skip_next),
                            color: c.fg,
                            tooltip: 'Next',
                            onPressed: track == null ? null : queue.next,
                          ),
                      ],
                    ),
                    if (radio != null)
                      Row(
                        children: [
                          _time(0, c),
                          Expanded(child: _seek(0, 0)), // disabled — live
                          Text(
                            'LIVE',
                            style: TextStyle(
                              fontSize: 12,
                              letterSpacing: 1,
                              color: c.accent,
                            ),
                          ),
                        ],
                      )
                    else
                      Row(
                        children: [
                          _time(_dragPos ?? pos, c),
                          Expanded(child: _seek(pos, dur)),
                          _time(dur, c),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AriaSpace.s3),
              Expanded(
                flex: 3,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (showSignal) ...[
                      const Flexible(child: SignalPath()),
                      const SizedBox(width: AriaSpace.s3),
                    ] else if (showBadge && radio != null) ...[
                      Text(
                        'STREAM',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1,
                          color: c.fgDim,
                        ),
                      ),
                      const SizedBox(width: AriaSpace.s3),
                    ] else if (showBadge && track != null) ...[
                      // Actual decoded format from mpv when available,
                      // tagged format until then — the bit-perfect badge.
                      FormatBadge(
                        format: track.format,
                        bitsPerSample: fmt?.bitDepth ?? track.bitsPerSample,
                        sampleRate: fmt?.sampleRate ?? track.sampleRate,
                        lossless: track.lossless,
                      ),
                      const SizedBox(width: AriaSpace.s3),
                    ],
                    if (showVolume)
                      SizedBox(
                        width: 130,
                        child: Row(
                          children: [
                            Icon(Icons.volume_up, size: 16, color: c.fgDim),
                            Expanded(
                              child: _slim(
                                Slider(
                                  value: volume,
                                  max: 100,
                                  onChanged: (v) =>
                                      ref.read(volumeProvider.notifier).set(v),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.lyrics_outlined),
                      color: c.fgDim,
                      tooltip: 'Now playing / lyrics',
                      onPressed: track == null
                          ? null
                          : () => context.push('/now-playing'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.queue_music),
                      color: c.fgDim,
                      tooltip: 'Queue',
                      onPressed: () => context.push('/queue'),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );

    if (!unavailable) return bar;
    // No-libmpv degradation must be visible: the app runs, playback doesn't.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: AriaSpace.s4,
            vertical: AriaSpace.s2,
          ),
          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.15),
          child: Row(
            children: [
              Icon(
                Icons.volume_off,
                size: 16,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: AriaSpace.s2),
              Expanded(
                child: Text(
                  'Playback unavailable — '
                  '${player.unavailableReason ?? 'libmpv could not be loaded'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
        ),
        bar,
      ],
    );
  }

  /// Legacy playRadio now-bar: station name + "Internet Radio", initials art.
  Widget _radioMeta(BuildContext context, RadioStation st) {
    final c = AriaColors.of(context);
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: BorderRadius.circular(AriaRadius.sm),
            border: Border.all(color: c.line),
          ),
          child: Icon(Icons.radio, size: 22, color: c.fgDim),
        ),
        const SizedBox(width: AriaSpace.s3),
        Flexible(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                st.name,
                style: TextStyle(color: c.fg),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                'Internet Radio',
                style: TextStyle(fontSize: 12.5, color: c.fgDim),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _nowMeta(BuildContext context, Track? track) {
    final c = AriaColors.of(context);
    if (track == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text('Nothing playing', style: TextStyle(color: c.fgDim)),
      );
    }
    final artUrl = ref.read(apiClientProvider).artUrl(track.albumId);
    return InkWell(
      onTap: () => context.push('/now-playing'),
      borderRadius: BorderRadius.circular(AriaRadius.sm),
      child: Row(
        children: [
          ArtImage(
            url: artUrl,
            fallbackText: track.album,
            size: 52,
            borderRadius: AriaRadius.sm,
          ),
          const SizedBox(width: AriaSpace.s3),
          Flexible(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trackTitleLine(track),
                  style: TextStyle(color: c.fg),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  trackSubLine(track),
                  style: TextStyle(fontSize: 12.5, color: c.fgDim),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _time(double seconds, AriaColors c) => Text(
    formatDuration(seconds),
    style: TextStyle(
      fontSize: 12,
      color: c.fgDim,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );

  Widget _seek(double pos, double dur) {
    final enabled = dur > 0;
    final max = enabled ? dur : 1.0;
    return _slim(
      Slider(
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

  /// Legacy seek/volume bars are thin; Material's defaults are chunky.
  Widget _slim(Slider slider) => SliderTheme(
    data: SliderThemeData(
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
    ),
    child: slider,
  );
}
