/// Pure formatting helpers ported 1:1 from the legacy app (app/ui/app.js).
library;

/// Legacy fmtTime: "3:07". Negative / non-finite clamps to 0:00.
String formatDuration(num? seconds) {
  var s = (seconds ?? 0).toDouble();
  if (!s.isFinite || s < 0) s = 0;
  final m = s ~/ 60;
  final r = (s % 60).floor();
  return '$m:${r.toString().padLeft(2, '0')}';
}

/// Legacy fmtHm, listening-time style: "3h 42m", minutes only under an hour.
String formatListenTime(num? seconds) {
  var s = (seconds ?? 0).toDouble();
  if (!s.isFinite || s < 0) s = 0;
  final h = s ~/ 3600;
  final mn = (s % 3600) ~/ 60;
  return h > 0 ? '${h}h ${mn}m' : '${mn}m';
}

/// Legacy initials(): first letter of up to two words, uppercased.
/// "Miles Davis" -> "MD", "Radiohead" -> "R", empty -> "?".
String initials(String? name) {
  final n = (name == null || name.trim().isEmpty) ? '?' : name.trim();
  return n
      .split(RegExp(r'\s+'))
      .take(2)
      .map((w) => w.isEmpty ? '' : w[0])
      .join()
      .toUpperCase();
}

/// Legacy fmtBadge(): "FLAC 24/96", "FLAC 16/44.1", "MP3".
/// Rate is kHz with a trailing ".0" stripped, matching the JS output exactly.
String formatBadgeText({String? format, int? bitsPerSample, int? sampleRate}) {
  var b = (format ?? '').toUpperCase();
  if (bitsPerSample != null &&
      bitsPerSample > 0 &&
      sampleRate != null &&
      sampleRate > 0) {
    final k = (sampleRate / 1000).toString().replaceFirst(RegExp(r'\.0$'), '');
    b += ' $bitsPerSample/$k';
  }
  return b;
}

/// Hi-res per the usual definition: beyond CD bit depth or beyond 48 kHz.
bool isHiRes({int? bitsPerSample, int? sampleRate}) =>
    (bitsPerSample ?? 0) > 16 || (sampleRate ?? 0) > 48000;

/// "512 B", "3.4 MB", "1.2 GB" — download sizes, decimal units.
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['kB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = -1;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[u]}';
}
