import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/library_providers.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/art_image.dart';
import '../../widgets/artist_avatar.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/library_cards.dart';
import '../../widgets/new_releases_shelf.dart';
import '../../widgets/shelf.dart';
import '../../widgets/track_actions.dart';
import 'home_providers.dart';
import 'mixes.dart';

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
        const NewReleasesShelf(),
        const SizedBox(height: AriaSpace.s6),
        if (added.isNotEmpty) ...[
          _AlbumShelf(title: 'Recently Added', albums: added.take(20).toList()),
          const SizedBox(height: AriaSpace.s6),
        ],
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

        // Recently Listened Artists: same play log, deduped by artist name.
        final seenArt = <String>{};
        final recentArtists = <String>[];
        for (final r in value.recent) {
          final name = byId[r.id]?.artist;
          if (name != null && name.isNotEmpty && seenArt.add(name)) {
            recentArtists.add(name);
          }
          if (recentArtists.length >= 20) break;
        }

        final top = [
          for (final x in value.topAlbums)
            if (albumById[x.albumId] != null)
              (album: albumById[x.albumId]!, count: x.count),
        ].take(20).toList();

        // Most Listened Artists: server-ranked, mirrors Most Played albums.
        final topArtists = value.topArtists.take(20).toList();

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
            if (recentArtists.isNotEmpty) ...[
              _ArtistShelf(
                title: 'Recently Listened Artists',
                names: recentArtists,
              ),
              const SizedBox(height: AriaSpace.s6),
            ],
          ],
          const _MixesShelf(),
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
          if (topArtists.isNotEmpty) ...[
            _ArtistShelf(
              title: 'Most Listened Artists',
              names: [for (final a in topArtists) a.name],
              subFor: {
                for (final a in topArtists)
                  a.name: '${a.count} play${a.count == 1 ? '' : 's'}',
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

/// Generic filler titles that aren't real compositions.
const _fillerTitles = {'intro', 'outro', 'interlude', 'untitled', 'skit'};

/// A track's composition identity for the stat count: the work tag when
/// present, otherwise a synthetic key from composer + title (so the same song
/// under different composers stays distinct). Returns null for filler/untitled
/// tracks, which don't count as compositions.
// ponytail: exact-match filler set; extend _fillerTitles as needed.
String? compositionKey(Track t) {
  final work = t.work?.trim();
  if (work != null && work.isNotEmpty) return 'w ${work.toLowerCase()}';
  final title = t.title?.trim().toLowerCase();
  if (title == null || title.isEmpty || _fillerTitles.contains(title)) {
    return null;
  }
  return '${t.composer?.trim().toLowerCase() ?? ''} $title';
}

/// Four equal-width tiles spanning the full width: Composers / Performers /
/// Releases / Compositions. Counts derive from the loaded library cache.
class _StatStrip extends StatelessWidget {
  const _StatStrip({required this.tracks, required this.albumCount});

  final List<Track> tracks;
  final int albumCount;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    // All tracks, not just classical-shaped ones: every distinct composer tag.
    final composers = <String>{
      for (final t in tracks)
        if (t.composer?.isNotEmpty ?? false) t.composer!,
    };
    final performers = <String>{
      for (final t in tracks)
        for (final p in t.performers)
          if (p.name.isNotEmpty) p.name,
    };
    final compositions = <String>{
      for (final t in tracks) ?compositionKey(t),
    };

    Widget tile(String num, String label, String route) => Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(AriaRadius.md),
        onTap: () => context.go(route),
        child: Container(
          // Equal-width under Expanded; vertical padding only so tiles stretch
          // to fill their share of the row.
          padding: const EdgeInsets.symmetric(
            horizontal: AriaSpace.s3,
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
                  fontSize: 18,
                  color: c.fg,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );

    return Row(
      children: [
        tile('${composers.length}', 'Composers', '/library/composers'),
        const SizedBox(width: AriaSpace.s2),
        tile('${performers.length}', 'Performers', '/library/artists'),
        const SizedBox(width: AriaSpace.s2),
        tile('$albumCount', 'Releases', '/library/albums'),
        const SizedBox(width: AriaSpace.s2),
        tile('${compositions.length}', 'Compositions', '/library/tracks'),
      ],
    );
  }
}

class _MixesShelf extends ConsumerWidget {
  const _MixesShelf();

  static const _looks = {
    'daily': (Icons.wb_sunny_outlined, Color(0xFF7C4DFF)),
    'weekly': (Icons.calendar_view_week_outlined, Color(0xFF00897B)),
    'monthly': (Icons.calendar_month_outlined, Color(0xFFEF6C00)),
    'yearly': (Icons.emoji_events_outlined, Color(0xFF3949AB)),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final mixes = [
      for (final m in ref.watch(homeMixesProvider))
        if (m.tracks.isNotEmpty) m,
    ];
    if (mixes.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your Mixes', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AriaSpace.s3),
        // Short full-width banners (one per row, full width on mobile) instead
        // of tall narrow shelf cards.
        for (final m in mixes) ...[
          _MixBanner(mix: m, looks: _looks[m.id] ?? (Icons.queue_music, c.accent)),
          const SizedBox(height: AriaSpace.s2),
        ],
        const SizedBox(height: AriaSpace.s4),
      ],
    );
  }
}

class _MixBanner extends StatelessWidget {
  const _MixBanner({required this.mix, required this.looks});

  final HomeMix mix;
  final (IconData, Color) looks;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final (icon, tint) = looks;
    return InkWell(
      borderRadius: BorderRadius.circular(AriaRadius.md),
      onTap: () => context.push('/mix/${mix.id}'),
      child: Container(
        height: 76,
        padding: const EdgeInsets.symmetric(horizontal: AriaSpace.s4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AriaRadius.md),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [c.accent, tint],
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 28),
            const SizedBox(width: AriaSpace.s4),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mix.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    mix.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

class _AlbumShelf extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Shelf(
      title: title,
      height: 236,
      itemCount: albums.length,
      itemBuilder: (context, i) {
        final a = albums[i];
        return AlbumGridCard(
          albumId: a.id,
          title: a.title,
          artistName: a.albumArtist,
          tracks: a.tracks,
          hasArt: a.hasArt,
          subtitle: subFor[a.id],
        );
      },
    );
  }
}

/// Avatar shelf of artists (Recently / Most Listened), wired like the tag
/// page's artist row: tap → artist page, secondary/long-press → menu.
class _ArtistShelf extends ConsumerWidget {
  const _ArtistShelf({
    required this.title,
    required this.names,
    this.subFor = const {},
  });

  final String title;
  final List<String> names;

  /// Optional per-artist subtitle (Most Listened's "N plays").
  final Map<String, String> subFor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final byId = ref.watch(trackByIdProvider);
    final people = ref.watch(peopleProvider).value ?? const {};
    return Shelf(
      title: title,
      // Same 236/168 art+text budget as album cards; the avatar fills the
      // band-derived card width so it scales down with the column count.
      height: 236,
      mobileColumns: 4,
      itemCount: names.length,
      itemBuilder: (context, i) {
        final name = names[i];
        List<Track> tracksOf() => [
          for (final t in byId.values)
            if (t.artist == name || t.albumArtist == name) t,
        ];
        final sub = subFor[name];
        return ArtistTile(
          name: name,
          tracksOf: tracksOf,
          child: LayoutBuilder(
            builder: (context, cons) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ArtistAvatar(
                  name: name,
                  imageUrl: people[name],
                  size: cons.maxWidth,
                ),
                const SizedBox(height: AriaSpace.s2),
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (sub != null)
                  Text(sub, style: TextStyle(color: c.fgDim, fontSize: 12)),
              ],
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
    final people = ref.watch(peopleProvider).value ?? const {};
    final api = ref.watch(apiClientProvider);

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

    // Listening time (seconds) per week for the last 4 weeks, from the play
    // log times * each track's tagged duration.
    final weekSecs = List<double>.filled(4, 0);
    for (final p in hist) {
      final d = DateTime.tryParse(p.at)?.toLocal();
      if (d == null) continue;
      final daysAgo = now.difference(d).inDays;
      if (daysAgo < 0 || daysAgo >= 28) continue;
      weekSecs[daysAgo ~/ 7] += byId[p.id]?.duration ?? 0;
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
          // Full-width horizontal slider — one card per page.
          SizedBox(
            height: 248,
            child: PageView(
              controller: PageController(viewportFraction: 0.92),
              children: [
                _WeeklyTimeBox(weekSecs: weekSecs),
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
                        leading: ArtistAvatar(
                          name: e.key,
                          imageUrl: people[e.key],
                          size: 28,
                        ),
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
                        leading: ArtImage(
                          url: api.artUrl(x.track.albumId,
                              version: x.track.artVersion),
                          fallbackText: x.track.title,
                          size: 28,
                          borderRadius: AriaRadius.sm,
                        ),
                        onTap: () => ref.read(queueProvider.notifier).playQueue([
                          x.track,
                        ], 0),
                      ),
                  ],
                ),
              ],
            ),
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
      margin: const EdgeInsets.only(right: AriaSpace.s3),
      padding: const EdgeInsets.all(AriaSpace.s4),
      decoration: BoxDecoration(
        color: c.bgRaised,
        borderRadius: BorderRadius.circular(AriaRadius.md),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.bodySmall),
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
                            color: v == 0 ? c.line : c.accent,
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
  final List<
    ({String label, String? sub, int n, Widget leading, VoidCallback onTap})
  >
  rows;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Container(
      margin: const EdgeInsets.only(right: AriaSpace.s3),
      padding: const EdgeInsets.all(AriaSpace.s4),
      decoration: BoxDecoration(
        color: c.bgRaised,
        borderRadius: BorderRadius.circular(AriaRadius.md),
        border: Border.all(color: c.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AriaSpace.s2),
          if (rows.isEmpty)
            Text('—', style: TextStyle(color: c.fgDim))
          else
            for (final (i, r) in rows.indexed)
              InkWell(
                onTap: r.onTap,
                borderRadius: BorderRadius.circular(AriaRadius.sm),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AriaSpace.s1),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 18,
                        child: Text(
                          '${i + 1}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      r.leading,
                      const SizedBox(width: AriaSpace.s2),
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
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                      Text(
                        '${r.n}',
                        style: Theme.of(context).textTheme.bodySmall,
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

class _WeeklyTimeBox extends StatelessWidget {
  const _WeeklyTimeBox({required this.weekSecs});

  /// Index 0 = current 7 days, 1 = prior week, up to 4 weeks back.
  final List<double> weekSecs;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    const labels = ['This week', 'Last week', '2 wks ago', '3 wks ago'];
    final max = weekSecs.fold<double>(1, (m, v) => v > m ? v : m);
    return Container(
      margin: const EdgeInsets.only(right: AriaSpace.s3),
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
            'Listening time · last 4 weeks',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AriaSpace.s3),
          for (final (i, secs) in weekSecs.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 78,
                    child: Text(
                      labels[i],
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: (secs / max).clamp(0, 1).toDouble(),
                        minHeight: 8,
                        backgroundColor: c.line,
                        color: c.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: AriaSpace.s3),
                  SizedBox(
                    width: 56,
                    child: Text(
                      _fmtListen(secs),
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.bodySmall,
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

String _fmtListen(double secs) {
  final m = (secs / 60).round();
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h ${m % 60}m';
}
