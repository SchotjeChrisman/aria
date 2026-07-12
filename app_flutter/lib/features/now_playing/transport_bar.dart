import 'dart:ui' show ImageFilter;

import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/phosphor_icons.dart';

import '../../core/connection.dart';
import '../../core/log_sync.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
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

/// No-libmpv degradation strip: the app runs, playback doesn't. Anchored at the
/// TOP of the shell content (not the bottom transport) so it reads as a
/// page-level alert, consistent with the top-anchored error toasts.
class PlaybackUnavailableBanner extends ConsumerWidget {
  const PlaybackUnavailableBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final init = ref.watch(playerInitProvider);
    final player = ref.watch(ariaPlayerProvider);
    if (!init.hasValue || player.isAvailable) return const SizedBox.shrink();
    final error = Theme.of(context).colorScheme.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AriaSpace.s4,
        vertical: AriaSpace.s2,
      ),
      color: error.withValues(alpha: 0.15),
      child: Row(
        children: [
          Icon(PhosphorIconsRegular.speakerSlash, size: 16, color: error),
          const SizedBox(width: AriaSpace.s2),
          Expanded(
            child: Text(
              'Playback unavailable — '
              '${player.unavailableReason ?? 'libmpv could not be loaded'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall!.copyWith(color: error),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransportBarState extends ConsumerState<TransportBar> {
  @override
  Widget build(BuildContext context) {
    // Keep the engine initialized and the play-report latch alive for the
    // app's lifetime — this bar is always mounted.
    ref.watch(playerInitProvider);
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
      showToast(context, notice.message, error: true);
    });

    // Audio output died (e.g. exclusive access denied because another app
    // holds the device) — the engine already stopped; tell the user why.
    ref.listen(audioErrorProvider, (_, next) {
      final detail = next.value;
      if (detail == null) return;
      showToast(
        context,
        'Playback stopped — the audio device is unavailable ($detail). '
        'Close other audio apps, or turn off Exclusive output in Settings.',
        error: true,
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
    final meta = radio != null
        ? _radioMeta(context, radio)
        : _nowMeta(context, track);
    // Solid (filled) glyphs in dimmed grey — lighter than black, but not thin.
    final prevBtn = IconButton(
      icon: const Icon(PhosphorIconsFill.skipBack),
      color: c.fgDim,
      tooltip: 'Previous',
      // Live stream: no track skipping (legacy).
      onPressed: track == null ? null : queue.prev,
    );
    // Same flat style as the skip buttons (no filled circle).
    final playBtn = IconButton(
      icon: Icon(playing ? PhosphorIconsFill.pause : PhosphorIconsFill.play),
      color: c.fgDim,
      tooltip: 'Play/Pause',
      onPressed: track == null && radio == null ? null : queue.togglePlay,
    );
    final nextBtn = radio != null
        ? IconButton(
            icon: const Icon(PhosphorIconsFill.stop),
            color: c.fgDim,
            tooltip: 'Stop station',
            onPressed: ref.read(radioPlaybackProvider.notifier).stop,
          )
        : IconButton(
            icon: const Icon(PhosphorIconsFill.skipForward),
            color: c.fgDim,
            tooltip: 'Next',
            onPressed: track == null ? null : queue.next,
          );
    final queueBtn = IconButton(
      icon: const Icon(PhosphorIconsRegular.queue),
      color: c.fgDim,
      tooltip: 'Queue',
      onPressed: () => context.push('/queue'),
    );
    final lyricsBtn = IconButton(
      icon: const Icon(PhosphorIconsRegular.microphoneStage),
      color: c.fgDim,
      tooltip: 'Now playing / lyrics',
      onPressed: track == null ? null : () => context.push('/now-playing'),
    );

    // Floating frosted pill: inset from the window edges, soft shadow on the
    // outer (unclipped) box, translucent fill + backdrop blur inside the clip
    // so content scrolling under it frosts through.
    final bar = Padding(
      padding: const EdgeInsets.fromLTRB(
          AriaSpace.s3, 0, AriaSpace.s3, AriaSpace.s2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AriaRadius.lg),
          boxShadow: surfaceShadow,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AriaRadius.lg),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: AriaSpace.s3),
              decoration: BoxDecoration(
                color: c.bgRaised.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(AriaRadius.lg),
                border: Border.all(color: c.line),
              ),
              // opaque: the pill floats over content, so its whole body must
              // absorb taps/scrolls rather than leak them to the list behind.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Bottom safe-area so the bar clears Android gesture handles,
                // with a little breathing room even without a system inset.
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
                          if (roomy) const SignalPathDot(),
                          prevBtn,
                          playBtn,
                          nextBtn,
                          if (roomy) lyricsBtn,
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
                          spacing: AriaSpace.s5,
                          children: [
                            const SignalPathDot(),
                            prevBtn,
                            playBtn,
                            nextBtn,
                            lyricsBtn,
                            queueBtn,
                          ],
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
                        // Lyrics/queue moved beside the transport; the quality
                        // dot (left of prev) now fronts the signal path. Only
                        // volume rides the right edge here.
                        SizedBox(
                          width: 130,
                          child: Row(
                            children: [
                              Icon(PhosphorIconsRegular.speakerHigh,
                                  size: 16, color: c.fgDim),
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
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
            ), // GestureDetector (opaque hit area)
            ), // Container (translucent fill)
          ), // BackdropFilter
        ), // ClipRRect
      ), // DecoratedBox (shadow)
    ); // Padding (float margin)

    return bar;
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
          child: Icon(PhosphorIconsRegular.radio, size: 22, color: c.fgDim),
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
