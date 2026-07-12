import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/log_sync.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../core/library_providers.dart' show enrichRefreshProvider;
import '../../widgets/art_image.dart';
import '../../widgets/format_badge.dart';
import '../library/library_providers.dart' show queueRestoreProvider;
import 'providers.dart';
import 'seek_bar.dart';
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
  @override
  Widget build(BuildContext context) {
    // Keep the engine initialized and the play-report latch alive for the
    // app's lifetime — this bar is always mounted.
    final init = ref.watch(playerInitProvider);
    ref.watch(playReporterProvider);
    // The persisted queue must rehydrate no matter which tab the app opens
    // on (it used to hang off LibraryScreen, so headset/notification play
    // did nothing after a restart until the Library tab was visited).
    ref.watch(queueRestoreProvider);
    // Server-side enrichment finishing must refresh the app from anywhere,
    // not just while the Settings page happens to be open.
    ref.watch(enrichRefreshProvider);
    // Log uploads run for the app's lifetime, same trick.
    ref.watch(logSyncProvider);

    // Playback notices (e.g. streaming blocked by the data-usage settings)
    // ride the same SnackBar pathway as audio errors.
    ref.listen(playbackNoticeProvider, (_, notice) {
      if (notice == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(notice.message)));
    });

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
    // Position/duration live inside SeekBar so time-pos ticks don't rebuild
    // the whole bar.
    final fmt = ref.watch(playbackFormatProvider).value;
    final volume = ref.watch(volumeProvider);
    final queue = ref.read(queueProvider.notifier);
    final player = ref.watch(ariaPlayerProvider);
    final unavailable = init.hasValue && !player.isAvailable;

    final meta = radio != null
        ? _radioMeta(context, radio)
        : _nowMeta(context, track);
    final prevBtn = IconButton(
      icon: const Icon(Icons.skip_previous),
      color: c.fg,
      tooltip: 'Previous',
      // Live stream: no track skipping (legacy).
      onPressed: track == null ? null : queue.prev,
    );
    final playBtn = IconButton.filled(
      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
      tooltip: 'Play/Pause',
      onPressed: track == null && radio == null ? null : queue.togglePlay,
    );
    final nextBtn = radio != null
        ? IconButton(
            icon: const Icon(Icons.stop),
            color: c.fg,
            tooltip: 'Stop station',
            onPressed: ref.read(radioPlaybackProvider.notifier).stop,
          )
        : IconButton(
            icon: const Icon(Icons.skip_next),
            color: c.fg,
            tooltip: 'Next',
            onPressed: track == null ? null : queue.next,
          );
    final queueBtn = IconButton(
      icon: const Icon(Icons.queue_music),
      color: c.fgDim,
      tooltip: 'Queue',
      onPressed: () => context.push('/queue'),
    );

    final bar = Container(
      padding: const EdgeInsets.symmetric(horizontal: AriaSpace.s3),
      decoration: BoxDecoration(
        color: c.bgRaised,
        // lineStrong: sole shadowless separator from the white content above.
        // (Phase 3 replaces this whole surface with a floating shadowed pill.)
        border: Border(top: BorderSide(color: c.lineStrong)),
      ),
      // Bottom safe-area so the bar clears Android gesture handles, with a
      // little breathing room even without a system inset.
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: AriaSpace.s2),
        child: SizedBox(
          height: 84,
          child: Builder(
            builder: (context) {
              final bp = AriaBreakpoint.of(context);

              // Below the desktop band the three-column layout is too
              // cramped: seek and meta each get squeezed into a third of the
              // bar. Stack instead — full-width seek strip on top, meta +
              // core controls in one row below, with time labels and the
              // format badge joining above the mobile band.
              if (bp != AriaBreakpoint.desktop) {
                final roomy = bp != AriaBreakpoint.mobile;
                return Column(
                  children: [
                    SizedBox(
                      height: 26,
                      child: radio != null
                          // disabled — live
                          ? const SeekBar(live: true, showTimes: false)
                          : SeekBar(showTimes: roomy),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(child: meta),
                          if (roomy && track != null) ...[
                            Flexible(
                              child: FormatBadge(
                                format: track.format,
                                bitsPerSample:
                                    fmt?.bitDepth ?? track.bitsPerSample,
                                sampleRate: fmt?.sampleRate ?? track.sampleRate,
                                lossless: track.lossless,
                              ),
                            ),
                            const SizedBox(width: AriaSpace.s2),
                          ],
                          prevBtn,
                          playBtn,
                          nextBtn,
                          queueBtn,
                        ],
                      ),
                    ),
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(flex: 3, child: meta),
                  const SizedBox(width: AriaSpace.s3),
                  Expanded(
                    flex: 4,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [prevBtn, playBtn, nextBtn],
                        ),
                        if (radio != null)
                          Row(
                            children: [
                              const TimeLabel(0),
                              // disabled — live
                              const Expanded(
                                child: SeekBar(live: true, showTimes: false),
                              ),
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
                          const SeekBar(),
                      ],
                    ),
                  ),
                  const SizedBox(width: AriaSpace.s3),
                  Expanded(
                    flex: 3,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        // Signal path is the desktop-band flourish; the
                        // stacked layout shows the format badge instead.
                        const Flexible(child: SignalPath()),
                        const SizedBox(width: AriaSpace.s3),
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
                                    onChanged: (v) => ref
                                        .read(volumeProvider.notifier)
                                        .set(v),
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
                        queueBtn,
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
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
                  style: Theme.of(context).textTheme.bodySmall!.copyWith(
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
            border: Border.all(color: c.lineStrong),
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
                style: Theme.of(context).textTheme.bodySmall,
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
    final artUrl = ref
        .watch(apiClientProvider)
        .artUrl(track.albumId, version: track.artVersion);
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
                  style: Theme.of(context).textTheme.bodySmall,
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
