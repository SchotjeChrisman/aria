import 'package:aria_api/aria_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library_providers.dart';

// Album-grid filters: genre / decade / format / tag. Matching semantics are
// the legacy trackPassesFilters() ones (msPass any-mode), lifted to albums:
// an album passes when ANY of its tracks passes every active filter.

@immutable
class AlbumFilters {
  const AlbumFilters({
    this.genres = const {},
    this.formats = const {},
    this.tags = const {},
    this.decade,
  });

  final Set<String> genres;
  final Set<String> formats;
  final Set<String> tags;

  /// Decade start year — 1970 means 1970–1979.
  final int? decade;

  /// Legacy activeFilterCount(): one per active filter group, for the badge.
  int get activeCount =>
      (genres.isEmpty ? 0 : 1) +
      (formats.isEmpty ? 0 : 1) +
      (tags.isEmpty ? 0 : 1) +
      (decade == null ? 0 : 1);

  bool get isEmpty => activeCount == 0;

  AlbumFilters copyWith({
    Set<String>? genres,
    Set<String>? formats,
    Set<String>? tags,
    int? Function()? decade,
  }) => AlbumFilters(
    genres: genres ?? this.genres,
    formats: formats ?? this.formats,
    tags: tags ?? this.tags,
    decade: decade == null ? this.decade : decade(),
  );
}

class AlbumFiltersNotifier extends Notifier<AlbumFilters> {
  @override
  AlbumFilters build() => const AlbumFilters();

  Set<String> _toggle(Set<String> s, String v) =>
      s.contains(v) ? ({...s}..remove(v)) : {...s, v};

  void toggleGenre(String g) =>
      state = state.copyWith(genres: _toggle(state.genres, g));
  void toggleFormat(String f) =>
      state = state.copyWith(formats: _toggle(state.formats, f));
  void toggleTag(String t) =>
      state = state.copyWith(tags: _toggle(state.tags, t));
  void setDecade(int? d) => state = state.copyWith(decade: () => d);
  void clear() => state = const AlbumFilters();
}

final albumFiltersProvider =
    NotifierProvider<AlbumFiltersNotifier, AlbumFilters>(
      AlbumFiltersNotifier.new,
    );

String _lc(String s) => s.toLowerCase();

bool _trackPasses(
  Track t,
  AlbumFilters f,
  Map<String, String?> parents,
  TagNameIndex tagIndex,
) {
  // Genre matches exactly against the track's genres + ancestors, so 'Pop'
  // does not substring-match 'Pop Rock' (legacy msPass exact=true).
  if (f.genres.isNotEmpty) {
    final up = trackGenresUp(t, parents).map(_lc).toSet();
    if (!f.genres.any((g) => up.contains(_lc(g)))) return false;
  }
  if (f.formats.isNotEmpty) {
    final fmt = _lc(t.format ?? '');
    if (!f.formats.any((q) => fmt.contains(_lc(q)))) return false;
  }
  if (f.tags.isNotEmpty) {
    final names = tagIndex.namesFor(t).map(_lc).toSet();
    if (!f.tags.any((q) => names.contains(_lc(q)))) return false;
  }
  if (f.decade != null) {
    final y = t.year;
    if (y == null || y < f.decade! || y > f.decade! + 9) return false;
  }
  return true;
}

bool albumPassesFilters(
  Album a,
  AlbumFilters f, {
  required Map<String, String?> parents,
  required TagNameIndex tagIndex,
}) => f.isEmpty || a.tracks.any((t) => _trackPasses(t, f, parents, tagIndex));

// ---------------------------------------------------------- option lists

/// All canonical genres present in the library, plus their ancestors.
final genreOptionsProvider = Provider<List<String>>((ref) {
  final idx = ref.watch(genreIndexProvider);
  final parents = ref.watch(genreParentsProvider);
  final out = <String>{};
  for (final g in idx.keys) {
    out.add(g);
    for (var p = parents[g]; p != null && out.add(p); p = parents[p]) {}
  }
  return out.toList()..sort((a, b) => _lc(a).compareTo(_lc(b)));
});

final formatOptionsProvider = Provider<List<String>>((ref) {
  final out = <String>{};
  for (final t in ref.watch(loadedTracksProvider)) {
    final f = t.format;
    if (f != null && f.isNotEmpty) out.add(f.toUpperCase());
  }
  return out.toList()..sort();
});

final tagOptionsProvider = Provider<List<String>>((ref) {
  final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
  final names = {for (final t in tags) t.name};
  return names.toList()..sort((a, b) => _lc(a).compareTo(_lc(b)));
});

/// Decade start years present in the library, newest first.
final decadeOptionsProvider = Provider<List<int>>((ref) {
  final out = <int>{};
  for (final t in ref.watch(loadedTracksProvider)) {
    final y = t.year;
    if (y != null && y > 0) out.add(y - y % 10);
  }
  return out.toList()..sort((a, b) => b.compareTo(a));
});
