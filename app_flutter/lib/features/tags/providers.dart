import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/library_providers.dart';

// tagsProvider/TagsNotifier live in core so the tag picker in lib/widgets
// and every feature share one cache.
export '../../core/tags_providers.dart' show TagsNotifier, tagsProvider;

/// Album grouping of one track batch (legacy loadLibrary() albums map).
class AlbumGroup {
  AlbumGroup({
    required this.id,
    required this.album,
    required this.albumArtist,
    this.year,
  });

  final String id;
  final String album;
  final String albumArtist;
  final int? year;
  final List<Track> tracks = [];
}

/// Track/album/artist lookups for the tag detail page, derived from the
/// shared core library cache.
class LibraryIndex {
  LibraryIndex(List<Track> tracks) {
    for (final t in tracks) {
      byId[t.id] = t;
      final a = albums.putIfAbsent(
        t.albumId,
        () => AlbumGroup(
          id: t.albumId,
          album: t.album ?? 'Unknown Album',
          albumArtist: t.albumArtist ?? t.artist ?? 'Unknown Artist',
          year: t.year,
        ),
      );
      a.tracks.add(t);
      artistNames.add(t.albumArtist ?? t.artist ?? 'Unknown Artist');
    }
    for (final a in albums.values) {
      a.tracks.sort(
        (x, y) => (x.discNo ?? 1) != (y.discNo ?? 1)
            ? (x.discNo ?? 1) - (y.discNo ?? 1)
            : (x.trackNo ?? 0) - (y.trackNo ?? 0),
      );
    }
  }

  final byId = <String, Track>{};
  final albums = <String, AlbumGroup>{};
  final artistNames = <String>{};
}

final libraryIndexProvider = FutureProvider<LibraryIndex>((ref) async {
  final tracks = await ref.watch(libraryTracksProvider.future);
  return LibraryIndex(tracks);
});
