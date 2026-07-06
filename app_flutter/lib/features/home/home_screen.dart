import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/library_providers.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/album_card.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/new_releases_shelf.dart';
import '../../widgets/shelf.dart';
import '../../widgets/track_actions.dart';
import 'home_providers.dart';

/// Legacy renderHome: stat strip, Recently Added, New Releases, Recently
/// Played, 30-day Listening summary, Most Played.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(libraryTracksProvider);
    return Scaffold(
      body: SafeArea(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => EmptyState(
            message: 'Cannot reach the server — check Settings.',
            icon: Icons.cloud_off,
            action: OutlinedButton(
              onPressed: () => ref.invalidate(libraryTracksProvider),
              child: const Text('Retry'),
            ),
          ),
          data: (tracks) => tracks.isEmpty
              ? const EmptyState(
                  message: 'The library is empty — scan it from Settings.',
                  icon: Icons.library_music_outlined,
                )
              : _HomeBody(tracks: tracks),
        ),
      ),
    );
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(homeAlbumsProvider);
    final stats = ref.watch(homeStatsProvider);

    // Recently Added — pure local data, works even when the play log is
    // unreachable (legacy).
    final added = [...albums]
      ..sort((x, y) => albumAddedAt(y).compareTo(albumAddedAt(x)));

    return ListView(
      padding: const EdgeInsets.all(AriaSpace.s6),
      children: [
        Text('Home', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AriaSpace.s4),
        _StatStrip(tracks: tracks, albumCount: albums.length),
        const SizedBox(height: AriaSpace.s6),
        if (added.isNotEmpty) ...[
          _AlbumShelf(title: 'Recently Added', albums: added.take(20).toList()),
          const SizedBox(height: AriaSpace.s6),
        ],
        const NewReleasesShelf(),
        const SizedBox(height: AriaSpace.s6),
        ..._playShelves(context, ref, stats),
      ],
    );
  }

  // Recently / Most Played + Listening need /api/stats for the profile.
  List<Widget> _playShelves(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<Stats> stats,
  ) {
    final c = AriaColors.of(context);
    switch (stats) {
      case AsyncError():
        return [
          Text(
            'Recently Played',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AriaSpace.s2),
          Text('Play history unavailable.', style: TextStyle(color: c.fgDim)),
        ];
      case AsyncData(:final value):
        final byId = ref.watch(trackByIdProvider);
        final albumById = ref.watch(homeAlbumByIdProvider);

        // Recently Played: one card per album, newest play first (legacy).
        final seen = <String>{};
        final recent = <Album>[];
        for (final r in value.recent) {
          final a = albumById[byId[r.id]?.albumId];
          if (a != null && seen.add(a.id)) recent.add(a);
          if (recent.length >= 20) break;
        }

        final top = [
          for (final x in value.topAlbums)
            if (albumById[x.albumId] != null)
              (album: albumById[x.albumId]!, count: x.count),
        ].take(20).toList();

        return [
          if (recent.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AriaSpace.s6),
              child: Text(
                'Nothing played yet.',
                style: TextStyle(color: c.fgDim),
              ),
            )
          else ...[
            _AlbumShelf(title: 'Recently Played', albums: recent),
            const SizedBox(height: AriaSpace.s6),
          ],
          _Listening(stats: value),
          if (top.isNotEmpty) ...[
            _AlbumShelf(
              title: 'Most Played',
              albums: [for (final x in top) x.album],
              subFor: {
                for (final x in top)
                  x.album.id: '${x.count} play${x.count == 1 ? '' : 's'}',
              },
            ),
            const SizedBox(height: AriaSpace.s6),
          ],
        ];
      default:
        return const [Center(child: CircularProgressIndicator())];
    }
  }
}

/// Legacy stat strip: Albums / Tracks / Artists / Genres / Of music.
class _StatStrip extends StatelessWidget {
  const _StatStrip({required this.tracks, required this.albumCount});

  final List<Track> tracks;
  final int albumCount;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final artists = <String>{
      for (final t in tracks) ...[
        if ((t.artist ?? '').isNotEmpty) t.artist!,
        if ((t.albumArtist ?? '').isNotEmpty) t.albumArtist!,
      ],
    };
    final genres = <String>{for (final t in tracks) ...t.genres};
    final secs = tracks.fold<double>(0, (s, t) => s + (t.duration ?? 0));

    Widget tile(String num, String label) => Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AriaSpace.s5,
        vertical: AriaSpace.s4,
      ),
      decoration: BoxDecoration(
        color: c.bgRaised,
        borderRadius: BorderRadius.circular(AriaRadius.md),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            num,
            style: TextStyle(
              fontSize: 20,
              color: c.fg,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(label, style: TextStyle(fontSize: 12.5, color: c.fgDim)),
        ],
      ),
    );

    return Wrap(
      spacing: AriaSpace.s3,
      runSpacing: AriaSpace.s3,
      children: [
        tile('$albumCount', 'Albums'),
        tile('${tracks.length}', 'Tracks'),
        tile('${artists.length}', 'Artists'),
        tile('${genres.length}', 'Genres'),
        tile(fmtHm(secs), 'Of music'),
      ],
    );
  }
}

class _AlbumShelf extends ConsumerWidget {
  const _AlbumShelf({
    required this.title,
    required this.albums,
    this.subFor = const {},
  });

  final String title;
  final List<Album> albums;

  /// Optional per-album subtitle override (Most Played's "N plays").
  final Map<String, String> subFor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiClientProvider);
    return Shelf(
      title: title,
      height: 236,
      itemCount: albums.length,
      itemBuilder: (context, i) {
        final a = albums[i];
        return AlbumCard(
          title: a.title,
          subtitle: subFor[a.id] ?? a.albumArtist,
          artUrl: a.hasArt ? api.artUrl(a.id) : null,
          onTap: () {
            if (selectionTapHandled(ref, albumSelectionItem(a.id, a.tracks))) {
              return;
            }
            context.push(albumPath(a.id));
          },
          onSecondary: (pos) => showAriaContextMenu(
            context,
            pos,
            albumMenuItems(
              context,
              ref,
              albumId: a.id,
              tracks: a.tracks,
              artistName: a.albumArtist,
            ),
          ),
        );
      },
    );
  }
}

/// Legacy buildListening: 30-day charts + top artists/tracks mini-lists.
class _Listening extends ConsumerWidget {
  const _Listening({required this.stats});

  final Stats stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hist = stats.history;
    if (hist.isEmpty) return const SizedBox.shrink(); // nothing in 30 days
    final byId = ref.watch(trackByIdProvider);

    // Bucket in the viewer's timezone — the server hands raw timestamps.
    String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';
    final days = <String, ({String label, int n})>{};
    final now = DateTime.now();
    for (var i = 29; i >= 0; i--) {
      final d = now.subtract(Duration(days: i));
      days[dayKey(d)] = (label: '${d.month}/${d.day}', n: 0);
    }
    final hours = List<int>.filled(24, 0);
    final artC = <String, int>{};
    final trkC = <String, int>{};
    for (final p in hist) {
      final d = DateTime.tryParse(p.at)?.toLocal();
      if (d == null) continue;
      final k = dayKey(d);
      final day = days[k];
      if (day != null) days[k] = (label: day.label, n: day.n + 1);
      hours[d.hour]++;
      final t = byId[p.id];
      final artist = t?.artist;
      if (artist != null && artist.isNotEmpty) {
        artC[artist] = (artC[artist] ?? 0) + 1;
      }
      trkC[p.id] = (trkC[p.id] ?? 0) + 1;
    }

    List<MapEntry<String, int>> top5(Map<String, int> m) =>
        (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .take(5)
            .toList();

    final topArtists = top5(artC);
    final topTracks = [
      for (final e in top5(trkC))
        if (byId[e.key] != null) (track: byId[e.key]!, n: e.value),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: AriaSpace.s6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Listening',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(
                onPressed: () => context.push('/stats'),
                child: const Text('See all →'),
              ),
            ],
          ),
          const SizedBox(height: AriaSpace.s3),
          Wrap(
            spacing: AriaSpace.s5,
            runSpacing: AriaSpace.s5,
            children: [
              _ChartBox(
                title: 'Plays · last 30 days',
                values: [for (final d in days.values) d.n],
              ),
              _ChartBox(title: 'By hour of day', values: hours),
              _MiniList(
                title: 'Top artists · 30 days',
                rows: [
                  for (final e in topArtists)
                    (
                      label: e.key,
                      sub: null,
                      n: e.value,
                      onTap: () => context.push(artistPath(e.key)),
                    ),
                ],
              ),
              _MiniList(
                title: 'Top tracks · 30 days',
                rows: [
                  for (final x in topTracks)
                    (
                      label: x.track.title ?? '—',
                      sub: x.track.artist,
                      n: x.n,
                      onTap: () => ref.read(queueProvider.notifier).playQueue([
                        x.track,
                      ], 0),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChartBox extends StatelessWidget {
  const _ChartBox({required this.title, required this.values});

  final String title;
  final List<int> values;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final max = values.fold<int>(1, (m, v) => v > m ? v : m);
    return Container(
      width: 320,
      padding: const EdgeInsets.all(AriaSpace.s4),
      decoration: BoxDecoration(
        color: c.bgRaised,
        borderRadius: BorderRadius.circular(AriaRadius.md),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 12.5, color: c.fgDim)),
          const SizedBox(height: AriaSpace.s3),
          SizedBox(
            height: 64,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final v in values)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 0.5),
                      child: FractionallySizedBox(
                        heightFactor: v == 0 ? 0.04 : (v / max).clamp(0.04, 1),
                        child: Container(
                          decoration: BoxDecoration(
                            color: v == 0 ? c.line : c.fgDim,
                            borderRadius: BorderRadius.circular(1.5),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniList extends StatelessWidget {
  const _MiniList({required this.title, required this.rows});

  final String title;
  final List<({String label, String? sub, int n, VoidCallback onTap})> rows;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Container(
      width: 320,
      padding: const EdgeInsets.all(AriaSpace.s4),
      decoration: BoxDecoration(
        color: c.bgRaised,
        borderRadius: BorderRadius.circular(AriaRadius.md),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 12.5, color: c.fgDim)),
          const SizedBox(height: AriaSpace.s2),
          if (rows.isEmpty)
            Text('—', style: TextStyle(color: c.fgDim))
          else
            for (final (i, r) in rows.indexed)
              InkWell(
                onTap: r.onTap,
                borderRadius: BorderRadius.circular(AriaRadius.sm),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 18,
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(color: c.fgDim, fontSize: 12.5),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              r.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if ((r.sub ?? '').isNotEmpty)
                              Text(
                                r.sub!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: c.fgDim),
                              ),
                          ],
                        ),
                      ),
                      Text(
                        '${r.n}',
                        style: TextStyle(color: c.fgDim, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
