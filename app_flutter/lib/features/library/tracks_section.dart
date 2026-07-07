import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/formats.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/selection_highlight.dart';
import '../../widgets/track_actions.dart';
import 'library_providers.dart';
import 'track_filters.dart';

// The Tracks browse view (legacy renderTracks): rich filter dialog + a
// sortable column table (title/artist/album/genre/year/duration/format/
// plays) with the sort persisted across sessions.

const _prefsKeySort = 'aria.sort.default.tracks';

@immutable
class TracksSort {
  const TracksSort(this.key, this.dir);

  final String key;
  final int dir; // 1 asc, -1 desc
}

class TracksSortNotifier extends Notifier<TracksSort> {
  @override
  TracksSort build() {
    final saved = ref.read(sharedPrefsProvider).getString(_prefsKeySort);
    final parts = saved?.split(':');
    if (parts != null && parts.length == 2) {
      return TracksSort(parts[0], parts[1] == '-1' ? -1 : 1);
    }
    return const TracksSort('artist', 1);
  }

  /// Legacy header click: same column flips direction, new column starts asc.
  void tap(String key) {
    state = TracksSort(key, state.key == key ? -state.dir : 1);
    ref
        .read(sharedPrefsProvider)
        .setString(_prefsKeySort, '${state.key}:${state.dir}');
  }
}

final tracksSortProvider = NotifierProvider<TracksSortNotifier, TracksSort>(
  TracksSortNotifier.new,
);

/// Filtered + sorted tracks (legacy renderTracks list building).
final visibleTracksProvider = Provider<List<Track>>((ref) {
  final f = ref.watch(trackFiltersProvider);
  final s = ref.watch(tracksSortProvider);
  final parents = ref.watch(genreParentsProvider);
  final tagIndex = ref.watch(tagNameIndexProvider);
  // Counts load lazily, only once the played filter or plays sort needs
  // them (legacy ensurePlayCounts).
  final needCounts = f.played != null || s.key == 'plays';
  final counts = needCounts ? ref.watch(playCountsProvider).value : null;

  final list = [
    for (final t in ref.watch(loadedTracksProvider))
      if (trackPassesFilters(
        t,
        f,
        genreParents: parents,
        tagIndex: tagIndex,
        playCounts: counts,
      ))
        t,
  ];

  String str(String? v) => (v ?? '').toLowerCase();
  Comparable keyFn(Track t) => switch (s.key) {
    'title' => str(t.title),
    'album' => str(t.album),
    'genre' => trackGenres(t).join(', ').toLowerCase(),
    'year' => t.year ?? 0,
    'duration' => t.duration ?? 0,
    'format' => str(
      formatBadgeText(
        format: t.format,
        bitsPerSample: t.bitsPerSample,
        sampleRate: t.sampleRate,
      ),
    ),
    'plays' => counts?[t.id] ?? 0,
    _ => str(t.artist),
  };
  list.sort((x, y) {
    final c = keyFn(x).compareTo(keyFn(y));
    final tie = c != 0
        ? c
        : (str(x.artist).compareTo(str(y.artist)) != 0
              ? str(x.artist).compareTo(str(y.artist))
              : str(x.title).compareTo(str(y.title)));
    return tie * s.dir;
  });
  return list;
});

const _cols = [
  ('title', 'Title'),
  ('artist', 'Artist'),
  ('album', 'Album'),
  ('genre', 'Genre'),
  ('year', 'Year'),
  ('duration', 'Time'),
  ('format', 'Format'),
  ('plays', 'Plays'),
];

class TracksSection extends ConsumerWidget {
  const TracksSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(trackFiltersProvider);
    final sort = ref.watch(tracksSortProvider);
    final list = ref.watch(visibleTracksProvider);
    final counts = (filters.played != null || sort.key == 'plays')
        ? ref.watch(playCountsProvider).value
        : null;
    final currentId = ref.watch(currentTrackProvider)?.id;
    final c = AriaColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AriaSpace.s6,
            AriaSpace.s4,
            AriaSpace.s6,
            AriaSpace.s4,
          ),
          child: Row(
            children: [
              FilterPill(
                label: 'Filters',
                selected: !filters.isEmpty,
                count: filters.activeCount,
                onTap: () => showTrackFilterDialog(context),
              ),
              if (!filters.isEmpty) ...[
                const SizedBox(width: AriaSpace.s2),
                FilterPill(
                  label: 'Clear',
                  onTap: ref.read(trackFiltersProvider.notifier).clear,
                ),
              ],
              const Spacer(),
              Text(
                '${list.length} tracks',
                style: TextStyle(fontSize: 12.5, color: c.fgDim),
              ),
            ],
          ),
        ),
        _HeaderRow(sort: sort),
        Divider(height: 1, color: c.line),
        Expanded(
          child: list.isEmpty
              ? const EmptyState(
                  message: 'No tracks.',
                  icon: Icons.music_note_outlined,
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: AriaSpace.s6),
                  itemCount: list.length,
                  itemExtent: 44,
                  itemBuilder: (context, i) => SelectionHighlight(
                    kind: 'track',
                    itemKey: list[i].id,
                    child: _TrackTableRow(
                      track: list[i],
                      index: i,
                      plays: counts?[list[i].id],
                      isCurrent: list[i].id == currentId,
                      onTap: () {
                        final t = list[i];
                        if (selectionTapHandled(ref, trackSelectionItem(t))) {
                          return;
                        }
                        ref.read(queueProvider.notifier).playQueue(list, i);
                      },
                      onSecondary: (pos) => showAriaContextMenu(
                        context,
                        pos,
                        trackMenuItems(context, ref, list[i]),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Column layout shared by the header and every row; genre/year/plays
/// collapse on narrow layouts.
class _Cells extends StatelessWidget {
  const _Cells({required this.builder});

  final Widget Function(String key, bool narrow) builder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < 760;
        Widget cell(String key) => builder(key, narrow);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: AriaSpace.s6),
          child: Row(
            children: [
              SizedBox(width: 34, child: cell('no')),
              Expanded(flex: 3, child: cell('title')),
              Expanded(flex: 2, child: cell('artist')),
              Expanded(flex: 2, child: cell('album')),
              if (!narrow) Expanded(flex: 2, child: cell('genre')),
              if (!narrow) SizedBox(width: 48, child: cell('year')),
              SizedBox(width: 52, child: cell('duration')),
              SizedBox(width: 92, child: cell('format')),
              if (!narrow) SizedBox(width: 46, child: cell('plays')),
            ],
          ),
        );
      },
    );
  }
}

class _HeaderRow extends ConsumerWidget {
  const _HeaderRow({required this.sort});

  final TracksSort sort;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final labels = {for (final (k, l) in _cols) k: l};
    return _Cells(
      builder: (key, _) {
        if (key == 'no') return const SizedBox.shrink();
        final active = sort.key == key;
        return InkWell(
          onTap: () => ref.read(tracksSortProvider.notifier).tap(key),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AriaSpace.s2),
            child: Text(
              '${labels[key]}${active ? (sort.dir == 1 ? ' ▲' : ' ▼') : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 0.4,
                color: active ? c.accent : c.fgDim,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrackTableRow extends StatelessWidget {
  const _TrackTableRow({
    required this.track,
    required this.index,
    required this.plays,
    required this.isCurrent,
    required this.onTap,
    required this.onSecondary,
  });

  final Track track;
  final int index;
  final int? plays;
  final bool isCurrent;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onSecondary;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final fg = isCurrent ? c.accent : c.fg;
    final dim = isCurrent ? c.accent : c.fgDim;

    Text txt(String s, {Color? color, bool tabular = false}) => Text(
      s,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        color: color ?? fg,
        fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
      ),
    );

    return GestureDetector(
      onSecondaryTapUp: (d) => onSecondary(d.globalPosition),
      onLongPressStart: (d) => onSecondary(d.globalPosition),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverColor: c.bgHover,
          child: _Cells(
            builder: (key, _) => switch (key) {
              'no' => txt(
                isCurrent ? '▶' : '${index + 1}',
                color: dim,
                tabular: true,
              ),
              'title' => txt(track.title ?? ''),
              'artist' => txt(track.artist ?? '', color: dim),
              'album' => txt(track.album ?? '', color: dim),
              'genre' => txt(trackGenres(track).join(', '), color: dim),
              'year' => txt(
                track.year?.toString() ?? '',
                color: dim,
                tabular: true,
              ),
              'duration' => txt(
                formatDuration(track.duration),
                color: dim,
                tabular: true,
              ),
              'format' => txt(
                formatBadgeText(
                  format: track.format,
                  bitsPerSample: track.bitsPerSample,
                  sampleRate: track.sampleRate,
                ),
                color: track.lossless ? c.lossless : dim,
              ),
              'plays' => txt(
                plays?.toString() ?? '',
                color: dim,
                tabular: true,
              ),
              _ => const SizedBox.shrink(),
            },
          ),
        ),
      ),
    );
  }
}
