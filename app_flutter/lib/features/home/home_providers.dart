import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/library_providers.dart';
import '../../core/profiles_providers.dart';

/// Albums grouped from the shared library cache (legacy albums map).
final homeAlbumsProvider = Provider<List<Album>>(
  (ref) => Album.group(ref.watch(libraryTracksProvider).value ?? const []),
);

final homeAlbumByIdProvider = Provider<Map<String, Album>>(
  (ref) => {for (final a in ref.watch(homeAlbumsProvider)) a.id: a},
);

/// Stats for the active profile; re-fetched on profile switch (legacy
/// fetchStats(profileId) on home).
final homeStatsProvider = FutureProvider<Stats>((ref) async {
  await ref.watch(profilesProvider.future);
  final pid = ref.watch(activeProfileIdProvider);
  return ref.watch(apiClientProvider).stats(profileId: pid);
});

/// Per-track play counts for the active profile over a period (week/month/
/// year/all) — the Listening ranks card multiplies these by track durations.
final periodCountsProvider =
    FutureProvider.family<Map<String, int>, String>((ref, period) async {
  await ref.watch(profilesProvider.future);
  final pid = ref.watch(activeProfileIdProvider);
  return ref.watch(apiClientProvider).playCountsFor(profileId: pid, period: period);
});

/// Latest addedAt across an album's tracks (legacy addedAt(), ISO strings
/// compare lexicographically).
String albumAddedAt(Album a) {
  var mx = '';
  for (final t in a.tracks) {
    final at = t.addedAt;
    if (at != null && at.compareTo(mx) > 0) mx = at;
  }
  return mx;
}

/// Legacy fmtHm: "3h 42m", minutes only under an hour.
String fmtHm(num seconds) {
  final m = seconds ~/ 60;
  final h = m ~/ 60;
  return h > 0 ? '${h}h ${m % 60}m' : '${m}m';
}
