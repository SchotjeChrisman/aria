import 'dart:math' as math;

import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/formats.dart';
import '../../core/library_providers.dart';
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
/// own screens, reachable from the bottom controls (thumb-reachable on mobile).
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
        actions: const [],
      ),
      body: track == null
          ? const EmptyState(message: 'Nothing playing.')
          : SafeArea(
              child: LayoutBuilder(
                builder: (context, box) => Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(AriaSpace.s5),
                          child: _Meta(
                            track: track,
                            artEdge: nowPlayingArtEdge(box.biggest),
                          ),
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
            ),
    );
  }
}

/// Dedicated ♥ toggle for the current track (independent favourite flag).
class _FavouriteButton extends ConsumerWidget {
  const _FavouriteButton({required this.trackId});

  final String trackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final fav = ref.watch(favouriteIdsProvider).contains(trackId);
    return IconButton(
      icon: Icon(fav ? Icons.favorite : Icons.favorite_border),
      color: fav ? c.accent : c.fgDim,
      tooltip: fav ? 'Remove from favourites' : 'Add to favourites',
      onPressed: () =>
          ref.read(favouriteIdsProvider.notifier).toggle(trackId),
    );
  }
}

/// Hero-art edge for the expanded screen: fill the width on phones, but
/// leave ~340px for the text block + controls so nothing scrolls on a
/// normal portrait screen. Fixed clamp bounds keep tiny/huge windows sane
/// (the parent width constraint still wins below 220).
double nowPlayingArtEdge(Size body) =>
    math.min(body.width - AriaSpace.s5 * 2, body.height - 340).clamp(220, 560);

class _Meta extends ConsumerWidget {
  const _Meta({required this.track, required this.artEdge});

  final Track track;
  final double artEdge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final artUrl = ref
        .watch(apiClientProvider)
        .artUrl(track.albumId, version: track.artVersion);
    // "3 of 12" only when there is an actual queue to navigate.
    final queuePos = ref.watch(
      queueProvider.select(
        (q) => q.tracks.length > 1 ? '${q.index + 1} of ${q.tracks.length}' : null,
      ),
    );
    final genre = track.genres.isNotEmpty ? track.genres.first : track.genre;
    final infoLine = [
      if (track.year != null) '${track.year}',
      if ((genre ?? '').isNotEmpty) genre!,
      if (track.duration != null) formatDuration(track.duration),
      if (queuePos != null) 'Track $queuePos',
    ].join(' · ');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: artEdge, maxHeight: artEdge),
          child: AspectRatio(
            aspectRatio: 1,
            child: GestureDetector(
              // go, not push: this screen sits above the shell and the album/
              // artist routes live inside shell branches — pushing across that
              // boundary corrupts the root navigator (duplicate shell pages).
              onTap: () => context.go(albumPath(track.albumId)),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: ArtImage(
                  url: artUrl,
                  fallbackText: track.album,
                  decodeSize: artEdge,
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
              : () => context.go(artistPath(track.artist!)),
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
        if (infoLine.isNotEmpty) ...[
          const SizedBox(height: AriaSpace.s2),
          Text(
            infoLine,
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: AriaSpace.s4),
        const SignalPath(),
      ],
    );
  }
}

/// Full-size transport for the expanded screen: seek with times, shuffle,
/// prev / big play / next, repeat, plus lyrics/queue links below (moved off
/// the app bar so they sit thumb-reachable under the transport). The
/// persistent bar stays on the shell; this replaces it here.
class _Controls extends ConsumerWidget {
  const _Controls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final track = ref.watch(currentTrackProvider);
    final playing =
        ref.watch(playbackStateProvider).value == PlaybackState.playing;
    final shuffle = ref.watch(queueProvider.select((q) => q.shuffle));
    final loop = ref.watch(queueProvider.select((q) => q.loop));
    final queue = ref.read(queueProvider.notifier);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Position/duration live inside SeekBar so time-pos ticks don't
          // rebuild the controls block.
          const SeekBar(thumbRadius: 9),
          const SizedBox(height: AriaSpace.s2),
          Row(
            // Spread across the (480-capped) width: on phones the gaps grow
            // with the screen, so neighbouring targets are hard to mis-hit.
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.shuffle),
                iconSize: 28,
                color: shuffle ? c.accent : c.fgDim,
                tooltip: 'Shuffle',
                onPressed: queue.toggleShuffle,
              ),
              IconButton(
                icon: const Icon(Icons.skip_previous),
                iconSize: 44,
                color: c.fg,
                tooltip: 'Previous',
                onPressed: queue.prev,
              ),
              IconButton.filled(
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                iconSize: 44,
                padding: const EdgeInsets.all(AriaSpace.s4),
                tooltip: 'Play/Pause',
                onPressed: queue.togglePlay,
              ),
              IconButton(
                icon: const Icon(Icons.skip_next),
                iconSize: 44,
                color: c.fg,
                tooltip: 'Next',
                onPressed: queue.next,
              ),
              IconButton(
                icon: Icon(
                  loop == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                ),
                iconSize: 28,
                color: loop != LoopMode.off ? c.accent : c.fgDim,
                tooltip: 'Repeat',
                onPressed: queue.cycleLoop,
              ),
            ],
          ),
          Row(
            // Lyrics + queue, moved off the app bar to sit under the transport
            // where a thumb reaches on mobile. Same push targets as before.
            // Heart centred, lyrics/queue spread to the edges.
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.lyrics_outlined),
                color: c.fgDim,
                tooltip: 'Lyrics',
                onPressed: () => context.push('/lyrics'),
              ),
              if (track != null) _FavouriteButton(trackId: track.id),
              IconButton(
                icon: const Icon(Icons.queue_music),
                color: c.fgDim,
                tooltip: 'Queue',
                onPressed: () => context.push('/queue'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

