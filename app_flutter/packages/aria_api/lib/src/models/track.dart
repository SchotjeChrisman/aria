import '../json.dart';

/// A per-track credited performer (from MusicBrainz enrichment).
class Performer {
  const Performer({required this.name, this.role});

  final String name;
  final String? role;

  factory Performer.fromJson(Map<String, dynamic> j) =>
      Performer(name: asString(j['name']) ?? '', role: asString(j['role']));

  Map<String, dynamic> toJson() =>
      {'name': name, if (role != null) 'role': role};
}

/// One entry of the `/api/tracks` response: file tags merged with enrichment
/// corrections and DB edits, plus server-derived `releaseType`, canonical
/// `genres`, and user `tags`.
class Track {
  const Track({
    required this.id,
    required this.albumId,
    this.addedAt,
    this.title,
    this.artist,
    this.albumArtist,
    this.album,
    this.year,
    this.genre,
    this.trackNo,
    this.discNo,
    this.duration,
    this.format,
    this.sampleRate,
    this.bitsPerSample,
    this.channels,
    this.lossless = false,
    this.hasArt = false,
    this.composer,
    this.conductor,
    this.orchestra,
    this.work,
    this.movement,
    this.mbAlbumId,
    this.mbRecordingId,
    this.mbAlbumArtistId,
    this.releaseType,
    this.genres = const [],
    this.tags = const [],
    this.performers = const [],
  });

  final String id;
  final String albumId;
  final String? addedAt; // ISO timestamp of first scan appearance
  final String? title;
  final String? artist;
  final String? albumArtist;
  final String? album;
  final int? year;
  final String? genre; // raw file tag; `genres` holds the canonical split
  final int? trackNo;
  final int? discNo;
  final double? duration; // seconds

  // format info for the bit-perfect badge
  final String? format; // container/codec, e.g. FLAC
  final int? sampleRate; // Hz
  final int? bitsPerSample;
  final int? channels;
  final bool lossless;

  final bool hasArt;
  final String? composer;
  final String? conductor;
  final String? orchestra;
  final String? work;
  final String? movement;
  final String? mbAlbumId;
  final String? mbRecordingId;
  final String? mbAlbumArtistId;
  final String? releaseType; // Album | EP | Single | Live | Compilation
  final List<String> genres; // canonical genres
  final List<String> tags; // user tag names (incl. ancestor chain)
  final List<Performer> performers;

  /// Alias for [format].
  String? get codec => format;

  /// Alias for [bitsPerSample].
  int? get bits => bitsPerSample;

  factory Track.fromJson(Map<String, dynamic> j) => Track(
        id: j['id'] as String,
        albumId: j['albumId'] as String,
        addedAt: asString(j['addedAt']),
        title: asString(j['title']),
        artist: asString(j['artist']),
        albumArtist: asString(j['albumArtist']),
        album: asString(j['album']),
        year: asInt(j['year']),
        genre: asString(j['genre']),
        trackNo: asInt(j['trackNo']),
        discNo: asInt(j['discNo']),
        duration: asDouble(j['duration']),
        format: asString(j['format']),
        sampleRate: asInt(j['sampleRate']),
        bitsPerSample: asInt(j['bitsPerSample']),
        channels: asInt(j['channels']),
        lossless: asBool(j['lossless']),
        hasArt: asBool(j['hasArt']),
        composer: asString(j['composer']),
        conductor: asString(j['conductor']),
        orchestra: asString(j['orchestra']),
        work: asString(j['work']),
        movement: asString(j['movement']),
        mbAlbumId: asString(j['mbAlbumId']),
        mbRecordingId: asString(j['mbRecordingId']),
        mbAlbumArtistId: asString(j['mbAlbumArtistId']),
        releaseType: asString(j['releaseType']),
        genres: asStringList(j['genres']),
        tags: asStringList(j['tags']),
        performers: j['performers'] is List
            ? (j['performers'] as List)
                .whereType<Map<String, dynamic>>()
                .map(Performer.fromJson)
                .toList()
            : const [],
      );
}
