import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ponytail: kept in sync with pubspec.yaml by hand — package_info_plus would
/// read it at runtime but isn't worth a dependency for one string.
const appVersion = '2.6.0';

const _prefsKeyDeviceId = 'aria.deviceId';

class LogEntry {
  const LogEntry({
    required this.ts,
    required this.level,
    required this.tag,
    required this.msg,
    this.extra,
  });

  final String ts;

  /// debug | info | warn | error.
  final String level;
  final String tag;
  final String msg;
  final String? extra;

  Map<String, dynamic> toJson() => {
    'ts': ts,
    'level': level,
    'tag': tag,
    'msg': msg,
    if (extra != null) 'extra': extra,
  };
}

/// Hand-rolled app logger: an in-memory ring buffer (debug screen) plus an
/// NDJSON file that log_sync uploads to the server. Callers never block —
/// file appends run on a serialized async queue. Before [init] (or when it
/// was never called, e.g. widget tests) entries reach the ring buffer only.
///
/// Never log tokens or PII; track titles are fine, the ListenBrainz token
/// is not.
abstract final class Log {
  static const _ringMax = 500;
  static final ListQueue<LogEntry> _ring = ListQueue();

  /// Bumped on every entry so the logs screen can rebuild cheaply.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  /// Ring-buffer snapshot, oldest first.
  static List<LogEntry> get entries => List.unmodifiable(_ring);

  /// Platform-labelled persistent device id, e.g. "linux-a1b2c3".
  static String device = 'unknown';

  static Directory? _dir;
  static File? _file;
  static int _maxBytes = 2 << 20;
  static int _length = 0;
  static Future<void> _queue = Future.value();

  /// Path of the live NDJSON file; null before [init].
  static String? get filePath => _file?.path;

  /// Called from main() before runApp with the app-support logs directory.
  static Future<void> init(
    Directory dir, {
    required SharedPreferences prefs,
    int maxBytes = 2 << 20,
  }) async {
    await dir.create(recursive: true);
    final f = File('${dir.path}/aria.ndjson');
    _length = await f.exists() ? await f.length() : 0;
    _dir = dir;
    _maxBytes = maxBytes;
    _file = f;
    device = _deviceId(prefs);
  }

  static String _deviceId(SharedPreferences prefs) {
    var id = prefs.getString(_prefsKeyDeviceId);
    if (id == null) {
      id = Random().nextInt(0xffffff).toRadixString(16).padLeft(6, '0');
      prefs.setString(_prefsKeyDeviceId, id);
    }
    return '${Platform.operatingSystem}-$id';
  }

  static void d(String tag, String msg, [Object? extra]) =>
      _add('debug', tag, msg, extra);
  static void i(String tag, String msg, [Object? extra]) =>
      _add('info', tag, msg, extra);
  static void w(String tag, String msg, [Object? extra]) =>
      _add('warn', tag, msg, extra);
  static void e(String tag, String msg, [Object? extra]) =>
      _add('error', tag, msg, extra);

  static void _add(String level, String tag, String msg, Object? extra) {
    final entry = LogEntry(
      ts: DateTime.now().toUtc().toIso8601String(),
      level: level,
      tag: tag,
      msg: msg,
      extra: extra?.toString(),
    );
    _ring.addLast(entry);
    if (_ring.length > _ringMax) _ring.removeFirst();
    revision.value++;
    if (_file == null) return;
    final line = '${jsonEncode(entry.toJson())}\n';
    // Serialized append; a failed write is dropped — logging must never throw
    // at call sites.
    _queue = _queue.then((_) => _write(line)).catchError((_) {});
  }

  static Future<void> _write(String line) async {
    final bytes = utf8.encode(line);
    if (_length + bytes.length > _maxBytes) {
      // ponytail: rotation drops any not-yet-uploaded lines in the old file
      // from sync (the cursor resets) — acceptable for a 2MB debug log.
      await _file!.rename('${_dir!.path}/aria.1.ndjson');
      _file = File('${_dir!.path}/aria.ndjson');
      _length = 0;
    }
    await _file!.writeAsBytes(bytes, mode: FileMode.append);
    _length += bytes.length;
  }

  /// Completes when all queued file writes have landed (sync, tests).
  static Future<void> flush() => _queue;

  @visibleForTesting
  static void reset() {
    _ring.clear();
    revision.value = 0;
    _dir = null;
    _file = null;
    _maxBytes = 2 << 20;
    _length = 0;
    _queue = Future.value();
    device = 'unknown';
  }
}
