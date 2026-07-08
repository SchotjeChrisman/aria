import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection.dart';
import 'data_usage.dart';
import 'log.dart';

// Transcode quality tiers live in core alongside data_usage because playback
// (and downloads) pick a tier at play/fetch time; the Settings UI re-imports
// this per the core-vs-feature rule. Mirrors DataUsage/DataUsageNotifier
// verbatim (prefs-backed Notifier, try/catch → clean defaults on corrupt).

const _prefsKeyQuality = 'aria.quality';

/// Server-side transcode tier the app requests. [original] is the raw
/// byte-for-byte file (no `?tier` query — the historical bit-perfect path);
/// [high]/[low] are Opus VBR (~192k/~96k) served from the server's cache.
enum QualityTier {
  original('original', 'Original'),
  high('high', 'High (Opus ~192k)'),
  low('low', 'Low (Opus ~96k)');

  const QualityTier(this.wire, this.label);

  /// The `?tier=` query value the server understands. [original] is still
  /// carried on the wire; callers OMIT the param for it so caching/URLs are
  /// unchanged — see AriaClient.streamUrl/download.
  final String wire;

  /// Human-facing name for the Settings selectors.
  final String label;

  static QualityTier fromWire(String? w) =>
      values.firstWhere((t) => t.wire == w, orElse: () => QualityTier.original);

  /// Tier to actually request: falls back to [original] when the server can't
  /// transcode, so playback/downloads never hit the server's 501 for high/low
  /// (mirrors the disabled Settings selector). Leaves the persisted pref
  /// untouched, so it re-applies if a transcoding server later appears.
  QualityTier clamp(bool canTranscode) =>
      canTranscode ? this : QualityTier.original;
}

/// Per-network-kind streaming tier + the downloads tier (downloads use their
/// own tier, not the live network). Defaults: wifi=original, cellular=high,
/// download=original.
class QualityPrefs {
  const QualityPrefs({
    this.tierWifi = QualityTier.original,
    this.tierCellular = QualityTier.high,
    this.tierDownload = QualityTier.original,
  });

  factory QualityPrefs.fromJson(Map<String, dynamic> j) => QualityPrefs(
    tierWifi: QualityTier.fromWire(j['tierWifi'] as String?),
    tierCellular: QualityTier.fromWire(j['tierCellular'] as String?),
    tierDownload: QualityTier.fromWire(j['tierDownload'] as String?),
  );

  final QualityTier tierWifi;
  final QualityTier tierCellular;
  final QualityTier tierDownload;

  /// Streaming tier for the current network kind. offline/other fall back to
  /// [QualityTier.original] — no metered link to protect, play the real file.
  QualityTier streamTierFor(NetKind kind) => switch (kind) {
    NetKind.wifi => tierWifi,
    NetKind.cellular => tierCellular,
    _ => QualityTier.original,
  };

  QualityPrefs copyWith({
    QualityTier? tierWifi,
    QualityTier? tierCellular,
    QualityTier? tierDownload,
  }) => QualityPrefs(
    tierWifi: tierWifi ?? this.tierWifi,
    tierCellular: tierCellular ?? this.tierCellular,
    tierDownload: tierDownload ?? this.tierDownload,
  );

  Map<String, dynamic> toJson() => {
    'tierWifi': tierWifi.wire,
    'tierCellular': tierCellular.wire,
    'tierDownload': tierDownload.wire,
  };
}

final qualityProvider = NotifierProvider<QualityNotifier, QualityPrefs>(
  QualityNotifier.new,
);

class QualityNotifier extends Notifier<QualityPrefs> {
  @override
  QualityPrefs build() {
    final raw = ref.read(sharedPrefsProvider).getString(_prefsKeyQuality);
    if (raw == null) return const QualityPrefs();
    try {
      return QualityPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      Log.w('settings', 'corrupt quality prefs', e);
      return const QualityPrefs(); // corrupt entry — start clean
    }
  }

  Future<void> set(QualityPrefs v) async {
    Log.i('settings', 'quality', jsonEncode(v.toJson()));
    state = v;
    await ref
        .read(sharedPrefsProvider)
        .setString(_prefsKeyQuality, jsonEncode(v.toJson()));
  }
}

/// Whether the server can transcode (its /api/status `transcode` flag). The
/// Settings selectors hide high/low when false. Rides the existing status
/// ping — no extra request. Null (status not yet loaded / unreachable) reads
/// as "assume capable" so the selectors aren't disabled on a slow first load.
final transcodeAvailableProvider = Provider<bool>(
  (ref) => ref.watch(serverStatusProvider).value?.transcode ?? true,
);
