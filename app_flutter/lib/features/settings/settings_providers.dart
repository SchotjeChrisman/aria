import 'dart:async';
import 'dart:convert';

import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/library_providers.dart';
import '../../core/log.dart';

// The exclusive-access toggle lives in core so playerInitProvider can apply
// the persisted flag right after engine init (bit-perfect survives restarts).
export '../../core/player_providers.dart'
    show AudioExclusiveNotifier, audioExclusiveProvider;

// Data-usage settings live in core so playback (and later downloads) can
// gate on the network kind at play time.
export '../../core/data_usage.dart'
    show DataUsage, DataUsageNotifier, NetKind, dataUsageProvider,
        networkKindProvider;

// Downloads live in core so playback resolves local sources at play time.
export '../../core/downloads.dart'
    show DownloadEntry, DownloadsNotifier, DownloadsState, downloadsProvider;

/// Server-side settings (ListenBrainz token). Refresh after save.
final serverSettingsProvider = FutureProvider<Settings>(
  (ref) => ref.watch(apiClientProvider).settings(),
);

/// Enrichment progress, polled every 5s while watched (legacy watchEnrich).
/// Display only — the cache refresh when a pass finishes lives app-wide in
/// core's enrichRefreshProvider, not on this page.
final enrichStatusProvider = StreamProvider.autoDispose<EnrichStatus>((
  ref,
) async* {
  final client = ref.watch(apiClientProvider);
  // async* cancellation only lands at a yield; the flag stops the loop (and
  // guards ref use) when disposal happens mid-await.
  var disposed = false;
  ref.onDispose(() => disposed = true);
  while (!disposed) {
    try {
      final s = await client.enrichStatus();
      if (disposed) break;
      yield s;
    } catch (_) {
      // server away — keep polling quietly, legacy did the same
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

class ScanState {
  const ScanState({
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.lastTracks,
    this.error,
  });

  final bool running;
  final int done;
  final int total;

  /// Track count from the last completed scan; null before any scan.
  final int? lastTracks;
  final String? error;

  ScanState copyWith({
    bool? running,
    int? done,
    int? total,
    int? lastTracks,
    String? error,
  }) => ScanState(
    running: running ?? this.running,
    done: done ?? this.done,
    total: total ?? this.total,
    lastTracks: lastTracks ?? this.lastTracks,
    error: error,
  );
}

final scanControllerProvider = NotifierProvider<ScanController, ScanState>(
  ScanController.new,
);

/// Rescan with live progress: POST /api/scan resolves when the scan is done;
/// meanwhile `event: scan` SSE frames carry {scanning, done, total, tracks}.
class ScanController extends Notifier<ScanState> {
  StreamSubscription<AriaEvent>? _sub;

  @override
  ScanState build() {
    ref.onDispose(() => _sub?.cancel());
    return const ScanState();
  }

  Future<void> start() async {
    if (state.running) return;
    final client = ref.read(apiClientProvider);
    Log.i('scan', 'started');
    state = const ScanState(running: true);

    _sub = client.events().listen(
      (e) {
        if (e.event != 'scan') return;
        Object? j;
        try {
          j = jsonDecode(e.data);
        } on FormatException {
          return;
        }
        if (j is! Map) return;
        state = state.copyWith(
          done: (j['done'] as num?)?.toInt() ?? state.done,
          total: (j['total'] as num?)?.toInt() ?? state.total,
        );
      },
      onError: (_) {}, // progress is cosmetic; the POST is the source of truth
      cancelOnError: true,
    );

    try {
      final tracks = await client.scan();
      Log.i('scan', 'finished: $tracks tracks');
      state = ScanState(lastTracks: tracks);
      // New/changed files: refresh everything derived from the track list —
      // the core cache feeds library/album/artist/search/playlists/tags.
      invalidateLibrary(ref);
      ref.invalidate(serverStatusProvider);
    } catch (e) {
      Log.w('scan', 'failed', e);
      state = ScanState(error: e.toString());
    } finally {
      await _sub?.cancel();
      _sub = null;
    }
  }
}
