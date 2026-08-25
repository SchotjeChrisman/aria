import 'package:aria/core/player_providers.dart';
import 'package:aria/core/theme.dart';
import 'package:aria/features/now_playing/lrc.dart';
import 'package:aria/features/now_playing/lyrics_view.dart';
import 'package:aria/features/now_playing/now_playing_screen.dart';
import 'package:aria/features/now_playing/queue_screen.dart';
import 'package:aria/features/now_playing/seek_bar.dart';
import 'package:aria/features/now_playing/signal_path.dart';
import 'package:aria/features/now_playing/transport_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:widgetbook/widgetbook.dart';

import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// Playback components. The audio engine is never initialised here — libmpv
/// only loads in `initialize()`, and every command is guarded — but the real
/// QueueNotifier runs, so loading the queue below genuinely puts a current
/// track behind every widget on these pages.

/// Puts the fixture album in the queue, so the components that read the
/// current track have one. Not a component: a story control, and the only
/// way to see these widgets in their loaded state without faking a provider.
///
/// It loads on mount rather than waiting for the button, because half these
/// widgets return `SizedBox.shrink()` with nothing playing — a use case that
/// draws nothing until you press something is a use case that shows nothing
/// in a screenshot. The buttons stay, for clearing and reloading by hand.
class _QueueLoader extends ConsumerStatefulWidget {
  const _QueueLoader();

  @override
  ConsumerState<_QueueLoader> createState() => _QueueLoaderState();
}

class _QueueLoaderState extends ConsumerState<_QueueLoader> {
  @override
  void initState() {
    super.initState();
    // Post-frame: playQueue mutates a provider, which cannot happen while the
    // tree that reads it is still building. Only when the queue is empty, so
    // switching use cases does not stamp on a queue you set up by hand.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(queueProvider).tracks.isEmpty) {
        ref.read(queueProvider.notifier).playQueue(fixtureTracks, 0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(currentTrackProvider);
    return Wrap(
      spacing: AriaSpace.s3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton(
          onPressed: () =>
              ref.read(queueProvider.notifier).playQueue(fixtureTracks, 0),
          child: const Text('Load the queue'),
        ),
        OutlinedButton(
          onPressed: () =>
              ref.read(queueProvider.notifier).playQueue(const [], 0),
          child: const Text('Clear'),
        ),
        Text(
          current == null ? 'nothing loaded' : 'current: ${current.title}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

Widget seekBarStory(BuildContext context) {
  final thumb = context.knobs.double
      .slider(label: 'thumb radius', initialValue: 6, min: 2, max: 14);

  return StoryPage(
    children: [
      const Section(
        title: 'Load a track',
        note: 'The engine stays silent — position never advances — but the '
            'labels and the disabled state are real.',
        child: _QueueLoader(),
      ),
      Section(
        title: 'SeekBar',
        note: 'Dragging the thumb pins the displayed position until release, '
            'so the engine\'s own ticks cannot fight the finger.',
        child: SeekBar(thumbRadius: thumb),
      ),
      const Section(
        title: 'Without times',
        note: 'The elapsed/total labels are dropped on cramped layouts; the '
            'slider keeps the full width.',
        child: SeekBar(showTimes: false),
      ),
      const Section(
        title: 'Live stream',
        note: 'Radio has no seek: the slider is disabled and nothing is '
            'watched, rather than showing a position that cannot be moved.',
        child: SeekBar(live: true),
      ),
    ],
  );
}

Widget timeLabelStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'TimeLabel',
        note: 'Seconds to m:ss, tabular so the digits do not jitter as the '
            'position ticks.',
        child: Wrap(
          spacing: 24,
          children: [
            TimeLabel(0),
            TimeLabel(9),
            TimeLabel(65.4),
            TimeLabel(545.5),
            TimeLabel(3725),
          ],
        ),
      ),
    ],
  );
}

Widget transportBarStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(title: 'Load a track', child: _QueueLoader()),
      Section(
        title: 'TransportBar',
        note: 'The persistent bottom bar: art, metadata, transport, seek, '
            'volume and the signal-path dot. It collapses by band rather than '
            'by pixel width, so the same controls drop out at the same place '
            'on every device.',
        child: TransportBar(),
      ),
      Section(
        title: 'PlaybackUnavailableBanner',
        note: 'Shown when libmpv failed to load — on web it always does. Says '
            'what is missing rather than failing silently on every tap.',
        child: PlaybackUnavailableBanner(),
      ),
    ],
  );
}

Widget nowPlayingMetaStory(BuildContext context) {
  final edge = context.knobs.double
      .slider(label: 'art edge', initialValue: 280, min: 120, max: 420);

  return StoryPage(
    children: [
      Section(
        title: 'NowPlayingMeta',
        note: 'Cover, title, artist and album for the expanded screen. The '
            'art edge is passed in because the screen computes it from the '
            'shorter viewport side, not from the widget.',
        child: NowPlayingMeta(track: hiResTrack, artEdge: edge),
      ),
      Section(
        title: 'No artwork, long title',
        child: NowPlayingMeta(track: lossyTrack, artEdge: 200),
      ),
    ],
  );
}

Widget nowPlayingControlsStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(title: 'Load a track', child: _QueueLoader()),
      Section(
        title: 'NowPlayingControls',
        note: 'Shuffle, previous, play/pause, next, repeat — the expanded '
            'screen\'s row, larger than the transport bar\'s and with the '
            'modes included.',
        child: NowPlayingControls(),
      ),
    ],
  );
}

Widget queueRowStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'QueueRow',
        note: 'Three states in one row: already played (dimmed), current '
            '(accented), and still to come. Drag to reorder is the screen\'s '
            'job, not the row\'s.',
        child: Column(
          children: [
            for (final (i, t) in fixtureTracks.take(5).indexed)
              Variant(
                label: i < 2
                    ? 'played'
                    : i == 2
                        ? 'current'
                        : 'upcoming',
                child: QueueRow(
                  track: t,
                  index: i,
                  isCurrent: i == 2,
                  isPlayed: i < 2,
                ),
              ),
          ],
        ),
      ),
      const Section(title: 'Load a track', child: _QueueLoader()),
      const Section(
        title: 'QueueLeftBanner',
        note: 'How much of the queue is still ahead, in tracks and time. '
            'Reads the queue directly, so it disappears once nothing is '
            'loaded.',
        child: QueueLeftBanner(),
      ),
    ],
  );
}

Widget lyricsStory(BuildContext context) {
  final lines = parseLrc(fixtureLyricsJson['synced']! as String) ?? const [];

  return StoryPage(
    children: [
      const Section(title: 'Load a track', child: _QueueLoader()),
      const Section(
        title: 'LyricsView',
        note: 'Fetches by track id and picks the synced view when the server '
            'has LRC, the plain one when it only has text.',
        child: SizedBox(height: 320, child: LyricsView()),
      ),
      Section(
        title: 'SyncedLyrics',
        note: 'The active line is centred as the position crosses its '
            'timestamp. With the engine silent it sits on the first line, '
            'which is the state it starts in anyway.',
        child: SizedBox(height: 320, child: SyncedLyrics(lines: lines)),
      ),
      Section(
        title: 'Parsed lines',
        note: 'What parseLrc returns for the fixture — timestamps in seconds, '
            'text trimmed.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final l in lines)
              Text(
                '${l.t.toStringAsFixed(2)}  ${l.text}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    ],
  );
}

Widget signalPathStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(title: 'Load a track', child: _QueueLoader()),
      Section(
        title: 'SignalPathDot',
        note: 'The compact indicator on the transport bar: one dot in the '
            'colour of the WORST stage in the chain, because a path is only '
            'as good as its weakest link.',
        child: SignalPathDot(),
      ),
      Section(
        title: 'SignalPath',
        note: 'The expanded sheet: source, processing and output as a rail of '
            'stages, each graded on its own.',
        child: SignalPath(),
      ),
    ],
  );
}

Widget signalPartsStory(BuildContext context) {
  const stages = <SignalStage>[
    (
      name: 'Source',
      detail: 'FLAC 24-bit / 192 kHz',
      short: 'FLAC 24/192',
      tier: SignalTier.bitPerfect,
    ),
    (
      name: 'Equaliser',
      detail: 'Harman 2018, 3 bands',
      short: 'EQ',
      tier: SignalTier.enhanced,
    ),
    (
      name: 'Output',
      detail: 'CoreAudio, 24-bit / 192 kHz',
      short: '24/192',
      tier: SignalTier.bitPerfect,
    ),
  ];

  return StoryPage(
    children: [
      Section(
        title: 'SignalDot',
        note: 'The grade, as a filled circle. Every tier the app can report, '
            'including the red one held back until the player exposes a '
            'persistent output failure to drive it.',
        child: Wrap(
          spacing: AriaSpace.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final t in SignalTier.values)
              Variant(
                label: t.label,
                child: SignalDot(color: t.color, size: 14),
              ),
          ],
        ),
      ),
      Section(
        title: 'SignalStageRow',
        note: 'One node of the chain with its rail. `first` and `last` hide '
            'the rail above and below, so the line starts and stops at the '
            'end stages instead of running off them.',
        child: Column(
          children: [
            for (final (i, stage) in stages.indexed)
              SignalStageRow(
                stage: stage,
                first: i == 0,
                last: i == stages.length - 1,
              ),
          ],
        ),
      ),
      Section(
        title: 'SignalTierChip',
        note: 'The tier as a labelled chip, used at the head of the sheet.',
        child: Wrap(
          spacing: AriaSpace.s3,
          runSpacing: AriaSpace.s3,
          children: [
            for (final t in SignalTier.values) SignalTierChip(tier: t),
          ],
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final nowPlayingEntries = <Entry>[
  Entry(
    folder: 'Transport',
    component: 'TransportBar',
    key: 'transport-bar',
    builder: transportBarStory,
  ),
  Entry(
    folder: 'Transport',
    component: 'SeekBar',
    key: 'seek-bar',
    builder: seekBarStory,
  ),
  Entry(
    folder: 'Transport',
    component: 'TimeLabel',
    key: 'time-label',
    builder: timeLabelStory,
  ),
  Entry(
    folder: 'Now playing',
    component: 'NowPlayingMeta',
    key: 'now-playing-meta',
    builder: nowPlayingMetaStory,
  ),
  Entry(
    folder: 'Now playing',
    component: 'NowPlayingControls',
    key: 'now-playing-controls',
    builder: nowPlayingControlsStory,
  ),
  Entry(
    folder: 'Now playing',
    component: 'Lyrics',
    key: 'lyrics',
    builder: lyricsStory,
  ),
  Entry(
    folder: 'Queue',
    component: 'QueueRow',
    key: 'queue-row',
    builder: queueRowStory,
  ),
  Entry(
    folder: 'Signal path',
    component: 'SignalPath',
    key: 'signal-path',
    builder: signalPathStory,
  ),
  Entry(
    folder: 'Signal path',
    component: 'Signal path parts',
    key: 'signal-path-parts',
    builder: signalPartsStory,
  ),
];
