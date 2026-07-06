import '../json.dart';

/// `/api/enrich/status` — background enrichment progress.
class EnrichStatus {
  const EnrichStatus({
    required this.phase,
    required this.done,
    required this.total,
    required this.running,
  });

  final String phase; // idle | albums | discographies | ...
  final int done;
  final int total;
  final bool running;

  factory EnrichStatus.fromJson(Map<String, dynamic> j) => EnrichStatus(
        phase: asString(j['phase']) ?? 'idle',
        done: asInt(j['done']) ?? 0,
        total: asInt(j['total']) ?? 0,
        running: asBool(j['running']),
      );
}

class SimilarArtist {
  const SimilarArtist({required this.name, this.image});

  final String name;
  final String? image;

  factory SimilarArtist.fromJson(Map<String, dynamic> j) =>
      SimilarArtist(name: j['name'] as String, image: asString(j['image']));
}

class DiscographyItem {
  const DiscographyItem(
      {required this.title, this.cover, this.date, this.type});

  final String title;
  final String? cover;
  final String? date; // yyyy-mm-dd
  final String? type; // album | ep | single ... (lowercase)

  factory DiscographyItem.fromJson(Map<String, dynamic> j) => DiscographyItem(
        title: j['title'] as String,
        cover: asString(j['cover']),
        date: asString(j['date']),
        type: asString(j['type']),
      );
}

/// `/api/artist/:name` — enriched person/band info (DB edits overlaid).
class ArtistInfo {
  const ArtistInfo({
    this.type,
    this.area,
    this.born,
    this.died,
    this.bio,
    this.url,
    this.image,
    this.imgSrc,
    this.similar = const [],
    this.members = const [],
    this.bands = const [],
    this.discography = const [],
  });

  final String? type; // Person | Group | ...
  final String? area;
  final String? born;
  final String? died;
  final String? bio;
  final String? url; // wikipedia page
  final String? image;
  final String? imgSrc; // wikipedia | deezer
  final List<SimilarArtist> similar;
  final List<String> members; // if a group
  final List<String> bands; // if a person
  final List<DiscographyItem> discography;

  factory ArtistInfo.fromJson(Map<String, dynamic> j) => ArtistInfo(
        type: asString(j['type']),
        area: asString(j['area']),
        born: asString(j['born']),
        died: asString(j['died']),
        bio: asString(j['bio']),
        url: asString(j['url']),
        image: asString(j['image']),
        imgSrc: asString(j['imgSrc']),
        similar: j['similar'] is List
            ? (j['similar'] as List)
                .whereType<Map<String, dynamic>>()
                .map(SimilarArtist.fromJson)
                .toList()
            : const [],
        members: asStringList(j['members']),
        bands: asStringList(j['bands']),
        discography: j['discography'] is List
            ? (j['discography'] as List)
                .whereType<Map<String, dynamic>>()
                .map(DiscographyItem.fromJson)
                .toList()
            : const [],
      );
}

/// `/api/composer/:name` — Open Opus + Wikipedia.
class ComposerInfo {
  const ComposerInfo({
    this.fullName,
    this.epoch,
    this.portrait,
    this.born,
    this.died,
    this.bio,
    this.url,
  });

  final String? fullName;
  final String? epoch;
  final String? portrait;
  final String? born; // year string
  final String? died;
  final String? bio;
  final String? url;

  factory ComposerInfo.fromJson(Map<String, dynamic> j) => ComposerInfo(
        fullName: asString(j['fullName']),
        epoch: asString(j['epoch']),
        portrait: asString(j['portrait']),
        born: asString(j['born']),
        died: asString(j['died']),
        bio: asString(j['bio']),
        url: asString(j['url']),
      );
}

/// `/api/album/:albumId/info` — label/date from MB, blurb from Wikipedia,
/// album-level DB edits overlaid.
class AlbumInfo {
  const AlbumInfo({
    this.label,
    this.date,
    this.country,
    this.mbType,
    this.mbSecondary = const [],
    this.blurb,
    this.url,
  });

  final String? label;
  final String? date;
  final String? country;
  final String? mbType; // MB primary type
  final List<String> mbSecondary;
  final String? blurb;
  final String? url;

  factory AlbumInfo.fromJson(Map<String, dynamic> j) => AlbumInfo(
        label: asString(j['label']),
        date: asString(j['date']),
        country: asString(j['country']),
        mbType: asString(j['mbType']),
        mbSecondary: asStringList(j['mbSecondary']),
        blurb: asString(j['blurb']),
        url: asString(j['url']),
      );
}

/// `/api/lyrics/:id` — at least one of synced/plain is set.
class Lyrics {
  const Lyrics({this.synced, this.plain});

  final String? synced; // LRC-format timed lyrics
  final String? plain;

  factory Lyrics.fromJson(Map<String, dynamic> j) =>
      Lyrics(synced: asString(j['synced']), plain: asString(j['plain']));
}

/// `/api/identify/artist/:name` candidate.
class ArtistCandidate {
  const ArtistCandidate({
    required this.mbid,
    required this.name,
    this.type,
    this.area,
    this.disambiguation,
    this.score,
  });

  final String mbid;
  final String name;
  final String? type;
  final String? area;
  final String? disambiguation;
  final int? score;

  factory ArtistCandidate.fromJson(Map<String, dynamic> j) => ArtistCandidate(
        mbid: j['mbid'] as String,
        name: j['name'] as String,
        type: asString(j['type']),
        area: asString(j['area']),
        disambiguation: asString(j['disambiguation']),
        score: asInt(j['score']),
      );
}

/// `/api/identify/album/:albumId` candidate.
class AlbumCandidate {
  const AlbumCandidate({
    required this.mbid,
    required this.title,
    this.artist,
    this.date,
    this.country,
    this.trackCount,
    this.score,
  });

  final String mbid;
  final String title;
  final String? artist;
  final String? date;
  final String? country;
  final int? trackCount;
  final int? score;

  factory AlbumCandidate.fromJson(Map<String, dynamic> j) => AlbumCandidate(
        mbid: j['mbid'] as String,
        title: j['title'] as String,
        artist: asString(j['artist']),
        date: asString(j['date']),
        country: asString(j['country']),
        trackCount: asInt(j['tracks']),
        score: asInt(j['score']),
      );
}

/// `/api/newreleases` item: recent, not-in-library release by a library artist.
class NewRelease {
  const NewRelease({
    required this.artist,
    required this.title,
    this.cover,
    required this.date,
    required this.type,
  });

  final String artist;
  final String title;
  final String? cover;
  final String date; // yyyy-mm-dd
  final String type;

  factory NewRelease.fromJson(Map<String, dynamic> j) => NewRelease(
        artist: j['artist'] as String,
        title: j['title'] as String,
        cover: asString(j['cover']),
        date: j['date'] as String,
        type: asString(j['type']) ?? 'album',
      );
}
