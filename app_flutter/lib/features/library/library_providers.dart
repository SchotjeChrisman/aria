import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/library_providers.dart';
import '../../core/player_providers.dart';
import '../../core/tags_providers.dart';

// Data layer for the browse pages, ported from legacy loadLibrary()/
// genreIndex()/tagsOf() in app/ui/app.js. Everything derives from core's
// one /api/tracks cache; refresh with ref.invalidate(tracksProvider).

export '../../core/library_providers.dart' show peopleProvider;
export '../../core/tags_providers.dart' show tagsProvider;

/// The core library cache under its legacy browse-layer name — invalidating
/// either name refreshes every feature.
final tracksProvider = libraryTracksProvider;

/// Canonical genre -> parent tree. Old/unreachable servers degrade to a flat
/// genre list, exactly like the legacy loadLibrary() catch.
final genreTreeProvider = FutureProvider<GenreTree>((ref) async {
  try {
    return await ref.watch(apiClientProvider).genres();
  } catch (_) {
    return const GenreTree({});
  }
});

/// Per-track play counts. Only fetched once something watches it (the
/// "Most played" sorts), mirroring legacy ensurePlayCounts() laziness.
/// NOTE: profile-unaware until the profiles feature lands.
final playCountsProvider = FutureProvider<Map<String, int>>((ref) async {
  try {
    final st = await ref.watch(apiClientProvider).stats(counts: true);
    return st.playCounts ?? const {};
  } catch (_) {
    return const {};
  }
});

/// Loaded tracks, or empty while loading/failed. Derived providers hang off
/// this; screens gate on [tracksProvider]'s AsyncValue for spinners/errors.
final loadedTracksProvider = Provider<List<Track>>(
  (ref) => ref.watch(tracksProvider).value ?? const [],
);

final albumsProvider = Provider<List<Album>>(
  (ref) => Album.group(ref.watch(loadedTracksProvider)),
);

/// Rehydrates the persisted queue against the loaded library (legacy
/// restorePlayback). QueueNotifier.restore is first-load-only, so re-fires
/// on library refresh are harmless. Watched by LibraryScreen.
final queueRestoreProvider = Provider<void>((ref) {
  final tracks = ref.watch(loadedTracksProvider);
  if (tracks.isEmpty) return;
  final byId = ref.watch(trackByIdProvider);
  // Riverpod forbids mutating other providers while one is building —
  // restore must run after this build completes, never inside it.
  var alive = true;
  ref.onDispose(() => alive = false);
  Future.microtask(() {
    if (alive) ref.read(queueProvider.notifier).restore((id) => byId[id]);
  });
});

final albumByIdProvider = Provider<Map<String, Album>>(
  (ref) => {for (final a in ref.watch(albumsProvider)) a.id: a},
);

final genreParentsProvider = Provider<Map<String, String?>>(
  (ref) => ref.watch(genreTreeProvider).value?.parents ?? const {},
);

/// Legacy `t.albumArtist || t.artist || 'Unknown Artist'` (empty = missing).
String displayArtist(Track t) {
  final aa = t.albumArtist;
  if (aa != null && aa.isNotEmpty) return aa;
  final a = t.artist;
  if (a != null && a.isNotEmpty) return a;
  return 'Unknown Artist';
}

/// Legacy tg(): canonical genres, raw file tag as fallback for old servers.
List<String> trackGenres(Track t) {
  if (t.genres.isNotEmpty) return t.genres;
  final g = t.genre;
  return (g == null || g.isEmpty) ? const [] : [g];
}

/// Legacy tgUp(): track genres plus their ancestors, so a "Blues" filter
/// also catches Blues Rock tracks.
List<String> trackGenresUp(Track t, Map<String, String?> parents) {
  final out = <String>[...trackGenres(t)];
  for (final g in trackGenres(t)) {
    for (var p = parents[g]; p != null && !out.contains(p); p = parents[p]) {
      out.add(p);
    }
  }
  return out;
}

// ---------------------------------------------------------------- genres

class GenreBucket {
  final List<Track> tracks = [];
  final Set<String> albumIds = {};
  final Set<String> artistNames = {};
}

/// Canonical genre -> direct hits only; pages roll up children via
/// [genreScope] (legacy genreIndex()).
final genreIndexProvider = Provider<Map<String, GenreBucket>>((ref) {
  final idx = <String, GenreBucket>{};
  for (final t in ref.watch(loadedTracksProvider)) {
    for (final g in trackGenres(t)) {
      final b = idx.putIfAbsent(g, GenreBucket.new);
      b.tracks.add(t);
      b.albumIds.add(t.albumId);
      b.artistNames.add(displayArtist(t));
    }
  }
  return idx;
});

List<String> genreChildren(Map<String, String?> parents, String g) => [
  for (final e in parents.entries)
    if (e.value == g) e.key,
];

/// The genre plus its library-present children (the tree is two levels deep).
List<String> genreScope(
  String g,
  Map<String, String?> parents,
  Map<String, GenreBucket> index,
) => [g, ...genreChildren(parents, g)].where(index.containsKey).toList();

// ---------------------------------------------------------------- artists

class ArtistEntry {
  ArtistEntry(this.name);
  final String name;
  final Set<String> albumIds = {};
}

final artistsProvider = Provider<List<ArtistEntry>>((ref) {
  final byName = <String, ArtistEntry>{};
  for (final t in ref.watch(loadedTracksProvider)) {
    final n = displayArtist(t);
    byName.putIfAbsent(n, () => ArtistEntry(n)).albumIds.add(t.albumId);
  }
  return byName.values.toList();
});

// -------------------------------------------------------------- composers

final _classicalRe = RegExp(
  'classical|opera|baroque|symphony|orchestral',
  caseSensitive: false,
);

class ComposerEntry {
  ComposerEntry(this.name);
  final String name;
  final Set<String> albumIds = {};
  final Set<String> works = {};
}

/// Pop songwriter credits share the COMPOSER tag; only classical-shaped
/// tracks surface composers (legacy heuristic, ported verbatim).
final composersProvider = Provider<List<ComposerEntry>>((ref) {
  final parents = ref.watch(genreParentsProvider);
  final byName = <String, ComposerEntry>{};
  for (final t in ref.watch(loadedTracksProvider)) {
    final name = t.composer;
    if (name == null || name.isEmpty) continue;
    final classicalShape =
        (t.work?.isNotEmpty ?? false) && (t.movement?.isNotEmpty ?? false);
    if (!classicalShape &&
        !trackGenresUp(t, parents).any(_classicalRe.hasMatch)) {
      continue;
    }
    final e = byName.putIfAbsent(name, () => ComposerEntry(name));
    e.albumIds.add(t.albumId);
    final w = t.work;
    if (w != null && w.isNotEmpty) e.works.add(w);
  }
  return byName.values.toList();
});

// ------------------------------------------------------------------- tags

/// Tag names applicable per entity key. Each tag hit contributes its own
/// name plus all ancestor names (legacy tagsOf()/tagChainNames()).
class TagNameIndex {
  const TagNameIndex(this.byTrack, this.byAlbum, this.byArtist);

  final Map<String, Set<String>> byTrack;
  final Map<String, Set<String>> byAlbum;
  final Map<String, Set<String>> byArtist;

  /// Tags matching a track: direct, via its album, via its artist names.
  Set<String> namesFor(Track t) => {
    ...?byTrack[t.id],
    ...?byAlbum[t.albumId],
    if (t.artist != null) ...?byArtist[t.artist!],
    if (t.albumArtist != null) ...?byArtist[t.albumArtist!],
  };
}

final tagNameIndexProvider = Provider<TagNameIndex>((ref) {
  final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
  final byId = {for (final t in tags) t.id: t};

  List<String> chain(Tag tag) {
    final names = <String>[];
    final seen = <String>{};
    for (Tag? t = tag; t != null && seen.add(t.id);) {
      names.add(t.name);
      t = t.parent == null ? null : byId[t.parent];
    }
    return names;
  }

  final byTrack = <String, Set<String>>{};
  final byAlbum = <String, Set<String>>{};
  final byArtist = <String, Set<String>>{};
  for (final tag in tags) {
    final names = chain(tag);
    for (final item in tag.items) {
      final m = switch (item.kind) {
        'track' => byTrack,
        'album' => byAlbum,
        'artist' => byArtist,
        _ => null,
      };
      m?.putIfAbsent(item.key, () => <String>{}).addAll(names);
    }
  }
  return TagNameIndex(byTrack, byAlbum, byArtist);
});
