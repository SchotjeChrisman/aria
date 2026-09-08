import 'dart:math' as math;

import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/phosphor_icons.dart';

import '../../core/connection.dart';
import '../../core/downloads.dart';
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

/// Legacy renderTracks' comparator, lifted out of the provider so any list of
/// tracks (a playlist's, say) sorts by the same columns in the same order.
List<Track> sortTracks(
  List<Track> list,
  TracksSort s,
  Map<String, int>? counts,
) {
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
  // Decorate-sort-undecorate: the keys (format text, lowercasing, genre
  // joins) are expensive — compute them once per track, not per comparison.
  final decorated = [
    for (final t in list) (keyFn(t), str(t.artist), str(t.title), t),
  ];
  decorated.sort((x, y) {
    final c = x.$1.compareTo(y.$1);
    final tie = c != 0
        ? c
        : (x.$2.compareTo(y.$2) != 0
              ? x.$2.compareTo(y.$2)
              : x.$3.compareTo(y.$3));
    return tie * s.dir;
  });
  return [for (final d in decorated) d.$4];
}

/// Filtered + sorted tracks (legacy renderTracks list building).
final visibleTracksProvider = Provider<List<Track>>((ref) {
  final f = ref.watch(trackFiltersProvider);
  final s = ref.watch(tracksSortProvider);
  final parents = ref.watch(genreParentsProvider);
  final tagIndex = ref.watch(tagNameIndexProvider);
  final favouriteIds = ref.watch(favouriteIdsProvider);
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
        favouriteIds: favouriteIds,
        playCounts: counts,
      ))
        t,
  ];

  return sortTracks(list, s, counts);
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
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Expanded(
          child: TrackTable(
            tracks: list,
            sort: sort,
            onSort: ref.read(tracksSortProvider.notifier).tap,
            plays: counts,
          ),
        ),
      ],
    );
  }
}

/// The Tracks table: sortable column header over 44px rows, scrolled sideways
/// below 900px. The playlist pages render this too, so a playlist's track
/// display IS the library's rather than a lookalike that drifts away from it.
///
/// [sort] + [onSort] hand the sort to the caller (the library's is persisted
/// across sessions). Leave them off and the table owns its own sort, starting
/// unsorted — a playlist shows its own order until a header is clicked.
class TrackTable extends ConsumerStatefulWidget {
  const TrackTable({
    super.key,
    required this.tracks,
    this.sort,
    this.onSort,
    this.plays,
    this.emptyMessage = 'No tracks.',
    this.menuExtra,
  });

  final List<Track> tracks;

  /// Caller-owned sort; null means this table sorts itself. When set, [tracks]
  /// is taken as already sorted.
  final TracksSort? sort;
  final ValueChanged<String>? onSort;

  /// Play counts for the Plays column. Null lets the table fetch them itself,
  /// but only once something sorts by plays (legacy ensurePlayCounts laziness).
  final Map<String, int>? plays;

  final String emptyMessage;

  /// Extra context-menu entries for one track, appended to the usual ones.
  final List<AriaMenuItem> Function(Track track)? menuExtra;

  @override
  ConsumerState<TrackTable> createState() => _TrackTableState();
}

class _TrackTableState extends ConsumerState<TrackTable> {
  TracksSort? _local;

  void _tap(String key) {
    final onSort = widget.onSort;
    if (onSort != null) return onSort(key);
    // Legacy header click: same column flips direction, new column starts asc.
    setState(
      () => _local = TracksSort(key, _local?.key == key ? -_local!.dir : 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final sort = widget.sort ?? _local;
    final plays =
        widget.plays ??
        (sort?.key == 'plays' ? ref.watch(playCountsProvider).value : null);
    // An external sort means the caller already applied it.
    final list = widget.sort != null || sort == null
        ? widget.tracks
        : sortTracks(widget.tracks, sort, plays);
    final currentId = ref.watch(currentTrackProvider)?.id;

    return LayoutBuilder(
      builder: (context, cons) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: math.max(cons.maxWidth, 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TrackHeaderRow(sort: sort, onTap: _tap),
              Divider(height: 1, color: c.lineStrong),
              Expanded(
                child: list.isEmpty
                    ? EmptyState(
                        message: widget.emptyMessage,
                        icon: PhosphorIconsThin.musicNote,
                      )
                    : ListView.builder(
                        // Bypasses ariaPagePadding, so add the floating
                        // transport clearance explicitly.
                        padding: const EdgeInsets.only(
                          bottom: AriaSpace.s6 + transportFloatInset,
                        ),
                        itemCount: list.length,
                        itemExtent: 44,
                        itemBuilder: (context, i) => SelectionHighlight(
                          kind: 'track',
                          itemKey: list[i].id,
                          child: TrackTableRow(
                            track: list[i],
                            index: i,
                            plays: plays?[list[i].id],
                            isCurrent: list[i].id == currentId,
                            onTap: () {
                              final t = list[i];
                              if (selectionTapHandled(
                                ref,
                                trackSelectionItem(t),
                              )) {
                                return;
                              }
                              ref
                                  .read(queueProvider.notifier)
                                  .playQueue(list, i);
                            },
                            menuExtra:
                                widget.menuExtra?.call(list[i]) ?? const [],
                            onSecondary: (pos) => showAriaContextMenu(
                              context,
                              pos,
                              trackMenuItems(
                                context,
                                ref,
                                list[i],
                                extra:
                                    widget.menuExtra?.call(list[i]) ?? const [],
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Column layout shared by the header and every row.
class TrackCells extends StatelessWidget {
  const TrackCells({super.key, required this.builder});

  final Widget Function(String key) builder;

  @override
  Widget build(BuildContext context) {
    Widget cell(String key) => builder(key);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AriaSpace.s6),
      child: Row(
        children: [
          SizedBox(width: 34, child: cell('no')),
          Expanded(flex: 3, child: cell('title')),
          Expanded(flex: 2, child: cell('artist')),
          Expanded(flex: 2, child: cell('album')),
          Expanded(flex: 2, child: cell('genre')),
          SizedBox(width: 48, child: cell('year')),
          SizedBox(width: 52, child: cell('duration')),
          SizedBox(width: 92, child: cell('format')),
          SizedBox(width: 46, child: cell('plays')),
          SizedBox(width: 36, child: cell('menu')),
        ],
      ),
    );
  }
}

class TrackHeaderRow extends StatelessWidget {
  const TrackHeaderRow({super.key, required this.sort, this.onTap});

  /// Null = nothing sorted yet: labels only, no arrow.
  final TracksSort? sort;
  final ValueChanged<String>? onTap;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final labels = {for (final (k, l) in _cols) k: l};
    return TrackCells(
      builder: (key) {
        if (key == 'no' || key == 'menu') return const SizedBox.shrink();
        final active = sort?.key == key;
        return InkWell(
          onTap: onTap == null ? null : () => onTap!(key),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AriaSpace.s2),
            child: Text(
              '${labels[key]}${active ? (sort!.dir == 1 ? ' ▲' : ' ▼') : ''}',
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

class TrackTableRow extends ConsumerWidget {
  const TrackTableRow({
    super.key,
    required this.track,
    required this.index,
    required this.plays,
    required this.isCurrent,
    required this.onTap,
    required this.onSecondary,
    this.menuExtra = const [],
  });

  final Track track;
  final int index;
  final int? plays;
  final bool isCurrent;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onSecondary;

  /// Page-specific verbs for this row's "…" menu, on top of the usual ones.
  final List<AriaMenuItem> menuExtra;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final fg = isCurrent ? c.accent : c.fg;
    final dim = isCurrent ? c.accent : c.fgDim;
    // `select` so a finished download rebuilds its own row, not the table.
    final downloaded = ref.watch(
      downloadsProvider.select((s) => s.index.containsKey(track.id)),
    );

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
          child: TrackCells(
            builder: (key) => switch (key) {
              'no' => txt(
                isCurrent ? '▶' : '${index + 1}',
                color: dim,
                tabular: true,
              ),
              // The offline-available check rides in the title cell rather
              // than a column of its own: a dedicated column would spend
              // width on every row to mark the few that are downloaded.
              'title' => Row(
                children: [
                  Flexible(child: txt(track.title ?? '')),
                  if (downloaded) ...[
                    const SizedBox(width: 6),
                    Icon(
                      PhosphorIconsRegular.checkCircle,
                      size: 13,
                      color: dim,
                    ),
                  ],
                ],
              ),
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
              // The same verbs the right-click gives, reachable with a plain
              // click — nothing lives only behind a secondary button.
              'menu' => TrackMenuButton(
                track: track,
                color: dim,
                extra: menuExtra,
                dense: true,
              ),
              _ => const SizedBox.shrink(),
            },
          ),
        ),
      ),
    );
  }
}
