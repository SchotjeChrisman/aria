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

/// True when the album's directory holds a booklet PDF; errors read as
/// "no booklet" (cosmetic data, house pattern).
final hasBookletProvider = FutureProvider.family<bool, String>((
  ref,
  albumId,
) async {
  try {
    return await ref.watch(albumApiProvider).hasBooklet(albumId);
  } catch (_) {
    return false;
  }
});

/// Up to [limit] albums sharing canonical genres with [target], never by the
/// same artist — "relate on music, not on artist" (issue #7).
/// score = 3 * shared genres + year proximity (+2 within 3y, +1 within 10y).
// ponytail: exact-genre match only; genre-tree ancestor matching would need
// /api/genres — add if results feel thin.
List<Album> relatedAlbums(Album target, Iterable<Album> all, {int limit = 12}) {
  Set<String> genresOf(Album a) => {for (final t in a.tracks) ...t.genres};
  final targetGenres = genresOf(target);
  if (targetGenres.isEmpty) return const [];
  final artist = target.albumArtist.toLowerCase();

  final scored = <(int, Album)>[];
  for (final a in all) {
    if (a.id == target.id || a.albumArtist.toLowerCase() == artist) continue;
    final shared = genresOf(a).intersection(targetGenres).length;
    if (shared == 0) continue;
    var score = 3 * shared;
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
  return relatedAlbums(target, byId.values);
});
