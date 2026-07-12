import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/phosphor_icons.dart';

import '../../core/connection.dart';
import '../../core/toast.dart';
import '../../core/formats.dart';
import '../../core/player_providers.dart';
import '../../core/playlists_providers.dart';
import '../../core/theme.dart';
import '../../widgets/art_image.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/tag_picker.dart';
import '../../widgets/track_actions.dart';
import 'providers.dart';
import 'transport_bar.dart';

const double _rowH = 56.0;

/// Play queue (legacy #queue-panel / renderQueue): played history dimmed
/// above the accented current row, drag handle to reorder (qMove semantics),
/// per-row remove (qRemove semantics), clear, save-as-playlist.
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key});

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen> {
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    // Open at the current song: played history is above (scroll up),
    // upcoming below (scroll down). Fixed _rowH per row, clamped by the list.
    final i = ref.read(queueProvider).index;
    _scroll = ScrollController(initialScrollOffset: i > 0 ? i * _rowH : 0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = ref.watch(queueProvider);
    final c = AriaColors.of(context);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: c.bg,
        elevation: 0,
        title: Text(
          q.tracks.isEmpty ? 'Queue' : 'Queue — ${q.tracks.length} tracks',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        actions: [
          if (q.tracks.isNotEmpty) ...[
            TextButton.icon(
              icon: const Icon(PhosphorIconsRegular.listPlus, size: 18),
              label: const Text('Save as playlist'),
              onPressed: () => _saveAsPlaylist(context),
            ),
            IconButton(
              icon: const Icon(PhosphorIconsRegular.broom),
              tooltip: 'Clear queue',
              onPressed: ref.read(queueProvider.notifier).clear,
            ),
          ],
          const SizedBox(width: AriaSpace.s2),
        ],
      ),
      body: q.tracks.isEmpty
          ? const EmptyState(
              message: 'Queue is empty.',
              icon: PhosphorIconsRegular.queue,
            )
          : Column(
              children: [
                const _QueueLeftBanner(),
                Expanded(
                  child: ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    scrollController: _scroll,
                    physics: _DampenUpPhysics(
                      boundary: q.index * _rowH,
                      parent: const ClampingScrollPhysics(),
                    ),
                    padding: const EdgeInsets.only(bottom: AriaSpace.s8),
                    itemCount: q.tracks.length,
                    // onReorderItem's newIndex is post-removal; core move()
                    // wants the pre-move insertion index (legacy qMove dest
                    // semantics).
                    onReorderItem: (oldIndex, newIndex) {
                      final dest = newIndex > oldIndex ? newIndex + 1 : newIndex;
                      ref.read(queueProvider.notifier).move([oldIndex], dest);
                    },
                    itemBuilder: (context, i) => _QueueRow(
                      // Same track can be queued twice; the index keeps keys
                      // unique.
                      key: ValueKey('q$i-${q.tracks[i].id}'),
                      track: q.tracks[i],
                      index: i,
                      isCurrent: i == q.index,
                      isPlayed: i < q.index,
                    ),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: const TransportBar(),
    );
  }

  Future<void> _saveAsPlaylist(BuildContext context) async {
    final tracks = ref.read(queueProvider).tracks;
    if (tracks.isEmpty) return;
    final toast = Toaster.of(context);

    final ctrl = TextEditingController();
    final String? name;
    try {
      name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Save queue as playlist'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 60,
            decoration: const InputDecoration(hintText: 'Playlist name'),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(ctrl.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;

    try {
      // Core playlists notifier scopes to the reactive active profile —
      // switching profiles re-attributes new playlists immediately.
      final notifier = ref.read(playlistsProvider.notifier);
      final pl = await notifier.createManual(trimmed);
      await notifier.addTracks(pl.id, [for (final t in tracks) t.id]);
      toast.show('Saved ${tracks.length} tracks to "$trimmed"');
    } on StateError catch (e) {
      toast.show(e.message, error: true);
    } catch (_) {
      toast.show('Could not save playlist.', error: true);
    }
  }
}

class _QueueRow extends ConsumerWidget {
  const _QueueRow({
    super.key,
    required this.track,
    required this.index,
    required this.isCurrent,
    required this.isPlayed,
  });

  final Track track;
  final int index;
  final bool isCurrent;
  final bool isPlayed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final notifier = ref.read(queueProvider.notifier);
    final fg = isCurrent ? c.accent : c.fg;
    final dim = isCurrent ? c.accent : c.fgDim;

    final row = Row(
      children: [
        ReorderableDragStartListener(
          index: index,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AriaSpace.s2),
            child: Icon(PhosphorIconsRegular.dotsSixVertical, size: 18, color: c.fgDim),
          ),
        ),
        ArtImage(
          url: ref
              .read(apiClientProvider)
              .artUrl(track.albumId, version: track.artVersion),
          fallbackText: track.album,
          size: 40,
          borderRadius: AriaRadius.sm,
        ),
        const SizedBox(width: AriaSpace.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${isCurrent ? '▶ ' : ''}${trackTitleLine(track)}',
                style: TextStyle(color: fg),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                trackSubLine(track),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall!.copyWith(color: dim),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: AriaSpace.s3),
        Text(
          formatDuration(track.duration),
          style: TextStyle(
            color: dim,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        IconButton(
          icon: const Icon(PhosphorIconsRegular.x, size: 16),
          color: c.fgDim,
          tooltip: 'Remove',
          onPressed: () => notifier.removeIndices([index]),
        ),
      ],
    );

    final content = GestureDetector(
      onSecondaryTapUp: (d) => _menu(context, ref, d.globalPosition),
      onLongPressStart: (d) => _menu(context, ref, d.globalPosition),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // Legacy dblclick-to-play; tap is the natural port with selection
          // handled by the context menu instead.
          onTap: () => notifier.playAt(index),
          hoverColor: c.bgHover,
          child: Opacity(
            opacity: isPlayed ? 0.55 : 1, // legacy .q-played
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AriaSpace.s2,
                vertical: 6,
              ),
              child: row,
            ),
          ),
        ),
      ),
    );
    final sized = SizedBox(height: _rowH, child: content);
    if (!isCurrent) return sized;
    // Visible separator dividing the current song from upcoming tracks.
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.accent, width: 2)),
      ),
      child: sized,
    );
  }

  // Legacy queueCtx: Play now / Move next / Remove / Add to playlist / tag /
  // Go to album / Go to artist.
  void _menu(BuildContext context, WidgetRef ref, Offset pos) {
    final notifier = ref.read(queueProvider.notifier);
    showAriaContextMenu(context, pos, [
      AriaMenuItem(
        'Play now',
        () => notifier.playAt(index),
        icon: PhosphorIconsRegular.play,
      ),
      AriaMenuItem(
        'Move next',
        // legacy: insert right after the current track
        () => notifier.move([index], ref.read(queueProvider).index + 1),
        icon: PhosphorIconsRegular.rowsPlusTop,
      ),
      AriaMenuItem(
        'Add to playlist…',
        () => showAddToPlaylistMenu(context, tracks: [track]),
        icon: PhosphorIconsRegular.listChecks,
      ),
      AriaMenuItem(
        'Tags…',
        () => showTagPicker(context, kind: 'track', key: track.id),
        icon: PhosphorIconsRegular.tag,
      ),
      AriaMenuItem(
        'Go to album',
        // go, not push: see now_playing_screen — this screen is above the
        // shell, the destinations are inside shell branches.
        () => context.go(albumPath(track.albumId)),
        icon: PhosphorIconsRegular.vinylRecord,
      ),
      if ((track.artist ?? '').isNotEmpty)
        AriaMenuItem(
          'Go to artist',
          () => context.go(artistPath(track.artist!)),
          icon: PhosphorIconsRegular.user,
        ),
      AriaMenuItem(
        'Remove from queue',
        () => notifier.removeIndices([index]),
        icon: PhosphorIconsRegular.x,
        destructive: true,
      ),
    ]);
  }
}

String _queueLeft(double secs) {
  final m = (secs / 60).round();
  final body = m < 60 ? '$m min' : '${m ~/ 60}h ${m % 60}m';
  return '$body left in queue';
}

/// Thin non-scrolling banner: remainder of the current track + all upcoming.
class _QueueLeftBanner extends ConsumerWidget {
  const _QueueLeftBanner();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final q = ref.watch(queueProvider);
    final pos = ref.watch(playbackPositionProvider).value ?? 0;
    final curDur = ref.watch(currentDurationProvider);
    if (q.tracks.isEmpty) return const SizedBox.shrink();
    final upcoming = q.tracks
        .skip(q.index + 1)
        .fold<double>(0, (s, t) => s + (t.duration ?? 0));
    final left = (curDur - pos).clamp(0, double.infinity) + upcoming;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AriaSpace.s4,
        0,
        AriaSpace.s4,
        AriaSpace.s2,
      ),
      child: Text(
        _queueLeft(left.toDouble()),
        style: Theme.of(context).textTheme.bodySmall!.copyWith(color: c.accent),
      ),
    );
  }
}

/// Dampens upward flings/drags into already-played history so scrolling back
/// up past the current song meets a bit of resistance.
class _DampenUpPhysics extends ScrollPhysics {
  const _DampenUpPhysics({required this.boundary, super.parent});
  final double boundary;
  @override
  _DampenUpPhysics applyTo(ScrollPhysics? ancestor) =>
      _DampenUpPhysics(boundary: boundary, parent: buildParent(ancestor));
  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    // In Flutter, a NEGATIVE offset moves toward minScrollExtent (up, into
    // already-played history). Dampen that once at/above the current song.
    if (offset < 0 && position.pixels <= boundary) {
      return super.applyPhysicsToUserOffset(position, offset * 0.35);
    }
    return super.applyPhysicsToUserOffset(position, offset);
  }
}
