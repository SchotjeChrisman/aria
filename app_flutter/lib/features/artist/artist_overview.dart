import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/library_providers.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/album_card.dart';
import '../../widgets/art_image.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/shelf.dart';
import '../../widgets/track_actions.dart' as actions;
import 'artist_util.dart';
import 'person_card.dart';
import 'providers.dart';

/// Overview tab (legacy renderArtistOverview): facts hero, top tracks,
/// library albums by release type, appears-on, members/bands/similar.
class ArtistOverview extends ConsumerWidget {
  const ArtistOverview({super.key, required this.name, this.onMoreBio});

  final String name;

  /// Switches the page to the Info tab (in-page, no navigation).
  final VoidCallback? onMoreBio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(artistTracksProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => const EmptyState(
            message: 'Could not load the library.',
            icon: Icons.cloud_off,
          ),
          data: (_) => _body(context, ref),
        );
  }

  Widget _body(BuildContext context, WidgetRef ref) {
    // Cached, artist-filtered subset — never rescan the full library here.
    final tracks = ref.watch(artistRelevantTracksProvider(name));
    final albums = ref.watch(artistAlbumsProvider).value ?? const <Album>[];
    final albumsById = {for (final a in albums) a.id: a};
    final inLibrary = ref.watch(libraryArtistNamesProvider);

    final main = [
      for (final a in albums)
        if (a.albumArtist == name) a,
    ];

    // appears on: albumId -> roles, from every credit field (legacy)
    final appear = <String, Set<String>>{};
    void add(String albumId, String role) =>
        (appear[albumId] ??= <String>{}).add(role);
    for (final t in tracks) {
      if (t.artist == name && t.albumArtist != name) add(t.albumId, 'artist');
      if (t.composer == name) add(t.albumId, 'composer');
      if (t.conductor == name) add(t.albumId, 'conductor');
      if (t.orchestra == name) add(t.albumId, 'orchestra');
      for (final p in t.performers) {
        if (p.name == name && p.role != null) add(t.albumId, p.role!);
      }
    }
    for (final a in main) {
      appear.remove(a.id);
    }

    // explicit works only, like the legacy composers index
    final works = <String>{
      for (final t in tracks)
        if (t.composer == name && (t.work ?? '').isNotEmpty) t.work!,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FactsHero(name: name, tracks: tracks, onMoreBio: onMoreBio),
        _TopTracks(name: name),
        ..._albumShelves(context, ref, main),
        ..._appearsOn(context, appear, albumsById),
        _PeopleShelves(name: name, inLibrary: inLibrary),
        if (works.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => context.push(composerPath(name)),
              child: Text('View compositions (${works.length}) →'),
            ),
          ),
        if (main.isEmpty && appear.isEmpty)
          const EmptyState(
            message: 'Not in your library — yet.',
            icon: Icons.person_outline,
          ),
      ],
    );
  }

  // Discography sectioned by release type; a single section — or no
  // releaseType data at all — degrades to the plain Albums shelf (legacy).
  List<Widget> _albumShelves(
    BuildContext context,
    WidgetRef ref,
    List<Album> main,
  ) {
    if (main.isEmpty) return const [];
    final groups = <String, List<Album>>{};
    for (final a in main) {
      (groups[a.releaseType ?? 'Album'] ??= []).add(a);
    }
    List<Album> sorted(List<Album> l) =>
        l..sort((x, y) => (y.year ?? 0) - (x.year ?? 0));
    final sections = groups.length > 1
        ? [
            for (final ty in rtOrder)
              if (groups.containsKey(ty))
                (rtHeadings[ty] ?? ty, sorted(groups[ty]!)),
          ]
        : [('Albums', sorted(main))];
    final api = ref.watch(artistApiProvider);
    return [
      for (final (heading, list) in sections)
        Padding(
          padding: const EdgeInsets.only(bottom: AriaSpace.s5),
          child: Shelf(
            title: heading,
            height: 226,
            itemCount: list.length,
            itemBuilder: (context, i) {
              final a = list[i];
              return Consumer(
                builder: (context, ref, _) => AlbumCard(
                  title: a.title,
                  subtitle: a.year?.toString() ?? '',
                  artUrl: api.artUrl(a.id),
                  onTap: () => context.push(albumPath(a.id)),
                  onSecondary: (pos) => showAriaContextMenu(
                    context,
                    pos,
                    actions.albumMenuItems(
                      context,
                      ref,
                      albumId: a.id,
                      tracks: a.tracks,
                      artistName: a.albumArtist,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
    ];
  }

  List<Widget> _appearsOn(
    BuildContext context,
    Map<String, Set<String>> appear,
    Map<String, Album> albumsById,
  ) {
    if (appear.isEmpty) return const [];
    final c = AriaColors.of(context);
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: AriaSpace.s3),
        child: Text(
          'Appears on',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      for (final e in appear.entries)
        if (albumsById[e.key] != null)
          InkWell(
            onTap: () => context.push(albumPath(e.key)),
            borderRadius: BorderRadius.circular(AriaRadius.md),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AriaSpace.s3,
                vertical: 10,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        text: albumsById[e.key]!.title,
                        children: [
                          TextSpan(
                            text: ' — ${albumsById[e.key]!.albumArtist}',
                            style: TextStyle(color: c.fgDim),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AriaSpace.s3),
                  Text(
                    e.value.join(', '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
      const SizedBox(height: AriaSpace.s5),
    ];
  }
}

/// Portrait + age/origin/genres only — the bio lives in the Info tab
/// (legacy heroCard {facts:true}).
class _FactsHero extends ConsumerWidget {
  const _FactsHero({required this.name, required this.tracks, this.onMoreBio});

  final String name;
  final List<Track> tracks;
  final VoidCallback? onMoreBio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    return ref
        .watch(artistInfoProvider(name))
        .when(
          loading: () => Padding(
            padding: const EdgeInsets.only(bottom: AriaSpace.s5),
            child: Text('Researching…', style: TextStyle(color: c.fgDim)),
          ),
          error: (_, _) => const SizedBox.shrink(),
          data: (d) {
            final people = ref.watch(artistPeopleProvider).value ?? const {};
            final img = d?.image ?? people[name];
            final genres = <String>{
              for (final t in tracks)
                if (t.artist == name || t.albumArtist == name)
                  ...trackGenres(t),
            }.take(8).toList();

            final facts = <(String, Widget)>[];
            if (d?.born != null) {
              final born = d!.born!;
              final by = int.tryParse(
                born.length >= 4 ? born.substring(0, 4) : born,
              );
              final endYear = d.died != null
                  ? int.tryParse(
                      d.died!.length >= 4 ? d.died!.substring(0, 4) : d.died!,
                    )
                  : DateTime.now().year;
              final age = (by != null && endYear != null) ? endYear - by : null;
              facts.add((
                'Born',
                Text(
                  '$born${d.died != null ? ' – ${d.died}' : ''}'
                  '${age != null ? ' (${d.died != null ? 'aged' : 'age'} $age)' : ''}',
                ),
              ));
            }
            if (d?.area != null) facts.add(('Origin', Text(d!.area!)));
            if (genres.isNotEmpty) {
              // GAP: genre pills don't navigate — genre pages belong to the
              // library feature; wire a path contract when it lands.
              facts.add((
                'Genres',
                Wrap(
                  spacing: AriaSpace.s1,
                  runSpacing: AriaSpace.s1,
                  children: [for (final g in genres) FilterPill(label: g)],
                ),
              ));
            }

            if (img == null && facts.isEmpty) return const SizedBox.shrink();

            return Padding(
              padding: const EdgeInsets.only(bottom: AriaSpace.s6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (img != null) ...[
                    ArtImage(
                      url: img,
                      fallbackText: name,
                      size: 150,
                      borderRadius: AriaRadius.lg,
                    ),
                    const SizedBox(width: AriaSpace.s6),
                  ],
                  Expanded(
                    child: facts.isEmpty
                        ? InkWell(
                            onTap: onMoreBio,
                            child: Text(
                              'No details yet — see the Info tab.',
                              style: TextStyle(color: c.fgDim),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final (k, v) in facts)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    bottom: AriaSpace.s2,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: 64,
                                        child: Text(
                                          k,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: c.fgDim,
                                          ),
                                        ),
                                      ),
                                      Expanded(child: v),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            );
          },
        );
  }
}

/// Top tracks for this artist from play stats (legacy: active profile's
/// stats; GAP: unscoped until a shared activeProfileProvider exists).
class _TopTracks extends ConsumerWidget {
  const _TopTracks({required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final stats = ref.watch(artistStatsProvider).value;
    // Shared cached id map — don't rebuild a 100k-entry map per build.
    final byId = ref.watch(trackByIdProvider);
    if (stats == null || byId.isEmpty) return const SizedBox.shrink();
    final top = [
      for (final x in stats.topTracks)
        if (byId[x.id] != null &&
            (byId[x.id]!.artist == name || byId[x.id]!.albumArtist == name))
          (byId[x.id]!, x.count),
    ].take(10).toList();
    if (top.isEmpty) return const SizedBox.shrink();
    final list = [for (final (t, _) in top) t];
    final currentId = ref.watch(currentTrackProvider)?.id;
    final queue = ref.read(queueProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AriaSpace.s3),
          child: Text(
            'Top Tracks',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        for (final (i, (t, count)) in top.indexed)
          InkWell(
            onTap: () => queue.playQueue(list, i),
            onSecondaryTapUp: (d) => showAriaContextMenu(
              context,
              d.globalPosition,
              actions.trackMenuItems(context, ref, t),
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
                      t.id == currentId ? '▶' : '${i + 1}',
                      style: TextStyle(
                        color: t.id == currentId ? c.accent : c.fgDim,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.title ?? '',
                          style: TextStyle(
                            color: t.id == currentId ? c.accent : c.fg,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          t.album ?? '',
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(
                    '$count play${count == 1 ? '' : 's'}',
                    style: TextStyle(color: c.fgDim),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: AriaSpace.s5),
      ],
    );
  }
}

/// Band Members / Member Of / Similar Artists shelves (legacy people()).
class _PeopleShelves extends ConsumerWidget {
  const _PeopleShelves({required this.name, required this.inLibrary});

  final String name;
  final Set<String> inLibrary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(artistInfoProvider(name)).value;
    if (d == null) return const SizedBox.shrink();
    final people = ref.watch(artistPeopleProvider).value ?? const {};

    Widget shelfOf(String heading, List<(String, String?)> entries) => Padding(
      padding: const EdgeInsets.only(bottom: AriaSpace.s5),
      child: Shelf(
        title: heading,
        height: 184,
        itemWidth: 132,
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final (n, img) = entries[i];
          return PersonCard(
            name: n,
            subtitle: inLibrary.contains(n) ? 'In library' : '',
            imageUrl: img ?? people[n],
            // every card is a door, in library or not (legacy)
            onTap: () => context.push(artistPath(n)),
          );
        },
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // this artist is a group (MB member-of-band rels)
        if (d.members.isNotEmpty)
          shelfOf('Band Members', [for (final n in d.members) (n, null)]),
        // groups this person plays/played in
        if (d.bands.isNotEmpty)
          shelfOf('Member Of', [for (final n in d.bands) (n, null)]),
        if (d.similar.isNotEmpty)
          shelfOf('Similar Artists', [
            for (final s in d.similar) (s.name, s.image),
          ]),
      ],
    );
  }
}
