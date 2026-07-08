import 'dart:convert';

import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connection.dart';
import 'log.dart';

const _prefsKeyPendingPlays = 'aria.pendingPlays';

/// Server timestamp format (JS toISOString, millisecond precision) — the
/// plays table compares these lexicographically, so the layout is exact.
String isoTimestamp(DateTime t) {
  final u = t.toUtc();
  String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
  return '${p(u.year, 4)}-${p(u.month)}-${p(u.day)}'
      'T${p(u.hour)}:${p(u.minute)}:${p(u.second)}.${p(u.millisecond, 3)}Z';
}

/// Offline play buffer: recordPlay failures land here and flush whenever the
/// server is reachable again (piggybacked on the log-sync tick). The user
/// tracks 20k+ plays/year — offline listening must not lose them.
final pendingPlaysProvider = Provider<PendingPlays>(
  (ref) => PendingPlays(
    prefs: ref.read(sharedPrefsProvider),
    send: (trackId, profileId, at) => ref
        .read(apiClientProvider)
        .recordPlay(trackId: trackId, profileId: profileId, at: at),
  ),
);

class PendingPlays {
  PendingPlays({required this.prefs, required this.send});

  /// Newest entries win when full — losing week-old queued plays beats
  /// losing today's.
  static const cap = 5000;

  final SharedPreferences prefs;

  /// Throws AriaApiException on failure (statusCode 0 = unreachable).
  final Future<void> Function(String trackId, String profileId, String? at)
  send;

  bool _busy = false;

  List<Map<String, dynamic>> get entries {
    final raw = prefs.getString(_prefsKeyPendingPlays);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {
      return []; // corrupt — the queued plays are lost, start clean
    }
  }

  void _save(List<Map<String, dynamic>> list) {
    prefs.setString(_prefsKeyPendingPlays, jsonEncode(list));
  }

  void add({
    required String trackId,
    required String profileId,
    required String at,
  }) {
    final list = entries
      ..add({'trackId': trackId, 'profileId': profileId, 'at': at});
    if (list.length > cap) list.removeRange(0, list.length - cap);
    _save(list);
    Log.i('plays', 'queued offline play (${list.length} pending)', trackId);
  }

  /// Replay queued plays oldest-first. An unreachable server (statusCode 0)
  /// or a transient server failure (5xx) stops the pass — retry next tick;
  /// only a 4xx rejection (e.g. its profile was deleted) drops the entry so
  /// one bad play can't wedge the queue forever. Returns true if anything
  /// was sent, so the caller can refresh play-derived providers.
  Future<bool> flush() async {
    if (_busy) return false;
    _busy = true;
    var sent = false;
    try {
      while (true) {
        final list = entries; // re-read: plays queued mid-flush must survive
        if (list.isEmpty) return sent;
        final p = list.first;
        final trackId = p['trackId'] as String?;
        final profileId = p['profileId'] as String?;
        if (trackId != null && profileId != null) {
          try {
            await send(trackId, profileId, p['at'] as String?);
            Log.i('plays', 'flushed offline play', trackId);
            sent = true;
          } on AriaApiException catch (e) {
            if (e.statusCode == 0 || e.statusCode >= 500) return sent;
            Log.w('plays', 'dropping rejected offline play', e);
          }
        }
        _save(entries..removeAt(0));
      }
    } catch (_) {
      // anything unexpected — quiet retry next tick
      return sent;
    } finally {
      _busy = false;
    }
  }
}
