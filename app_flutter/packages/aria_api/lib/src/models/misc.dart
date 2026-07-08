import '../json.dart';

/// `/api/status`.
class ServerStatus {
  const ServerStatus({
    required this.tracks,
    required this.musicDir,
    required this.version,
    this.transcode = false,
  });

  final int tracks;
  final String musicDir;
  final String version;

  /// Whether the server has ffmpeg and can serve `?tier=high|low`. Absent on
  /// older servers → false, so the app offers only the original tier.
  final bool transcode;

  factory ServerStatus.fromJson(Map<String, dynamic> j) => ServerStatus(
        tracks: asInt(j['tracks']) ?? 0,
        musicDir: asString(j['musicDir']) ?? '',
        version: asString(j['version']) ?? '',
        transcode: asBool(j['transcode']),
      );
}

/// `/api/settings`.
class Settings {
  const Settings({this.listenbrainzToken = ''});

  final String listenbrainzToken;

  factory Settings.fromJson(Map<String, dynamic> j) =>
      Settings(listenbrainzToken: asString(j['listenbrainzToken']) ?? '');
}

/// `/api/radio` station (builtin stations cannot be deleted).
class RadioStation {
  const RadioStation({
    required this.id,
    required this.name,
    required this.url,
    this.genre,
    this.builtin = false,
    this.createdAt,
  });

  final String id;
  final String name;
  final String url;
  final String? genre;
  final bool builtin;
  final String? createdAt;

  factory RadioStation.fromJson(Map<String, dynamic> j) => RadioStation(
        id: j['id'] as String,
        name: j['name'] as String,
        url: j['url'] as String,
        genre: asString(j['genre']),
        builtin: asBool(j['builtin']),
        createdAt: asString(j['createdAt']),
      );
}

/// `/api/edits/:kind/:key` — pre-override originals + current overrides,
/// for populating an edit form. Field sets differ per kind.
class EditState {
  const EditState({required this.original, required this.overrides});

  final Map<String, dynamic> original;
  final Map<String, dynamic> overrides;

  factory EditState.fromJson(Map<String, dynamic> j) => EditState(
        original: asMap(j['original']),
        overrides: asMap(j['overrides']),
      );
}

/// `/api/genres` — canonical genre -> parent genre (null = top level).
class GenreTree {
  const GenreTree(this.parents);

  final Map<String, String?> parents;

  Iterable<String> get topLevel =>
      parents.entries.where((e) => e.value == null).map((e) => e.key);

  List<String> childrenOf(String genre) =>
      parents.entries.where((e) => e.value == genre).map((e) => e.key).toList();

  factory GenreTree.fromJson(Map<String, dynamic> j) => GenreTree(
        asMap(j['tree']).map((k, v) => MapEntry(k, asString(v))),
      );
}
