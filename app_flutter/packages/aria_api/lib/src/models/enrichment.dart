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
      {required this.title, this.cover, this.date, this.type, this.deezerId});

  final String title;
  final String? cover;
  final String? date; // yyyy-mm-dd
  final String? type; // album | ep | single ... (lowercase)

  /// Absent from discographies cached before the id was kept; null only means
  /// the server falls back to a name search when resolving this album.
  final int? deezerId;

  factory DiscographyItem.fromJson(Map<String, dynamic> j) => DiscographyItem(
        title: j['title'] as String,
        cover: asString(j['cover']),
        date: asString(j['date']),
        type: asString(j['type']),
        deezerId: asInt(j['deezerId']),
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
    this.instruments = const [],
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

  /// Instruments played, from Wikidata. Empty for entries enriched before the
  /// Wikidata pass ran, and for anyone Wikidata says nothing about.
  final List<String> instruments;
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
        instruments: asStringList(j['instruments']),
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
    this.catno,
    this.mbType,
    this.mbSecondary = const [],
    this.blurb,
    this.url,
  });

  final String? label;
  final String? date;
  final String? country;

  /// Catalogue number of the pressing, from Discogs. Null without a server
  /// DISCOGS_TOKEN, and for releases MusicBrainz carries no Discogs link for.
  final String? catno;
  final String? mbType; // MB primary type
  final List<String> mbSecondary;
  final String? blurb;
  final String? url;

  factory AlbumInfo.fromJson(Map<String, dynamic> j) => AlbumInfo(
        label: asString(j['label']),
        date: asString(j['date']),
        country: asString(j['country']),
        catno: asString(j['catno']),
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
    this.deezerId,
  });

  final String artist;
  final String title;
  final String? cover;
  final String date; // yyyy-mm-dd
  final String type;

  /// Present only once the artist's discography has been re-cached since the
  /// id started being kept; null just means the server does a name search.
  final int? deezerId;

  factory NewRelease.fromJson(Map<String, dynamic> j) => NewRelease(
        artist: j['artist'] as String,
        title: j['title'] as String,
        cover: asString(j['cover']),
        date: j['date'] as String,
        type: asString(j['type']) ?? 'album',
        deezerId: asInt(j['deezerId']),
      );
}

/// One track of an album that isn't in the library — listable, not playable.
class ExtTrack {
  const ExtTrack({
    required this.title,
    required this.duration,
    required this.disc,
    required this.number,
  });

  final String title;
  final int duration; // seconds
  final int disc;
  final int number;

  factory ExtTrack.fromJson(Map<String, dynamic> j) => ExtTrack(
        title: asString(j['title']) ?? '',
        duration: asInt(j['duration']) ?? 0,
        disc: asInt(j['disc']) ?? 1,
        number: asInt(j['number']) ?? 0,
      );
}

/// `/api/extalbum`: an album nobody here owns, infused from Deezer and
/// MusicBrainz. [id] is the universal identity — `rg:<release-group mbid>`, or
/// `dz:<deezer id>` while MusicBrainz still hasn't ingested the record.
class ExtAlbum {
  const ExtAlbum({
    required this.id,
    required this.artist,
    required this.title,
    this.cover,
    required this.date,
    required this.type,
    this.label,
    this.link,
    this.upc,
    this.deezerId,
    this.tracks = const [],
  });

  final String id;
  final String artist;
  final String title;
  final String? cover;
  final String date;
  final String type;
  final String? label;
  final String? link;

  /// The barcode. Deezer, MusicBrainz and Qobuz all carry it, so it is what
  /// lets one saved album be recognised in another catalogue.
  final String? upc;
  final int? deezerId;
  final List<ExtTrack> tracks;

  factory ExtAlbum.fromJson(Map<String, dynamic> j) => ExtAlbum(
        id: asString(j['id']) ?? '',
        artist: asString(j['artist']) ?? '',
        title: asString(j['title']) ?? '',
        cover: asString(j['cover']),
        date: asString(j['date']) ?? '',
        type: asString(j['type']) ?? 'album',
        label: asString(j['label']),
        link: asString(j['link']),
        upc: asString(j['upc']),
        deezerId: asInt(j['deezerId']),
        tracks: j['tracks'] is List
            ? (j['tracks'] as List)
                .whereType<Map<String, dynamic>>()
                .map(ExtTrack.fromJson)
                .toList()
            : const [],
      );
}

/// `/api/listenlater` entry: an album saved to hear later, which by definition
/// is not in the library — the server drops it from this list once it arrives.
class ListenLaterAlbum {
  const ListenLaterAlbum({
    required this.id,
    required this.artist,
    required this.title,
    this.cover,
    this.date,
    required this.type,
    this.upc,
    this.deezerId,
    required this.addedAt,
  });

  final String id;
  final String artist;
  final String title;
  final String? cover;
  final String? date;
  final String type;
  final String? upc;
  final int? deezerId;
  final String addedAt;

  factory ListenLaterAlbum.fromJson(Map<String, dynamic> j) => ListenLaterAlbum(
        id: asString(j['id']) ?? '',
        artist: asString(j['artist']) ?? '',
        title: asString(j['title']) ?? '',
        cover: asString(j['cover']),
        date: asString(j['date']),
        type: asString(j['type']) ?? 'album',
        upc: asString(j['upc']),
        deezerId: asInt(j['deezerId']),
        addedAt: asString(j['addedAt']) ?? '',
      );
}
