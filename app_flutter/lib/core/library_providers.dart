import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection.dart';

// The ONE whole-library cache. Every feature derives from these providers;
// mutations (rescan, enrichment, metadata edits) invalidate them here and
// every view refreshes — legacy loadLibrary() semantics.

/// Whole library, one fetch (legacy loadLibrary: full /api/tracks refetch,
/// fine below ~100k tracks). Refresh with [invalidateLibrary].
final libraryTracksProvider = FutureProvider<List<Track>>(
  (ref) => ref.watch(apiClientProvider).tracks(),
);

/// trackId -> Track (legacy byId map). Empty until the library loads.
final trackByIdProvider = Provider<Map<String, Track>>((ref) {
  final tracks = ref.watch(libraryTracksProvider).value ?? const [];
  return {for (final t in tracks) t.id: t};
});

/// Person name -> photo URL (server enrichment cache). Errors degrade to an
/// empty map — portraits are progressive enhancement.
final peopleProvider = FutureProvider<Map<String, String>>((ref) async {
  try {
    return await ref.watch(apiClientProvider).people();
  } catch (_) {
    return const {};
  }
});

/// Refresh everything derived from the track list after a rescan,
/// enrichment pass or metadata edit (legacy reloaded the whole library).
void invalidateLibrary(Ref ref) {
  ref.invalidate(libraryTracksProvider);
  ref.invalidate(peopleProvider);
}

/// An album derived from its tracks (legacy albums map): tracks are kept in
/// disc/track order, ready to queue.
class AlbumEntry {
  const AlbumEntry({required this.id, required this.tracks});

  final String id;
  final List<Track> tracks;

  Track get _rep => tracks.first;
  String get title => _rep.album ?? '';
  String get albumArtist => _rep.albumArtist ?? _rep.artist ?? '';
  int? get year => _rep.year;
  bool get hasArt => tracks.any((t) => t.hasArt);
}

/// albumId -> AlbumEntry, grouped from the flat track list.
final libraryAlbumsProvider = Provider<Map<String, AlbumEntry>>((ref) {
  final tracks = ref.watch(libraryTracksProvider).value ?? const [];
  final byAlbum = <String, List<Track>>{};
  for (final t in tracks) {
    (byAlbum[t.albumId] ??= []).add(t);
  }
  int order(Track t) => (t.discNo ?? 1) * 1000 + (t.trackNo ?? 0);
  return byAlbum.map((id, list) {
    list.sort((a, b) => order(a) - order(b));
    return MapEntry(id, AlbumEntry(id: id, tracks: list));
  });
});
