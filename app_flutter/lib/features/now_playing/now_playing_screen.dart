import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/art_image.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/track_actions.dart';
import 'providers.dart';
import 'seek_bar.dart';
import 'signal_path.dart';

/// Expanded now-playing (legacy #np-overlay): big art + title/sub + signal
/// path with full-size transport controls inline. Lyrics and queue are their
/// own screens, reachable from the app bar.
class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final c = AriaColors.of(context);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: c.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          tooltip: 'Close',
          onPressed: () => context.pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.lyrics_outlined),
            tooltip: 'Lyrics',
            onPressed: track == null ? null : () => context.push('/lyrics'),
          ),
          IconButton(
            icon: const Icon(Icons.queue_music),
            tooltip: 'Queue',
            onPressed: () => context.push('/queue'),
          ),
          const SizedBox(width: AriaSpace.s2),
        ],
      ),
      body: track == null
          ? const EmptyState(message: 'Nothing playing.')
          : SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(AriaSpace.s5),
                        child: _Meta(track: track),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(
                      AriaSpace.s5,
                      0,
                      AriaSpace.s5,
                      AriaSpace.s5,
                    ),
                    child: _Controls(),
                  ),
                ],
              ),
            ),
    );
  }
}

class _Meta extends ConsumerWidget {
  const _Meta({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final artUrl = ref.watch(apiClientProvider).artUrl(track.albumId);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340, maxHeight: 340),
          child: AspectRatio(
            aspectRatio: 1,
            child: GestureDetector(
              onTap: () => context.push(albumPath(track.albumId)),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: ArtImage(
                  url: artUrl,
                  fallbackText: track.album,
                  decodeSize: 340, // hero art is capped at 340 logical px
                  borderRadius: AriaRadius.lg,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AriaSpace.s5),
        Text(
          trackTitleLine(track),
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AriaSpace.s1),
        GestureDetector(
          onTap: (track.artist ?? '').isEmpty
              ? null
              : () => context.push(artistPath(track.artist!)),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Text(
              trackSubLine(track),
              style: TextStyle(fontSize: 15, color: c.fgDim),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(height: AriaSpace.s4),
        const SignalPath(),
      ],
    );
  }
}

/// Full-size transport for the expanded screen: seek with times, shuffle,
/// prev / big play / next. The persistent bar stays on the shell; this
/// replaces it here.
class _Controls extends ConsumerWidget {
  const _Controls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final playing =
        ref.watch(playbackStateProvider).value == PlaybackState.playing;
    final shuffle = ref.watch(queueProvider.select((q) => q.shuffle));
    final queue = ref.read(queueProvider.notifier);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Position/duration live inside SeekBar so time-pos ticks don't
          // rebuild the controls block.
          const SeekBar(thumbRadius: 7),
          const SizedBox(height: AriaSpace.s2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.shuffle),
                iconSize: 24,
                color: shuffle ? c.accent : c.fgDim,
                tooltip: 'Shuffle',
                onPressed: queue.toggleShuffle,
              ),
              const SizedBox(width: AriaSpace.s3),
              IconButton(
                icon: const Icon(Icons.skip_previous),
                iconSize: 40,
                color: c.fg,
                tooltip: 'Previous',
                onPressed: queue.prev,
              ),
              const SizedBox(width: AriaSpace.s3),
              IconButton.filled(
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                iconSize: 40,
                padding: const EdgeInsets.all(AriaSpace.s3),
                tooltip: 'Play/Pause',
                onPressed: queue.togglePlay,
              ),
              const SizedBox(width: AriaSpace.s3),
              IconButton(
                icon: const Icon(Icons.skip_next),
                iconSize: 40,
                color: c.fg,
                tooltip: 'Next',
                onPressed: queue.next,
              ),
              const SizedBox(width: AriaSpace.s3),
              // Symmetry slot for shuffle; volume lives on the shell bar.
              const SizedBox(width: 40),
            ],
          ),
        ],
      ),
    );
  }
}
