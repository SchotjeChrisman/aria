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

/// The library generation carried by a `library` SSE frame, or null when the
/// frame is not one (malformed, or a differently shaped event). Type-tested
/// rather than cast: a bad `gen` must yield null, not throw out of the stream
/// loop and drop the app into its reconnect delay.
int? libraryGen(Object? frameJson) {
  final gen = frameJson is Map ? frameJson['gen'] : null;
  return gen is num ? gen.toInt() : null;
}

/// App-lifetime `library` SSE watcher: the app holds a whole-library cache, the
/// SERVER is where that library actually changes — a scan on its own schedule
/// (SCAN_INTERVAL, hourly by default), an enrichment pass, an edit made from
/// any device — so the server announces a generation and every connected app
/// refreshes off it. Nothing about keeping a device current is that device's
/// job; without this, each one sat on its stale copy until someone walked over
/// and pressed Rescan on it.
///
/// A GENERATION, not a "something changed" ping, because the hub drops frames
/// for slow subscribers and an app that is asleep or offline receives none at
/// all. The stream opens with the current generation, so a phone that dozed
/// through the 04:00 scan compares on reconnect and refetches then. A ping
/// would simply have been lost with the frame that carried it.
///
/// Watched by TransportBar; the Settings poller only renders pass progress.
const _coalesceWindow = Duration(seconds: 1);

final enrichRefreshProvider = Provider<void>((ref) {
  final client = ref.watch(apiClientProvider);
  var disposed = false;
  // The reconnect delay must be a cancellable Timer, not Future.delayed —
  // dispose (server-URL change, test teardown) has to stop it immediately.
  Timer? retry;
  // Coalesces a burst into one refetch. Generations rise per mutation, and
  // plenty of things move several in a row — tagging 20 tracks is 20 sequential
  // writes, one manual rescan is the scan plus the enrich and analyse passes
  // behind it. Refetching the whole library on each would be absurd; waiting a
  // beat for the burst to settle costs nothing anyone can perceive.
  Timer? coalesce;
  ref.onDispose(() {
    disposed = true;
    retry?.cancel();
    coalesce?.cancel();
  });
  // Outlives one connection on purpose: comparing across a reconnect is the
  // whole point. Null until the first frame — the startup fetch is already
  // current, so the opening generation is recorded, not acted on.
  int? seenGen;

  Future<void> tick() async {
    try {
      await for (final e in client.events()) {
        if (disposed) return;
        if (e.event != 'library') continue; // scan/enrich progress: cosmetic
        int? gen;
        try {
          gen = libraryGen(jsonDecode(e.data));
        } on FormatException {
          continue; // malformed frame — the next one corrects us
        }
        if (gen == null) continue;
        if (seenGen != null && gen != seenGen) {
          Log.i('library', 'server generation $seenGen -> $gen');
          coalesce?.cancel();
          coalesce = Timer(_coalesceWindow, () {
            if (disposed) return;
            invalidateLibrary(ref);
          });
        }
        seenGen = gen;
      }
    } catch (_) {
      // server away — quiet retry, same cadence as the settings poller
    }
    if (!disposed) retry = Timer(const Duration(seconds: 5), tick);
  }

  tick();
});
