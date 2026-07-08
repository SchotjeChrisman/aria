import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/artist/providers.dart' show artistStatsProvider;
import '../features/home/home_providers.dart' show homeStatsProvider;
import '../features/library/library_providers.dart' show playCountsProvider;
import '../features/stats/stats_providers.dart' show statsProvider;
import 'connection.dart';
import 'log.dart';
import 'pending_plays.dart';

const _prefsKeyCursor = 'aria.logCursor';

/// App-lifetime log uploader (kept alive by TransportBar, like
/// enrichRefreshProvider): drains new NDJSON lines to POST /api/logs every
/// 5 minutes and whenever a server status probe succeeds. Plays queued while
/// offline piggyback on the same tick — one reachability heartbeat.
final logSyncProvider = Provider<LogSync>((ref) {
  final sync = LogSync(
    prefs: ref.read(sharedPrefsProvider),
    file: () {
      final p = Log.filePath;
      return p == null ? null : File(p);
    },
    beforeRead: Log.flush,
    upload: (entries) =>
        ref.read(apiClientProvider).uploadLogs(Log.device, entries),
  );
  void tick() {
    sync.syncNow();
    ref.read(pendingPlaysProvider).flush().then((sent) {
      if (!sent) return;
      // Flushed plays are in the DB now — refetch everything that renders
      // play data (mirrors playReporter's success branch).
      ref.invalidate(statsProvider);
      ref.invalidate(homeStatsProvider);
      ref.invalidate(artistStatsProvider);
      ref.invalidate(playCountsProvider);
    });
  }

  final timer = Timer.periodic(const Duration(minutes: 5), (_) => tick());
  ref.onDispose(timer.cancel);
  // A successful status ping means the server is reachable — drain now.
  ref.listen(serverStatusProvider, (_, next) {
    if (next.hasValue) tick();
  });
  tick();
  return sync;
});

/// Reads NDJSON lines past a persisted byte cursor and uploads them in
/// batches, advancing the cursor only after a 2xx. Failures (offline
/// statusCode 0, 404 from an old server, anything else) are quiet retries —
/// they must never be written to the log file or syncing would generate the
/// very lines it fails to upload, forever.
class LogSync {
  LogSync({
    required this.prefs,
    required this.file,
    required this.upload,
    this.beforeRead,
  });

  final SharedPreferences prefs;

  /// Current log file; null when logging to disk is not initialized.
  final File? Function() file;

  /// Throws on any non-2xx / no-response.
  final Future<void> Function(List<Map<String, dynamic>> entries) upload;

  /// Awaited before reading (drains the logger's write queue).
  final Future<void> Function()? beforeRead;

  static const maxBatchEntries = 500;
  static const maxBatchBytes = 512 * 1024;

  bool _busy = false;

  Future<void> syncNow() async {
    if (_busy) return;
    _busy = true;
    try {
      await beforeRead?.call();
      await _drain();
    } catch (_) {
      // Server unreachable or too old — memory-only quiet retry next tick.
    } finally {
      _busy = false;
    }
  }

  Future<void> _drain() async {
    final f = file();
    if (f == null || !await f.exists()) return;
    var (offset, fingerprint, savedHead) = _cursor();
    final len = await f.length();
    final head = await _readHead(f, len);
    // File shrank vs the fingerprint (rotation) or cursor ran past the end
    // (truncation): start over from the top of the new file. The length
    // checks miss a rotated file that already grew past the old length, so
    // also fingerprint the first bytes — each line starts with a unique
    // '{"ts":"<iso>"' so the head identifies the file generation. A cursor
    // saved before heads existed is match-unknown: reset once (re-upload
    // from the top is harmless) and the head is saved from then on.
    if (len < fingerprint || offset > len || !_headMatches(savedHead, head)) {
      offset = 0;
    }
    while (offset < len) {
      final (:entries, :consumed) = await _readBatch(f, offset, len);
      if (consumed == 0) break; // partial trailing line — next tick
      if (entries.isNotEmpty) await upload(entries); // throws on failure
      offset += consumed;
      _save(offset, len, head);
    }
  }

  (int, int, String?) _cursor() {
    final raw = prefs.getString(_prefsKeyCursor);
    if (raw == null) return (0, 0, null);
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (
        (j['offset'] as num).toInt(),
        (j['len'] as num).toInt(),
        j['head'] as String?,
      );
    } catch (_) {
      return (0, 0, null); // corrupt cursor — re-upload from the top
    }
  }

  void _save(int offset, int len, String head) {
    prefs.setString(
      _prefsKeyCursor,
      jsonEncode({'offset': offset, 'len': len, 'head': head}),
    );
  }

  /// Base64 of the first min(64, len) bytes — the file-generation fingerprint.
  Future<String> _readHead(File f, int len) async {
    if (len == 0) return '';
    final raf = await f.open();
    try {
      return base64Encode(await raf.read(min(64, len)));
    } finally {
      await raf.close();
    }
  }

  /// Prefix comparison, not equality: a head captured while the file was
  /// still shorter than 64 bytes must keep matching after the file grows.
  bool _headMatches(String? saved, String current) {
    if (saved == null) return false; // pre-head cursor — unknown, reset once
    try {
      final a = base64Decode(saved);
      final b = base64Decode(current);
      final n = min(a.length, b.length);
      for (var i = 0; i < n; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// One batch of complete lines starting at [offset]: up to
  /// [maxBatchEntries] parsed entries, and the byte count they (plus any
  /// skipped blank/corrupt lines) consumed.
  Future<({List<Map<String, dynamic>> entries, int consumed})> _readBatch(
    File f,
    int offset,
    int len,
  ) async {
    final raf = await f.open();
    try {
      await raf.setPosition(offset);
      final chunk = await raf.read(min(maxBatchBytes, len - offset));
      var consumed = 0;
      var lineStart = 0;
      final entries = <Map<String, dynamic>>[];
      for (
        var i = 0;
        i < chunk.length && entries.length < maxBatchEntries;
        i++
      ) {
        if (chunk[i] != 0x0a) continue;
        final lineBytes = chunk.sublist(lineStart, i);
        consumed = i + 1;
        lineStart = i + 1;
        if (lineBytes.isEmpty) continue;
        try {
          final j = jsonDecode(utf8.decode(lineBytes));
          if (j is Map<String, dynamic>) entries.add(j);
        } catch (_) {
          // torn/corrupt line — skip it rather than wedge the cursor
        }
      }
      return (entries: entries, consumed: consumed);
    } finally {
      await raf.close();
    }
  }
}
