import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/library_providers.dart';
import '../../core/theme.dart';
import '../../widgets/artist_avatar.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/library_cards.dart';
import '../../widgets/new_releases_shelf.dart';
import '../../widgets/shelf.dart';
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
      padding: ariaPagePadding(context),
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
          if (recent.length >= 10) break;
        }

        // Recently Listened Artists: same play log, deduped by artist name.
        final seenArt = <String>{};
        final recentArtists = <String>[];
        for (final r in value.recent) {
          final name = byId[r.id]?.artist;
          if (name != null && name.isNotEmpty && seenArt.add(name)) {
            recentArtists.add(name);
          }
          if (recentArtists.length >= 10) break;
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

    Widget tile(String num, String label, IconData icon, String route) {
      final text = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
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
      );
      final glyph = Icon(icon, size: 24, color: c.accent);
      return Expanded(
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
            // Icon beside the text when the tile is wide enough, stacked above
            // it when it isn't.
            child: LayoutBuilder(
              builder: (context, box) => box.maxWidth >= 150
                  ? Row(
                      children: [
                        glyph,
                        const SizedBox(width: AriaSpace.s3),
                        Flexible(child: text),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        glyph,
                        const SizedBox(height: AriaSpace.s2),
                        text,
                      ],
                    ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tile('${composers.length}', 'Composers', Icons.edit_note,
            '/library/composers'),
        const SizedBox(width: AriaSpace.s2),
        tile('${performers.length}', 'Performers', Icons.groups_outlined,
            '/library/artists'),
        const SizedBox(width: AriaSpace.s2),
        tile('$albumCount', 'Releases', Icons.album_outlined,
            '/library/albums'),
        const SizedBox(width: AriaSpace.s2),
        tile('${compositions.length}', 'Compositions', Icons.music_note_outlined,
            '/library/tracks'),
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
        // Horizontal shelf of 3:2 mix cards — 3 visible on desktop, 2 on
        // tablet, 1 on mobile; scrolls if there are more.
        LayoutBuilder(
          builder: (context, box) {
            const gap = AriaSpace.s5;
            final n = switch (AriaBreakpoint.of(context)) {
              AriaBreakpoint.desktop => 3,
              AriaBreakpoint.tablet => 2,
              AriaBreakpoint.mobile => 1,
            };
            final w = (box.maxWidth - (n - 1) * gap) / n;
            return SizedBox(
              height: w * 2 / 3,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: mixes.length,
                separatorBuilder: (_, _) => const SizedBox(width: gap),
                itemBuilder: (context, i) => SizedBox(
                  width: w,
                  child: _MixBanner(
                    mix: mixes[i],
                    looks: _looks[mixes[i].id] ??
                        (Icons.queue_music, c.accent),
                  ),
                ),
              ),
            );
          },
        ),
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
        padding: const EdgeInsets.all(AriaSpace.s4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AriaRadius.md),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [c.accent, tint],
          ),
        ),
        // Content sits at the bottom of the taller 3:2 card.
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
        Row(
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
      // One column denser than album shelves — smaller person cards.
      extraColumns: 1,
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
              // Centered under the round avatar, like the grid cards.
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ArtistAvatar(
                  name: name,
                  imageUrl: people[name],
                  size: cons.maxWidth,
                ),
                const SizedBox(height: AriaSpace.s2),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
                if (sub != null)
                  Text(
                    sub,
                    style: TextStyle(color: c.fgDim, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
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

    // Bucket in the viewer's timezone — the server hands raw timestamps.
    final now = DateTime.now();

    // Listening time (seconds) per week for the last 4 weeks, from the
    // play-log times * each track's tagged duration. dayGrid also splits each
    // week into its 7 weekdays for the dot column — a rolling 7-day window
    // holds exactly one of each weekday, so no collisions.
    final weekSecs = List<double>.filled(4, 0);
    final dayGrid = List.generate(4, (_) => List<double>.filled(7, 0));
    for (final p in hist) {
      final d = DateTime.tryParse(p.at)?.toLocal();
      if (d == null) continue;
      final daysAgo = now.difference(d).inDays;
      if (daysAgo < 0 || daysAgo >= 28) continue;
      final secs = byId[p.id]?.duration ?? 0;
      weekSecs[daysAgo ~/ 7] += secs;
      dayGrid[daysAgo ~/ 7][d.weekday - 1] += secs;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AriaSpace.s6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Two separate titled shelves, each three panels wide (3 across on
          // desktop, 2 on tablet, 1 on mobile) — replaces the old swipe slider.
          _shelfHeader(
            context,
            'Listening time',
            onSeeAll: () => context.push('/stats'),
          ),
          const SizedBox(height: AriaSpace.s3),
          _WeeklyTimeBox(weekSecs: weekSecs, dayGrid: dayGrid),
          const SizedBox(height: AriaSpace.s6),
          _shelfHeader(context, 'Ranks'),
          const SizedBox(height: AriaSpace.s3),
          const _RanksCard(),
        ],
      ),
    );
  }
}

/// Section header for a stat shelf: title with an optional "See all →".
Widget _shelfHeader(
  BuildContext context,
  String title, {
  VoidCallback? onSeeAll,
}) => Row(
  children: [
    Expanded(
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    ),
    if (onSeeAll != null)
      TextButton(onPressed: onSeeAll, child: const Text('See all →')),
  ],
);

/// Three stat panels sized so N fill the width — 3 on desktop, 2 on tablet,
/// 1 on mobile — with the rest reachable by horizontal slide, never wrapping.
Widget _cardShelf(BuildContext context, List<Widget> cards) {
  final n = switch (AriaBreakpoint.of(context)) {
    AriaBreakpoint.desktop => 3,
    AriaBreakpoint.tablet => 2,
    AriaBreakpoint.mobile => 1,
  };
  const gap = AriaSpace.s6;
  return LayoutBuilder(
    builder: (context, box) {
      final w = (box.maxWidth - (n - 1) * gap) / n;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, card) in cards.indexed) ...[
              if (i > 0) const SizedBox(width: gap),
              SizedBox(width: w, child: card),
            ],
          ],
        ),
      );
    },
  );
}

/// Top genres / performers / releases by time listened over a selectable
/// period. Play counts come windowed from the server; durations are local, so
/// seconds = count × track.duration aggregated by genre, performer, album.
class _RanksCard extends ConsumerStatefulWidget {
  const _RanksCard();

  @override
  ConsumerState<_RanksCard> createState() => _RanksCardState();
}

class _RanksCardState extends ConsumerState<_RanksCard> {
  String _period = 'month';

  static const _periods = [
    ('week', 'Week'),
    ('month', 'Month'),
    ('year', 'Year'),
    ('all', 'All-time'),
  ];

  static List<MapEntry<String, double>> _top5(Map<String, double> m) =>
      (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
          .take(5)
          .toList();

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final countsAsync = ref.watch(periodCountsProvider(_period));
    final counts = countsAsync.value ?? const <String, int>{};
    final byId = ref.watch(trackByIdProvider);
    final albumById = ref.watch(homeAlbumByIdProvider);

    final genreSecs = <String, double>{};
    final perfSecs = <String, double>{};
    final relSecs = <String, double>{}; // albumId → seconds
    counts.forEach((id, n) {
      final t = byId[id];
      if (t == null) return;
      final secs = (t.duration ?? 0) * n;
      if (secs <= 0) return;
      for (final g in t.genres) {
        if (g.isNotEmpty) genreSecs[g] = (genreSecs[g] ?? 0) + secs;
      }
      for (final p in t.performers) {
        if (p.name.isNotEmpty) perfSecs[p.name] = (perfSecs[p.name] ?? 0) + secs;
      }
      relSecs[t.albumId] = (relSecs[t.albumId] ?? 0) + secs;
    });

    Widget rankColumn(
      String title,
      List<MapEntry<String, double>> rows,
      String Function(String key) label,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AriaSpace.s3),
        if (rows.isEmpty)
          Text('—', style: TextStyle(color: c.fgDim))
        else
          for (final (i, e) in rows.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AriaSpace.s1),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    child: Text(
                      '${i + 1}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: c.fgDim),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      label(e.key),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AriaSpace.s2),
                  Text(
                    fmtHm(e.value),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: c.fgDim),
                  ),
                ],
              ),
            ),
      ],
    );

    final genres = rankColumn('Genres', _top5(genreSecs), (k) => k);
    final performers = rankColumn('Performers', _top5(perfSecs), (k) => k);
    final releases = rankColumn(
      'Releases',
      _top5(relSecs),
      (k) => albumById[k]?.title ?? '—',
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AriaSpace.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: DropdownButton<String>(
              value: _period,
              items: [
                for (final (v, l) in _periods)
                  DropdownMenuItem(value: v, child: Text(l)),
              ],
              onChanged: (v) =>
                  v == null ? null : setState(() => _period = v),
            ),
          ),
          const SizedBox(height: AriaSpace.s4),
          if (countsAsync.isLoading && counts.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: AriaSpace.s6),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            _cardShelf(context, [genres, performers, releases]),
        ],
      ),
    );
  }
}

class _WeeklyTimeBox extends StatelessWidget {
  const _WeeklyTimeBox({required this.weekSecs, required this.dayGrid});

  /// Index 0 = current 7 days, 1 = prior week, up to 4 weeks back.
  final List<double> weekSecs;

  /// [week][weekday] listening seconds, week 0 = current, weekday 0 = Monday.
  final List<List<double>> dayGrid;

  // Per-row content height and vertical padding, shared by the bar rows and
  // the dot rows so weeks line up across columns 2 and 3.
  static const double _rowH = 16;
  static const double _rowPad = 7;
  // Fixed-height stand-in matching the dot column's weekday-label row, so both
  // columns' data rows start at the same y.
  static const double _headerH = 16;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final total = weekSecs.fold<double>(0, (s, v) => s + v);
    final maxWeek = weekSecs.fold<double>(1, (m, v) => v > m ? v : m);
    final maxDay = dayGrid
        .expand((r) => r)
        .fold<double>(1, (m, v) => v > m ? v : m);

    Widget column(String title, Widget header, List<Widget> rows) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AriaSpace.s3),
            header,
            const SizedBox(height: AriaSpace.s2),
            ...rows,
          ],
        );

    // Oldest week first, current week last (indices 3..0) — matches nothing to
    // label, columns align row-for-row.
    const weekOrder = [3, 2, 1, 0];

    final time = column(
      'Listening time · last 4 weeks',
      const SizedBox(height: _headerH),
      [
        for (final w in weekOrder)
          Builder(builder: (context) {
            // Variable-width bar, relative to the busiest of the 4 weeks, with
            // the time label riding directly off its end.
            final frac = (weekSecs[w] / maxWeek).clamp(0, 1).toDouble();
            final fill = (frac * 1000).round();
            final rest = 1000 - fill;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: _rowPad),
              child: SizedBox(
                height: _rowH,
                child: Row(
                  children: [
                    if (fill > 0)
                      Flexible(
                        flex: fill,
                        child: Container(
                          decoration: BoxDecoration(
                            color: c.accent,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    const SizedBox(width: AriaSpace.s2),
                    Text(
                      _fmtListen(weekSecs[w]),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (rest > 0) Spacer(flex: rest),
                  ],
                ),
              ),
            );
          }),
      ],
    );

    Widget dot(double secs) {
      final has = secs > 0;
      const minD = 6.0;
      final size = has
          ? (minD + (_rowH - minD) * (secs / maxDay)).clamp(minD, _rowH)
          : minD;
      return Center(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: has ? c.accent : c.line,
          ),
        ),
      );
    }

    final dots = column(
      'Daily · last 4 weeks',
      SizedBox(
        height: _headerH,
        child: Row(
          children: [
            for (final d in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
              Expanded(
                child: Text(
                  d,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: c.fgDim),
                ),
              ),
          ],
        ),
      ),
      [
        for (final w in weekOrder)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: _rowPad),
            child: SizedBox(
              height: _rowH,
              child: Row(
                children: [
                  for (var wd = 0; wd < 7; wd++)
                    Expanded(child: dot(dayGrid[w][wd])),
                ],
              ),
            ),
          ),
      ],
    );

    final total4w = Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.schedule_outlined, size: 64, color: c.accent),
        const SizedBox(height: AriaSpace.s4),
        Text(
          _fmtListen(total),
          style: Theme.of(context).textTheme.displaySmall,
        ),
        const SizedBox(height: AriaSpace.s2),
        Text(
          'time listened last 4 weeks',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AriaSpace.s4),
      child: _cardShelf(context, [total4w, time, dots]),
    );
  }
}

String _fmtListen(double secs) {
  final m = (secs / 60).round();
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h ${m % 60}m';
}
