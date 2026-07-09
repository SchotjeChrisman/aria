import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/library_providers.dart';
import '../../core/profiles_providers.dart';

/// Server-computed home mixes for the active profile; re-fetched on profile
/// switch, mirrors [homeStatsProvider].
final mixesProvider = FutureProvider<Mixes>((ref) async {
  await ref.watch(profilesProvider.future);
  final pid = ref.watch(activeProfileIdProvider);
  return ref.watch(apiClientProvider).mixes(profileId: pid);
});

/// One resolved mix: a stable [id] (route key), display [title]/[subtitle], and
/// the tracks in server rank order (unknown ids dropped).
typedef HomeMix = ({String id, String title, String subtitle, List<Track> tracks});

/// The four mixes with client-side titles from the local date and trackIds
/// resolved against the library. Empty mixes are kept (callers hide them).
final homeMixesProvider = Provider<List<HomeMix>>((ref) {
  final mixes = ref.watch(mixesProvider).value;
  if (mixes == null) return const [];
  final byId = ref.watch(trackByIdProvider);
  final now = DateTime.now();

  List<Track> resolve(List<String> ids) =>
      [for (final id in ids) ?byId[id]];

  HomeMix mk(String id, String title, List<String> ids) {
    final tracks = resolve(ids);
    return (
      id: id,
      title: title,
      subtitle: '${tracks.length} track${tracks.length == 1 ? '' : 's'}',
      tracks: tracks,
    );
  }

  return [
    mk('daily', 'Daily Mix', mixes.daily),
    mk('weekly', 'Weekly Mix', mixes.weekly),
    mk('monthly', '${_monthNames[now.month - 1]} Mix', mixes.monthly),
    mk('yearly', '${now.year} Top 100', mixes.yearly),
  ];
});

/// Look up a single resolved mix by its route id.
HomeMix? homeMixById(WidgetRef ref, String id) {
  for (final m in ref.watch(homeMixesProvider)) {
    if (m.id == id) return m;
  }
  return null;
}

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];
