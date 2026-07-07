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
