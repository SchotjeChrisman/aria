import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/formats.dart';
import '../../core/library_providers.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/album_card.dart';
import '../../widgets/artist_avatar.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/selection_highlight.dart';
import '../../widgets/shelf.dart';
import '../../widgets/track_actions.dart';
import '../library/library_providers.dart' show albumByIdProvider;
import 'charts.dart';
import 'stats_providers.dart';

String _plays(int n) => '$n play${n == 1 ? '' : 's'}';

class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(statsProvider);

    return Scaffold(
      body: SafeArea(
        child: switch (stats) {
          AsyncError() => const EmptyState(
            message: 'Stats unavailable.',
            icon: Icons.bar_chart,
          ),
          AsyncData(:final value) => RefreshIndicator(
            onRefresh: () => ref.refresh(statsProvider.future),
            child: _StatsBody(stats: value),
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _StatsBody extends ConsumerWidget {
  const _StatsBody({required this.stats});

  final Stats stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final byId = ref.watch(trackByIdProvider);
    final albums = ref.watch(albumByIdProvider);
    final people = ref.watch(peopleProvider).value ?? const {};
    final client = ref.watch(apiClientProvider);
    final queue = ref.read(queueProvider.notifier);
    final current = ref.watch(currentTrackProvider);
    final c = AriaColors.of(context);
    final h2 = Theme.of(context).textTheme.titleMedium;

    final topTracks = [
      for (final x in stats.topTracks)
        if (byId[x.id] != null) (t: byId[x.id]!, c: x.count),
    ].take(25).toList();
    final topAlbums = [
      for (final x in stats.topAlbums)
        if (albums[x.albumId] != null) (a: albums[x.albumId]!, c: x.count),
    ].take(20).toList();
    final topArtists = stats.topArtists.take(25).toList();
    final charts = stats.history.isNotEmpty
        ? _buildCharts(stats.history)
        : null;

    return ListView(
      padding: const EdgeInsets.all(AriaSpace.s6),
      children: [
        Text('Stats', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AriaSpace.s5),

        // Legacy stat-tiles: Total plays / Listening time / Tracks played.
        Wrap(
          spacing: AriaSpace.s3,
          runSpacing: AriaSpace.s3,
          children: [
            _StatTile(num_: '${stats.totalPlays}', label: 'Total plays'),
            _StatTile(
              num_: formatListenTime(stats.totalSeconds),
              label: 'Listening time',
            ),
            _StatTile(
              num_:
                  '${stats.uniqueTracks > 0 ? stats.uniqueTracks : stats.recent.length}',
              label: 'Tracks played',
            ),
          ],
        ),

        // Listening charts from the raw 30-day history (legacy buildListening).
        if (charts != null) ...[
          const SizedBox(height: AriaSpace.s8),
          Text('Listening', style: h2),
          const SizedBox(height: AriaSpace.s3),
          if (AriaBreakpoint.of(context) == AriaBreakpoint.mobile)
            Column(
              children: [
                charts.$1,
                const SizedBox(height: AriaSpace.s3),
                charts.$2,
              ],
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: charts.$1),
                const SizedBox(width: AriaSpace.s3),
                Expanded(child: charts.$2),
              ],
            ),
        ],

        if (topTracks.isNotEmpty) ...[
          const SizedBox(height: AriaSpace.s8),
          Text('Top Tracks', style: h2),
          const SizedBox(height: AriaSpace.s2),
          // Legacy rows: rank, title + artist · album, play count; tap plays
          // the top-track list from that row.
          for (var i = 0; i < topTracks.length; i++)
            SelectionHighlight(
              kind: 'track',
              itemKey: topTracks[i].t.id,
              child: InkWell(
                onTap: () {
                  if (selectionTapHandled(
                    ref,
                    trackSelectionItem(topTracks[i].t),
                  )) {
                    return;
                  }
                  queue.playQueue([for (final x in topTracks) x.t], i);
                },
                onSecondaryTapUp: (d) => showAriaContextMenu(
                  context,
                  d.globalPosition,
                  trackMenuItems(context, ref, topTracks[i].t),
                ),
                borderRadius: BorderRadius.circular(AriaRadius.md),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AriaSpace.s3,
                    vertical: AriaSpace.s2,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 34,
                        child: Text(
                          current?.id == topTracks[i].t.id ? '▶' : '${i + 1}',
                          style: TextStyle(
                            color: current?.id == topTracks[i].t.id
                                ? c.accent
                                : c.fgDim,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              topTracks[i].t.title ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: current?.id == topTracks[i].t.id
                                    ? c.accent
                                    : c.fg,
                              ),
                            ),
                            Text(
                              [
                                topTracks[i].t.artist,
                                topTracks[i].t.album,
                              ].nonNulls.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AriaSpace.s3),
                      Text(
                        _plays(topTracks[i].c),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],

        if (topAlbums.isNotEmpty) ...[
          const SizedBox(height: AriaSpace.s8),
          Shelf(
            title: 'Top Albums',
            height: 226,
            itemCount: topAlbums.length,
            itemBuilder: (context, i) {
              final x = topAlbums[i];
              return AlbumCard(
                title: x.a.title,
                subtitle: _plays(x.c),
                artUrl: x.a.hasArt ? client.artUrl(x.a.id) : null,
                onTap: () => queue.playQueue(x.a.tracks, 0),
                onSecondary: (pos) => showAriaContextMenu(
                  context,
                  pos,
                  albumMenuItems(
                    context,
                    ref,
                    albumId: x.a.id,
                    tracks: x.a.tracks,
                    artistName: x.a.albumArtist,
                  ),
                ),
              );
            },
          ),
        ],

        if (topArtists.isNotEmpty) ...[
          const SizedBox(height: AriaSpace.s8),
          Text('Top Artists', style: h2),
          const SizedBox(height: AriaSpace.s3),
          SizedBox(
            height: 130,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: topArtists.length,
              separatorBuilder: (_, _) => const SizedBox(width: AriaSpace.s4),
              itemBuilder: (context, i) {
                final x = topArtists[i];
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ArtistAvatar(
                      name: x.name,
                      imageUrl: people[x.name],
                      size: 72,
                    ),
                    const SizedBox(height: AriaSpace.s2),
                    SizedBox(
                      width: 96,
                      child: Column(
                        children: [
                          Text(
                            x.name,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5),
                          ),
                          Text(
                            _plays(x.count),
                            style: TextStyle(fontSize: 11.5, color: c.fgDim),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],

        if (stats.totalPlays == 0)
          const EmptyState(
            message: 'No plays yet — go listen to something.',
            icon: Icons.music_note_outlined,
          ),
      ],
    );
  }

  /// Legacy buildListening bucketing: last 30 days in the viewer's timezone,
  /// plus a 24-slot hour-of-day histogram.
  (Widget, Widget) _buildCharts(List<PlayRef> history) {
    String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';
    final days = <String, ({String label, int n})>{};
    final now = DateTime.now();
    for (var i = 29; i >= 0; i--) {
      final d = now.subtract(Duration(days: i));
      days[dayKey(d)] = (label: '${d.month}/${d.day}', n: 0);
    }
    final hours = List.filled(24, 0);
    for (final p in history) {
      final d = DateTime.tryParse(p.at)?.toLocal();
      if (d == null) continue;
      final k = dayKey(d);
      final day = days[k];
      if (day != null) days[k] = (label: day.label, n: day.n + 1);
      hours[d.hour]++;
    }
    return (
      BarChart(
        title: 'Plays · last 30 days',
        points: [
          for (final e in days.values)
            ChartPoint(value: e.n, tip: '${e.label} · ${_plays(e.n)}'),
        ],
      ),
      BarChart(
        title: 'By hour of day',
        points: [
          for (var h = 0; h < 24; h++)
            ChartPoint(
              value: hours[h],
              tip: '${h.toString().padLeft(2, '0')}:00 · ${_plays(hours[h])}',
            ),
        ],
      ),
    );
  }
}

/// Legacy .stat-tile: big number over a dim label.
class _StatTile extends StatelessWidget {
  const _StatTile({required this.num_, required this.label});

  final String num_;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 140),
      padding: const EdgeInsets.all(AriaSpace.s4),
      decoration: BoxDecoration(
        color: c.bgRaised,
        borderRadius: BorderRadius.circular(AriaRadius.md),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            num_,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 12, color: c.fgDim)),
        ],
      ),
    );
  }
}
