import '../json.dart';

/// `/api/library/health` — what the identification and analysis passes could
/// not settle. Everything here is read-only diagnostics; nothing the app can
/// do from this page writes to a file.
class LibraryHealth {
  const LibraryHealth({required this.counts, required this.issues});

  /// tracks / albums / analysed / fingerprinted / identified. Read by key so a
  /// server that adds a counter does not need an app release.
  final Map<String, int> counts;
  final List<HealthIssue> issues;

  int count(String key) => counts[key] ?? 0;

  /// True when nothing is wrong — every issue section is empty.
  bool get clean => issues.every((i) => i.count == 0);

  factory LibraryHealth.fromJson(Map<String, dynamic> j) => LibraryHealth(
        counts: {
          for (final e in asMap(j['counts']).entries)
            if (asInt(e.value) case final n?) e.key: n,
        },
        issues: [
          for (final i in (j['issues'] as List? ?? const []))
            HealthIssue.fromJson(asMap(i)),
        ],
      );
}

class HealthIssue {
  const HealthIssue({
    required this.kind,
    required this.count,
    required this.items,
  });

  /// unmatched | lowSeparation | missingArt | missingMbid | suspect |
  /// clipping | unanalysed. Unknown kinds are kept and shown under their raw
  /// name rather than dropped.
  final String kind;

  /// The true total. [items] is capped at 100 by the server, so this may be
  /// larger than items.length.
  final int count;
  final List<HealthItem> items;

  factory HealthIssue.fromJson(Map<String, dynamic> j) => HealthIssue(
        kind: asString(j['kind']) ?? '',
        count: asInt(j['count']) ?? 0,
        items: [
          for (final i in (j['items'] as List? ?? const []))
            HealthItem.fromJson(asMap(i)),
        ],
      );
}

class HealthItem {
  const HealthItem({
    required this.albumId,
    required this.title,
    this.trackId,
    this.subtitle = '',
    this.detail = '',
  });

  final String albumId;

  /// Set on track-level issues only; album issues carry just [albumId].
  final String? trackId;
  final String title;
  final String subtitle;
  final String detail;

  factory HealthItem.fromJson(Map<String, dynamic> j) => HealthItem(
        albumId: asString(j['albumId']) ?? '',
        trackId: asString(j['trackId']),
        title: asString(j['title']) ?? '',
        subtitle: asString(j['subtitle']) ?? '',
        detail: asString(j['detail']) ?? '',
      );
}

/// `/api/library/duplicates` — one set of tracks the library holds twice.
class DuplicateGroup {
  const DuplicateGroup({
    required this.key,
    required this.exact,
    required this.tracks,
  });

  final String key;

  /// True when the decoded audio is byte-identical; false when only AcoustID
  /// says these are the same recording (a re-encode, or the same track on a
  /// compilation — which may be entirely wanted).
  final bool exact;
  final List<DuplicateTrack> tracks;

  factory DuplicateGroup.fromJson(Map<String, dynamic> j) => DuplicateGroup(
        key: asString(j['key']) ?? '',
        exact: asBool(j['exact']),
        tracks: [
          for (final t in (j['tracks'] as List? ?? const []))
            DuplicateTrack.fromJson(asMap(t)),
        ],
      );
}

class DuplicateTrack {
  const DuplicateTrack({
    required this.id,
    required this.albumId,
    required this.title,
    required this.artist,
    required this.album,
    required this.format,
    required this.lossless,
    this.duration,
    this.sampleRate,
    this.bitsPerSample,
  });

  final String id;
  final String albumId;
  final String title;
  final String artist;
  final String album;
  final String format;
  final bool lossless;
  final double? duration;
  final int? sampleRate;
  final int? bitsPerSample;

  factory DuplicateTrack.fromJson(Map<String, dynamic> j) => DuplicateTrack(
        id: asString(j['id']) ?? '',
        albumId: asString(j['albumId']) ?? '',
        title: asString(j['title']) ?? '',
        artist: asString(j['artist']) ?? '',
        album: asString(j['album']) ?? '',
        format: asString(j['format']) ?? '',
        lossless: asBool(j['lossless']),
        duration: asDouble(j['duration']),
        sampleRate: asInt(j['sampleRate']),
        bitsPerSample: asInt(j['bitsPerSample']),
      );
}
