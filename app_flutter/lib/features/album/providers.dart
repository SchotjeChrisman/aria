import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/library_providers.dart';

/// Core client/caches under this feature's historical names — one HTTP
/// client and one /api/tracks fetch shared app-wide; invalidating
/// [albumTracksProvider] (metadata edits) refreshes every feature.
final albumApiProvider = apiClientProvider;
final albumTracksProvider = libraryTracksProvider;

final albumsByIdProvider = FutureProvider<Map<String, Album>>((ref) async {
  final tracks = await ref.watch(albumTracksProvider.future);
  return {for (final a in Album.group(tracks)) a.id: a};
});

/// Label/date/country (MusicBrainz) + blurb (Wikipedia), cached server-side.
/// null = nothing known about this album yet.
final albumInfoProvider = FutureProvider.family<AlbumInfo?, String>(
  (ref, albumId) => ref.watch(albumApiProvider).albumInfo(albumId),
);

/// name -> portrait URL, for the performer credit cards.
final albumPeopleProvider = peopleProvider;

/// Booklet PDF names in the album's directory, best first; errors read as
/// "no booklet" (cosmetic data, house pattern).
final bookletsProvider = FutureProvider.family<List<String>, String>((
  ref,
  albumId,
) async {
  try {
    return await ref.watch(albumApiProvider).booklets(albumId);
  } catch (_) {
    return const [];
  }
});

/// Up to [limit] albums sharing canonical genres with [target], never by the
/// same artist — "relate on music, not on artist" (issue #7).
/// score = 3 * shared genres + 1 * shared genre families (a genre or its
/// [parents] entry matching the other side) + year proximity (+2 within 3y,
/// +1 within 10y). Pass an empty tree to fall back to exact matches only.
List<Album> relatedAlbums(
  Album target,
  Iterable<Album> all, {
  Map<String, String?> parents = const {},
  int limit = 12,
}) {
  Set<String> genresOf(Album a) => {for (final t in a.tracks) ...t.genres};
  // Genres plus their parent categories: "Blues Rock" also counts as "Rock",
  // so cousins in the taxonomy still relate when exact tags never overlap.
  Set<String> familyOf(Set<String> genres) => {
    ...genres,
    for (final g in genres)
      if (parents[g] case final String p) p,
  };
  final targetGenres = genresOf(target);
  if (targetGenres.isEmpty) return const [];
  final targetFamily = familyOf(targetGenres);
  final artist = target.albumArtist.toLowerCase();

  final scored = <(int, Album)>[];
  for (final a in all) {
    if (a.id == target.id || a.albumArtist.toLowerCase() == artist) continue;
    final genres = genresOf(a);
    final shared = genres.intersection(targetGenres).length;
    final kin = familyOf(genres).intersection(targetFamily).length;
    if (kin == 0) continue;
    // kin counts exact matches too, so exact overlap weighs 3+1=4 vs 1.
    var score = 3 * shared + kin;
    if (target.year != null && a.year != null) {
      final d = (target.year! - a.year!).abs();
      score += d <= 3
          ? 2
          : d <= 10
          ? 1
          : 0;
    }
    scored.add((score, a));
  }
  scored.sort((x, y) {
    final d = y.$1 - x.$1;
    return d != 0 ? d : x.$2.title.compareTo(y.$2.title);
  });
  return [for (final s in scored.take(limit)) s.$2];
}

final relatedAlbumsProvider = FutureProvider.family<List<Album>, String>((
  ref,
  albumId,
) async {
  final byId = await ref.watch(albumsByIdProvider.future);
  final target = byId[albumId];
  if (target == null) return const [];
  final tree = await ref.watch(genreTreeProvider.future);
  return relatedAlbums(target, byId.values, parents: tree.parents);
});
