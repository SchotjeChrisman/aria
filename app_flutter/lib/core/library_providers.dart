import 'dart:async';
import 'dart:convert';
import 'native/native.dart';
import 'dart:typed_data';

import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection.dart';
import 'log.dart';

// The ONE whole-library cache. Every feature derives from these providers;
// mutations (rescan, enrichment, metadata edits) invalidate them here and
// every view refreshes — legacy loadLibrary() semantics.

/// Whole library, one fetch (legacy loadLibrary: full /api/tracks refetch,
/// fine below ~100k tracks). Refresh with [invalidateLibrary]. A successful
/// fetch is mirrored to disk so an unreachable server degrades to the last
/// known library (browsable offline, playable where downloaded).
final libraryTracksProvider = FutureProvider<List<Track>>((ref) async {
  final client = ref.watch(apiClientProvider);
  // One shared fetch: a slow/offline server falls back to the disk cache
  // after 3s instead of the full API timeout, while the original request
  // keeps running to refresh the cache if the server eventually answers.
  final fetch = client.tracksBytes();
  try {
    Uint8List bytes;
    try {
      bytes = await fetch.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      final cached = await _readTracksCache(ref);
      if (cached == null) {
        bytes = await fetch; // no offline copy — wait out the real fetch
      } else {
        unawaited(_refreshCacheWhenDone(ref, fetch));
        final tracks =
            await runOffThread(() => AriaClient.decodeTracks(cached));
        Log.i('library',
            'loaded ${tracks.length} tracks from offline cache (slow server)');
        return tracks;
      }
    }
    // Same decoder + isolate as AriaClient.tracks() — 100k rows never parse
    // on the UI isolate.
    final tracks = await runOffThread(() => AriaClient.decodeTracks(bytes));
    Log.i('library', 'loaded ${tracks.length} tracks from server');
    unawaited(_writeTracksCache(ref, bytes)); // fire-and-forget
    return tracks;
  } catch (e) {
    Log.w('library', 'load failed', e);
    final cached = await _readTracksCache(ref);
    if (cached == null) rethrow;
    final tracks = await runOffThread(() => AriaClient.decodeTracks(cached));
    Log.i('library', 'loaded ${tracks.length} tracks from offline cache');
    return tracks;
  }
});

/// After a cache fallback, mirror the (late) server response to disk when it
/// eventually arrives; errors are swallowed — the fallback already served.
/// A named helper, not an inline `.then` closure: closures capturing `ref`
/// inside the provider body poison the `runOffThread` context chain
/// (unsendable riverpod internals).
Future<void> _refreshCacheWhenDone(Ref ref, Future<Uint8List> fetch) async {
  try {
    await _writeTracksCache(ref, await fetch);
  } catch (_) {
    // server stayed away — the cache fallback already served the UI
  }
}

File _tracksCacheFile(Ref ref) =>
    File('${ref.read(appSupportDirProvider).path}/cache/tracks.json');

Future<void> _writeTracksCache(Ref ref, Uint8List bytes) async {
  try {
    final f = _tracksCacheFile(ref);
    await f.parent.create(recursive: true);
    // .part + rename: a crash mid-write must not corrupt the only offline copy
    final tmp = File('${f.path}.part');
    await tmp.writeAsBytes(bytes);
    await tmp.rename(f.path);
  } catch (e) {
    Log.w('library', 'offline cache write failed', e);
  }
}

/// Raw cached payload, or null when there is none (also: no support dir).
Future<Uint8List?> _readTracksCache(Ref ref) async {
  try {
    return await _tracksCacheFile(ref).readAsBytes();
  } catch (_) {
    return null;
  }
}

/// trackId -> Track (legacy byId map). Empty until the library loads.
final trackByIdProvider = Provider<Map<String, Track>>((ref) {
  final tracks = ref.watch(libraryTracksProvider).value ?? const [];
  return {for (final t in tracks) t.id: t};
});

/// Favourited track ids. Seeded from the loaded library's `favourite` column,
/// then updated optimistically on toggle so a heart tap doesn't refetch the
/// whole library. The server column is the store; a library reload reconciles.
final favouriteIdsProvider =
    NotifierProvider<FavouritesNotifier, Set<String>>(FavouritesNotifier.new);

class FavouritesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final tracks = ref.watch(libraryTracksProvider).value ?? const <Track>[];
    return {
      for (final t in tracks)
        if (t.favourite) t.id,
    };
  }

  Future<void> toggle(String trackId) async {
    final adding = !state.contains(trackId);
    state = _with(trackId, adding); // optimistic
    try {
      await ref.read(apiClientProvider).setFavourite(trackId, adding);
    } catch (_) {
      state = _with(trackId, !adding); // revert on failure
    }
  }

  Set<String> _with(String id, bool present) {
    final next = {...state};
    present ? next.add(id) : next.remove(id);
    return next;
  }
}

/// Canonical genre -> parent tree. Old/unreachable servers degrade to a flat
/// genre list, exactly like the legacy loadLibrary() catch.
final genreTreeProvider = FutureProvider<GenreTree>((ref) async {
  try {
    return await ref.watch(apiClientProvider).genres();
  } catch (e) {
    Log.w('library', 'genres load failed', e);
    return const GenreTree({});
  }
});

/// Person name -> photo URL (server enrichment cache). Errors degrade to an
/// empty map — portraits are progressive enhancement.
final peopleProvider = FutureProvider<Map<String, String>>((ref) async {
  try {
    return await ref.watch(apiClientProvider).people();
  } catch (e) {
    Log.w('library', 'people load failed', e);
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

/// App-lifetime `enrich`/`analyze` SSE watcher: when a server pass finishes
/// (busy -> idle) the library caches refresh, no matter which screen is
/// open — both are server-side work, the app just reacts to it.
/// Watched by TransportBar; the Settings poller only renders progress.
///
/// The three passes (enrich, fingerprint, analyze) are tracked separately
/// rather than through one shared `wasBusy`: the analyzer runs for hours after
/// enrichment has gone idle, and a single flag would read every interleaving as
/// a spurious transition and refresh the whole library on each one.
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
  final wasBusy = {'enrich': false, 'analyze': false, 'fingerprint': false};

  void seen(String src, bool busy) {
    if (wasBusy[src] != busy) Log.i(src, busy ? 'pass started' : 'pass finished');
    if (wasBusy[src]! && !busy) invalidateLibrary(ref);
    wasBusy[src] = busy;
  }

  Future<void> tick() async {
    try {
      // A pass may have ended while disconnected — one status probe on
      // (re)connect closes that gap before we trust the stream.
      final s = await client.enrichStatus();
      if (disposed) return;
      seen('enrich', s.phase != 'idle');
      await for (final e in client.events()) {
        if (disposed) return;
        if (e.event != 'enrich' &&
            e.event != 'analyze' &&
            e.event != 'fingerprint') {
          continue;
        }
        try {
          // All three statuses are deliberately the same {phase,running} shape.
          seen(e.event, enrichBusy(jsonDecode(e.data)));
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
