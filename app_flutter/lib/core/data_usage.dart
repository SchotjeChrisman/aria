import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection.dart';
import 'log.dart';

// Data-usage gating lives in core because playback (and later downloads)
// consult it at play time; the Settings UI re-imports it via
// settings_providers.dart per the core-vs-feature rule.

const _prefsKeyDataUsage = 'aria.dataUsage';

/// Network class for metered-data gating. Ethernet counts as wifi
/// (unmetered); [offline]/[other] never block anything — gating only
/// protects metered data, a doomed request fails on its own.
enum NetKind { wifi, cellular, offline, other }

/// Map a connectivity_plus report to a [NetKind]. Anything ambiguous
/// (vpn/bluetooth/other) defaults to wifi on non-Android desktop — there is
/// no metered interface to protect there.
NetKind netKindOf(List<ConnectivityResult> results) {
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return NetKind.wifi;
  }
  if (results.contains(ConnectivityResult.mobile)) return NetKind.cellular;
  if (results.isEmpty || results.contains(ConnectivityResult.none)) {
    return NetKind.offline;
  }
  return Platform.isAndroid ? NetKind.other : NetKind.wifi;
}

/// Live network kind: an initial check, then connectivity change events.
/// No value yet (startup race or a dead plugin) reads as null — the gates
/// treat that like [NetKind.other] and allow the attempt.
final networkKindProvider = StreamProvider<NetKind>((ref) async* {
  final connectivity = Connectivity();
  try {
    var kind = netKindOf(await connectivity.checkConnectivity());
    Log.i('net', 'network ${kind.name}');
    yield kind;
    await for (final results in connectivity.onConnectivityChanged) {
      final next = netKindOf(results);
      if (next == kind) continue; // the plugin repeats itself; log transitions
      kind = next;
      Log.i('net', 'network ${kind.name}');
      yield kind;
    }
  } catch (e) {
    // Plugin unavailable (tests, exotic platforms) — stay valueless forever
    // rather than leak an async error nobody can catch.
    Log.w('net', 'connectivity unavailable', e);
  }
});

/// Which network kinds may carry streaming/download traffic.
class DataUsage {
  const DataUsage({
    this.streamOnWifi = true,
    this.downloadOnWifi = true,
    this.streamOnCellular = true,
    this.downloadOnCellular = false,
  });

  factory DataUsage.fromJson(Map<String, dynamic> j) => DataUsage(
    streamOnWifi: j['streamOnWifi'] != false,
    downloadOnWifi: j['downloadOnWifi'] != false,
    streamOnCellular: j['streamOnCellular'] != false,
    downloadOnCellular: j['downloadOnCellular'] == true,
  );

  final bool streamOnWifi;
  final bool downloadOnWifi;
  final bool streamOnCellular;
  final bool downloadOnCellular;

  bool allowsStream(NetKind kind) => switch (kind) {
    NetKind.wifi => streamOnWifi,
    NetKind.cellular => streamOnCellular,
    _ => true,
  };

  bool allowsDownload(NetKind kind) => switch (kind) {
    NetKind.wifi => downloadOnWifi,
    NetKind.cellular => downloadOnCellular,
    _ => true,
  };

  DataUsage copyWith({
    bool? streamOnWifi,
    bool? downloadOnWifi,
    bool? streamOnCellular,
    bool? downloadOnCellular,
  }) => DataUsage(
    streamOnWifi: streamOnWifi ?? this.streamOnWifi,
    downloadOnWifi: downloadOnWifi ?? this.downloadOnWifi,
    streamOnCellular: streamOnCellular ?? this.streamOnCellular,
    downloadOnCellular: downloadOnCellular ?? this.downloadOnCellular,
  );

  Map<String, dynamic> toJson() => {
    'streamOnWifi': streamOnWifi,
    'downloadOnWifi': downloadOnWifi,
    'streamOnCellular': streamOnCellular,
    'downloadOnCellular': downloadOnCellular,
  };
}

final dataUsageProvider = NotifierProvider<DataUsageNotifier, DataUsage>(
  DataUsageNotifier.new,
);

class DataUsageNotifier extends Notifier<DataUsage> {
  @override
  DataUsage build() {
    final raw = ref.read(sharedPrefsProvider).getString(_prefsKeyDataUsage);
    if (raw == null) return const DataUsage();
    try {
      return DataUsage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      Log.w('settings', 'corrupt data-usage prefs', e);
      return const DataUsage(); // corrupt entry — start clean
    }
  }

  Future<void> set(DataUsage v) async {
    Log.i('settings', 'data usage', jsonEncode(v.toJson()));
    state = v;
    await ref
        .read(sharedPrefsProvider)
        .setString(_prefsKeyDataUsage, jsonEncode(v.toJson()));
  }
}
