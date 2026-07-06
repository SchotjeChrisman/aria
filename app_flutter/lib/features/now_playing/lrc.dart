/// LRC parsing + sync helpers, ported 1:1 from legacy app.js
/// (parseLrc / syncLyrics index math).
library;

class LrcLine {
  const LrcLine(this.t, this.text);

  /// Seconds from track start.
  final double t;
  final String text;
}

/// Legacy parseLrc: only `[m:ss.xx]` lines count; null when nothing matched
/// (caller falls back to plain lyrics).
List<LrcLine>? parseLrc(String text) {
  final re = RegExp(r'^\[(\d+):(\d+(?:\.\d+)?)\](.*)');
  final lines = <LrcLine>[];
  for (final raw in text.split('\n')) {
    final m = re.firstMatch(raw);
    if (m != null) {
      lines.add(
        LrcLine(
          double.parse(m.group(1)!) * 60 + double.parse(m.group(2)!),
          m.group(3)!.trim(),
        ),
      );
    }
  }
  return lines.isEmpty ? null : lines;
}

/// Legacy syncLyrics index: last line whose timestamp has passed;
/// -1 before the first line, last index past the final timestamp.
int currentLrcIndex(List<LrcLine> lines, double position) {
  var i = lines.indexWhere((l) => l.t > position) - 1;
  if (i < -1) i = lines.length - 1;
  return i;
}

/// Parsed `/api/lyrics/:id` payload: synced lines when the LRC parsed,
/// otherwise plain text.
class LoadedLyrics {
  const LoadedLyrics({this.lines, this.plain});

  final List<LrcLine>? lines;
  final String? plain;

  bool get isEmpty => lines == null && (plain == null || plain!.isEmpty);
}
