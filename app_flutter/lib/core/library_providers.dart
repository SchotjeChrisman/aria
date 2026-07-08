import 'dart:async';
import 'dart:convert';

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

/// Canonical genre -> parent tree. Old/unreachable servers degrade to a flat
/// genre list, exactly like the legacy loadLibrary() catch.
final genreTreeProvider = FutureProvider<GenreTree>((ref) async {
  try {
    return await ref.watch(apiClientProvider).genres();
  } catch (_) {
    return const GenreTree({});
  }
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

/// True while the server reports an enrichment pass in flight.
bool enrichBusy(Object? statusJson) =>
    statusJson is Map &&
    (statusJson['running'] == true || statusJson['phase'] != 'idle');

/// App-lifetime `enrich` SSE watcher: when a server pass finishes
/// (busy -> idle) the library caches refresh, no matter which screen is
/// open — enrichment is server-side work, the app just reacts to it.
/// Watched by TransportBar; the Settings poller only renders progress.
final enrichRefreshProvider = Provider<void>((ref) {
  final client = ref.watch(apiClientProvider);
  var disposed = false;
  // The reconnect delay must be a cancellable Timer, not Future.delayed —
  // dispose (server-URL change, test teardown) has to stop it immediately.
  Timer? retry;
  ref.onDispose(() {
    disposed = true;
    retry?.cancel();
  });
  var wasBusy = false;

  void seen(bool busy) {
    if (wasBusy && !busy) invalidateLibrary(ref);
    wasBusy = busy;
  }

  Future<void> tick() async {
    try {
      // A pass may have ended while disconnected — one status probe on
      // (re)connect closes that gap before we trust the stream.
      final s = await client.enrichStatus();
      if (disposed) return;
      seen(s.phase != 'idle');
      await for (final e in client.events()) {
        if (disposed) return;
        if (e.event != 'enrich') continue;
        try {
          seen(enrichBusy(jsonDecode(e.data)));
        } on FormatException {
          // malformed frame — ignore, the next one corrects us
        }
      }
    } catch (_) {
      // server away — quiet retry, same cadence as the settings poller
    }
    if (!disposed) retry = Timer(const Duration(seconds: 5), tick);
  }

  tick();
});
