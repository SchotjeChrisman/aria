import '../json.dart';

/// A play reference: track id + when it was played.
class PlayRef {
  const PlayRef({required this.id, required this.at});

  final String id; // trackId
  final String at; // ISO timestamp

  factory PlayRef.fromJson(Map<String, dynamic> j) =>
      PlayRef(id: j['id'] as String, at: j['at'] as String);
}

class TopTrack {
  const TopTrack({required this.id, required this.count, this.lastAt});

  final String id;
  final int count;
  final String? lastAt;

  factory TopTrack.fromJson(Map<String, dynamic> j) => TopTrack(
        id: j['id'] as String,
        count: asInt(j['count']) ?? 0,
        lastAt: asString(j['lastAt']),
      );
}

class TopAlbum {
  const TopAlbum({required this.albumId, required this.count});

  final String albumId;
  final int count;

  factory TopAlbum.fromJson(Map<String, dynamic> j) =>
      TopAlbum(albumId: j['albumId'] as String, count: asInt(j['count']) ?? 0);
}

class TopArtist {
  const TopArtist({required this.name, required this.count});

  final String name;
  final int count;

  factory TopArtist.fromJson(Map<String, dynamic> j) =>
      TopArtist(name: j['name'] as String, count: asInt(j['count']) ?? 0);
}

/// Rolling 7-day window.
class WeekStats {
  const WeekStats({required this.plays, required this.seconds});

  final int plays;
  final int seconds;

  factory WeekStats.fromJson(Map<String, dynamic> j) => WeekStats(
        plays: asInt(j['plays']) ?? 0,
        seconds: asInt(j['seconds']) ?? 0,
      );
}

/// Rolling 30-day window.
class MonthStats {
  const MonthStats(
      {required this.plays, required this.seconds, this.topArtist});

  final int plays;
  final int seconds;
  final TopArtist? topArtist;

  factory MonthStats.fromJson(Map<String, dynamic> j) => MonthStats(
        plays: asInt(j['plays']) ?? 0,
        seconds: asInt(j['seconds']) ?? 0,
        topArtist: j['topArtist'] is Map<String, dynamic>
            ? TopArtist.fromJson(j['topArtist'] as Map<String, dynamic>)
            : null,
      );
}

/// `/api/stats` response, optionally scoped to a profile.
class Stats {
  const Stats({
    this.profileId,
    required this.totalPlays,
    required this.totalSeconds,
    required this.uniqueTracks,
    required this.week,
    required this.month,
    this.history = const [],
    this.topTracks = const [],
    this.topAlbums = const [],
    this.topArtists = const [],
    this.recent = const [],
    this.playCounts,
  });

  final String? profileId;
  final int totalPlays;
  final int totalSeconds;
  final int uniqueTracks;
  final WeekStats week;
  final MonthStats month;
  final List<PlayRef> history; // raw 30-day plays for client-side charts
  final List<TopTrack> topTracks;
  final List<TopAlbum> topAlbums;
  final List<TopArtist> topArtists;
  final List<PlayRef> recent;
  final Map<String, int>? playCounts; // only when requested with counts=1

  factory Stats.fromJson(Map<String, dynamic> j) {
    List<T> list<T>(Object? v, T Function(Map<String, dynamic>) f) =>
        v is List ? v.whereType<Map<String, dynamic>>().map(f).toList() : [];
    return Stats(
      profileId: asString(j['profileId']),
      totalPlays: asInt(j['totalPlays']) ?? 0,
      totalSeconds: asInt(j['totalSeconds']) ?? 0,
      uniqueTracks: asInt(j['uniqueTracks']) ?? 0,
      week: WeekStats.fromJson(asMap(j['week'])),
      month: MonthStats.fromJson(asMap(j['month'])),
      history: list(j['history'], PlayRef.fromJson),
      topTracks: list(j['topTracks'], TopTrack.fromJson),
      topAlbums: list(j['topAlbums'], TopAlbum.fromJson),
      topArtists: list(j['topArtists'], TopArtist.fromJson),
      recent: list(j['recent'], PlayRef.fromJson),
      playCounts: j['playCounts'] is Map<String, dynamic>
          ? (j['playCounts'] as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, asInt(v) ?? 0))
          : null,
    );
  }
}
