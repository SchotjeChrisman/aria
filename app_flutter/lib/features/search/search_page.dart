import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/downloads.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/artist_avatar.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/library_cards.dart';
import '../../widgets/selection_highlight.dart';
import '../../widgets/track_actions.dart';
import '../../widgets/track_row.dart';
import 'library_lookup.dart';
import 'translit.dart';

// The server has no FTS endpoint (openapi: /api/tracks takes only
// limit/offset), so search is client-side over the cached library —
// exactly the legacy matches() model including its transliteration pass.

final searchQueryProvider = NotifierProvider<_QueryNotifier, String>(
  _QueryNotifier.new,
);

class _QueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String q) => state = q.trim().toLowerCase();
}

class SearchResults {
  const SearchResults({
    this.artists = const [],
    this.albums = const [],
    this.tracks = const [],
  });

  final List<String> artists;
  final List<Album> albums;
  final List<Track> tracks;

  bool get isEmpty => artists.isEmpty && albums.isEmpty && tracks.isEmpty;
}

/// Client-side scan of the whole library (up to 6 fields per track, plus
/// transliteration) — too heavy to run per keystroke at 100k tracks, so it
/// is debounced like [mbArtistsProvider] via autoDispose cancellation.
final searchResultsProvider = FutureProvider.autoDispose<SearchResults>((
  ref,
) async {
  final q = ref.watch(searchQueryProvider);
  if (q.isEmpty) return const SearchResults();
  var cancelled = false;
  ref.onDispose(() => cancelled = true);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  if (cancelled) return const SearchResults();
  final tracks = ref.watch(libraryTracksProvider).value ?? const [];
  final albums = ref.watch(albumsProvider);

  bool m(String? s) => matchesQuery(s, q);

  final artists = <String>{};
  final trackHits = <Track>[];
  for (final t in tracks) {
    if (m(t.artist)) artists.add(t.artist!);
    if (m(t.albumArtist)) artists.add(t.albumArtist!);
    if (m(t.composer)) artists.add(t.composer!);
    // Legacy matched title, composer and work on track rows.
    if ((m(t.title) || m(t.composer) || m(t.work)) && trackHits.length < 100) {
      trackHits.add(t);
    }
  }
  final albumHits = [
    for (final a in albums)
      if (m(a.title) || m(a.albumArtist)) a,
  ]..sort((x, y) => x.title.toLowerCase().compareTo(y.title.toLowerCase()));

  final artistList = artists.toList()
    ..sort((x, y) => x.toLowerCase().compareTo(y.toLowerCase()));

  return SearchResults(
    artists: artistList.take(24).toList(),
    albums: albumHits.take(48).toList(),
    tracks: trackHits,
  );
});

/// MusicBrainz artist candidates for the query — the common case is
/// searching for an artist not in the library yet. Tapping one opens the
/// regular artist page, which enriches by name like any not-in-library
/// artist. Debounced against keystrokes (and MB rate limits) via
/// autoDispose cancellation.
final mbArtistsProvider = FutureProvider.autoDispose<List<ArtistCandidate>>((
  ref,
) async {
  final q = ref.watch(searchQueryProvider);
  if (q.length < 3) return const [];
  var cancelled = false;
  ref.onDispose(() => cancelled = true);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  if (cancelled) return const [];
  final candidates = await ref.watch(apiClientProvider).identifyArtist(q);
  // Skip artists the library sections already show, and MB's low-score fuzz.
  final inLibrary = {
    for (final a
        in ref.read(searchResultsProvider).value?.artists ?? const <String>[])
      a.toLowerCase(),
  };
  return [
    for (final c in candidates)
      if ((c.score ?? 0) >= 75 && !inLibrary.contains(c.name.toLowerCase())) c,
  ].take(6).toList();
});

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  late final TextEditingController _ctrl = TextEditingController(
    text: ref.read(searchQueryProvider),
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final library = ref.watch(libraryTracksProvider);
    // Previous results stay visible while the debounced scan re-runs.
    final results =
        ref.watch(searchResultsProvider).value ?? const SearchResults();
    final mb = ref.watch(mbArtistsProvider);
    final nothingAnywhere =
        results.isEmpty && mb.hasValue && (mb.value?.isEmpty ?? true);

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AriaSpace.s6,
                AriaSpace.s6,
                AriaSpace.s6,
                AriaSpace.s3,
              ),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search your library and MusicBrainz…',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => ref.read(searchQueryProvider.notifier).set(v),
              ),
            ),
            Expanded(
              // hasValue (not AsyncData) so a library refetch after a
              // metadata edit keeps showing results instead of a spinner.
              child: switch (library) {
                AsyncError() => const EmptyState(
                  message: 'Library unavailable — check the server.',
                  icon: Icons.cloud_off,
                ),
                AsyncValue(hasValue: true) when query.isEmpty =>
                  const EmptyState(
                    message: 'Type to search titles, artists and albums.',
                    icon: Icons.search,
                  ),
                AsyncValue(hasValue: true) when nothingAnywhere => EmptyState(
                  message: 'Nothing matches "$query".',
                  icon: Icons.search_off,
                ),
                AsyncValue(hasValue: true) => _ResultsList(results: results),
                _ => const Center(child: CircularProgressIndicator()),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsList extends ConsumerWidget {
  const _ResultsList({required this.results});

  final SearchResults results;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(peopleProvider).value ?? const {};
    final queue = ref.read(queueProvider.notifier);
    final current = ref.watch(currentTrackProvider);
    final style = Theme.of(context).textTheme.titleMedium;
    final mb = ref.watch(mbArtistsProvider);
    final mbArtists = mb.value ?? const <ArtistCandidate>[];

    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: AriaSpace.s6,
        vertical: AriaSpace.s3,
      ),
      children: [
        if (results.artists.isNotEmpty) ...[
          Text('Artists', style: style),
          const SizedBox(height: AriaSpace.s3),
          SizedBox(
            height: 120,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: results.artists.length,
              separatorBuilder: (_, _) => const SizedBox(width: AriaSpace.s4),
              itemBuilder: (context, i) {
                final name = results.artists[i];
                final tracks =
                    ref.watch(libraryTracksProvider).value ?? const <Track>[];
                List<Track> artistTracks() => [
                  for (final t in tracks)
                    if (t.artist == name || t.albumArtist == name) t,
                ];
                return SelectionHighlight(
                  kind: 'artist',
                  itemKey: name,
                  child: GestureDetector(
                    onTap: () {
                      if (selectionTapHandled(
                        ref,
                        artistSelectionItem(name, artistTracks()),
                      )) {
                        return;
                      }
                      context.push(artistPath(name));
                    },
                    onSecondaryTapUp: (d) => showAriaContextMenu(
                      context,
                      d.globalPosition,
                      artistMenuItems(
                        context,
                        ref,
                        name: name,
                        tracks: artistTracks(),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ArtistAvatar(
                          name: name,
                          imageUrl: people[name],
                          size: 72,
                        ),
                        const SizedBox(height: AriaSpace.s2),
                        SizedBox(
                          width: 88,
                          child: Text(
                            name,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: AriaSpace.s6),
        ],
        if (mb.isLoading && results.isEmpty)
          const Padding(
            padding: EdgeInsets.all(AriaSpace.s6),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (mbArtists.isNotEmpty) ...[
          Text('On MusicBrainz', style: style),
          const SizedBox(height: AriaSpace.s2),
          for (final a in mbArtists)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: ArtistAvatar(name: a.name, size: 40),
              title: Text(a.name),
              subtitle: Text(
                [
                  a.type,
                  a.area,
                  a.disambiguation,
                ].nonNulls.where((s) => s.isNotEmpty).join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right),
              // Same flow as any not-in-library artist (e.g. New Releases):
              // the artist page enriches by name.
              onTap: () => context.push(artistPath(a.name)),
            ),
          const SizedBox(height: AriaSpace.s6),
        ],
        if (results.albums.isNotEmpty) ...[
          Text('Albums', style: style),
          const SizedBox(height: AriaSpace.s3),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: AriaBreakpoint.of(context).gridColumns,
              mainAxisSpacing: AriaSpace.s5,
              crossAxisSpacing: AriaSpace.s5,
              // Tablet-floor tiles (~103px at a 600px window) need a taller
              // cell: the ~49px text block under the square art doesn't
              // shrink with the tile.
              childAspectRatio:
                  AriaBreakpoint.of(context) == AriaBreakpoint.tablet
                  ? 0.67
                  : 0.72,
            ),
            itemCount: results.albums.length,
            itemBuilder: (context, i) {
              final a = results.albums[i];
              return AlbumGridCard(
                albumId: a.id,
                title: a.title,
                artistName: a.albumArtist,
                tracks: a.tracks,
                hasArt: a.hasArt,
              );
            },
          ),
          const SizedBox(height: AriaSpace.s6),
        ],
        if (results.tracks.isNotEmpty) ...[
          Text('Tracks', style: style),
          const SizedBox(height: AriaSpace.s2),
          for (var i = 0; i < results.tracks.length; i++)
            SelectionHighlight(
              kind: 'track',
              itemKey: results.tracks[i].id,
              child: TrackRow(
                number: i + 1,
                title: results.tracks[i].title ?? '',
                subtitle: [
                  results.tracks[i].artist,
                  results.tracks[i].album,
                ].nonNulls.join(' · '),
                duration: results.tracks[i].duration,
                format: results.tracks[i].format,
                bitsPerSample: results.tracks[i].bitsPerSample,
                sampleRate: results.tracks[i].sampleRate,
                lossless: results.tracks[i].lossless,
                downloaded: ref.watch(
                  downloadsProvider.select(
                    (s) => s.index.containsKey(results.tracks[i].id),
                  ),
                ),
                isCurrent: current?.id == results.tracks[i].id,
                onTap: () {
                  if (selectionTapHandled(
                    ref,
                    trackSelectionItem(results.tracks[i]),
                  )) {
                    return;
                  }
                  queue.playQueue(results.tracks, i);
                },
                onSecondary: (pos) => showAriaContextMenu(
                  context,
                  pos,
                  trackMenuItems(context, ref, results.tracks[i]),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
