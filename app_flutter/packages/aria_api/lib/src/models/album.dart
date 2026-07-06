import 'track.dart';

/// Albums are never sent by the server — they are derived client-side by
/// grouping `/api/tracks` on `albumId`, exactly like the legacy app:
/// title/albumArtist/year come from the first track seen for the album
/// (empty strings treated as missing), tracks sorted by (discNo||1, trackNo||0).
class Album {
  Album({
    required this.id,
    required this.title,
    required this.albumArtist,
    this.year,
    required this.tracks,
  });

  final String id; // albumId (sha1)
  final String title;
  final String albumArtist;
  final int? year;
  final List<Track> tracks;

  bool get hasArt => tracks.isNotEmpty && tracks.first.hasArt;
  String? get releaseType =>
      tracks.isNotEmpty ? tracks.first.releaseType : null;
  double get duration => tracks.fold(0.0, (s, t) => s + (t.duration ?? 0));
  bool get lossless => tracks.isNotEmpty && tracks.every((t) => t.lossless);

  static String _or(String? v, String fallback) =>
      (v == null || v.isEmpty) ? fallback : v;

  /// Group tracks into albums, preserving first-seen order.
  static List<Album> group(List<Track> tracks) {
    final byId = <String, Album>{};
    for (final t in tracks) {
      final a = byId.putIfAbsent(
        t.albumId,
        () => Album(
          id: t.albumId,
          title: _or(t.album, 'Unknown Album'),
          albumArtist: _or(t.albumArtist, _or(t.artist, 'Unknown Artist')),
          year: t.year,
          tracks: [],
        ),
      );
      a.tracks.add(t);
    }
    for (final a in byId.values) {
      a.tracks.sort((x, y) {
        final d = (x.discNo ?? 1) - (y.discNo ?? 1);
        if (d != 0) return d;
        return (x.trackNo ?? 0) - (y.trackNo ?? 0);
      });
    }
    return byId.values.toList();
  }
}
