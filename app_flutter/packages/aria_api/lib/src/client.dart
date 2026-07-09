import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'exceptions.dart';
import 'json.dart';
import 'models/enrichment.dart';
import 'models/eq.dart';
import 'models/misc.dart';
import 'models/playlist.dart';
import 'models/profile.dart';
import 'models/stats.dart';
import 'models/tag.dart';
import 'models/track.dart';
import 'sse.dart';

/// Sentinel so PATCH bodies can distinguish "not provided" from
/// "explicitly null" (null clears a server-side override / tag parent).
const Object unset = _Unset();

class _Unset {
  const _Unset();
}

/// Typed client for the Aria server API. The base URL is user-configured at
/// runtime; audio and art are consumed by URL ([streamUrl], [artUrl]) — the
/// player streams natively, the client never downloads-then-plays.
class AriaClient {
  AriaClient({required String baseUrl, http.Client? httpClient})
      : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  void close() => _http.close();

  Uri _u(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(
          queryParameters: (query == null || query.isEmpty) ? null : query);

  // ---- URL builders (consumed directly by the native player / image cache)

  /// [tier] is the server transcode tier wire value (`high`/`low`); pass null
  /// (or `original`) for the raw byte-for-byte file — the param is OMITTED
  /// then so the URL and its caching are identical to the historical path.
  /// The app layer maps its QualityTier enum → wire; the client stays
  /// Riverpod-free and takes a plain string.
  String streamUrl(String trackId, {String? tier}) {
    final url = '$baseUrl/api/stream/${Uri.encodeComponent(trackId)}';
    return _tierQuery(tier) == null ? url : '$url?tier=$tier';
  }

  /// Null / empty / `original` → no query param; only `high`/`low` append.
  static String? _tierQuery(String? tier) =>
      (tier == null || tier.isEmpty || tier == 'original') ? null : tier;

  String artUrl(String albumId) =>
      '$baseUrl/api/art/${Uri.encodeComponent(albumId)}';

  String bookletUrl(String albumId, String name) =>
      '$baseUrl/api/albums/${Uri.encodeComponent(albumId)}'
      '/booklet/${Uri.encodeComponent(name)}';

  /// Candidate booklet PDF names in the album's directory, best first;
  /// empty when none. Each name feeds [bookletUrl].
  Future<List<String>> booklets(String albumId) async => asStringList(
      asMap(await _get('/api/albums/${Uri.encodeComponent(albumId)}/booklets'))[
          'booklets']);

  // ---- plumbing

  /// Per-request cap so a dead/unreachable server fails fast instead of
  /// hanging callers forever. The SSE stream ([events]) is exempt — only its
  /// initial connection is guarded.
  static const _timeout = Duration(seconds: 15);

  /// Awaits [f] with [_timeout], mapping [TimeoutException] into the normal
  /// [AriaApiException] flow (statusCode 0 = no response).
  Future<T> _timed<T>(Future<T> f, String path) async {
    try {
      return await f.timeout(_timeout);
    } on TimeoutException {
      throw AriaApiException(0, 'request timed out', path: path);
    }
  }

  Never _throw(http.Response r, String path) {
    String msg = r.body;
    try {
      final j = jsonDecode(r.body);
      if (j is Map && j['error'] is String) msg = j['error'] as String;
    } on FormatException {
      // keep raw body
    }
    throw AriaApiException(r.statusCode, msg, path: path);
  }

  Future<Object?> _json(Future<http.Response> f, String path,
      {bool nullOn404 = false}) async {
    final r = await _timed(f, path);
    if (r.statusCode == 404 && nullOn404) return null;
    if (r.statusCode < 200 || r.statusCode >= 300) _throw(r, path);
    if (r.body.isEmpty) return null;
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<Object?> _get(String path,
          {Map<String, String>? query, bool nullOn404 = false}) =>
      _json(_http.get(_u(path, query)), path, nullOn404: nullOn404);

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  Future<Object?> _send(String method, String path, [Object? body]) async {
    final req = http.Request(method, _u(path));
    if (body != null) {
      req.headers.addAll(_jsonHeaders);
      req.body = jsonEncode(body);
    }
    final r =
        await _timed(_http.send(req).then(http.Response.fromStream), path);
    if (r.statusCode < 200 || r.statusCode >= 300) _throw(r, path);
    if (r.body.isEmpty) return null;
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  Future<Object?> _post(String path, [Object? body]) =>
      _send('POST', path, body);
  Future<Object?> _patch(String path, Object body) =>
      _send('PATCH', path, body);
  Future<Object?> _put(String path, Object body) => _send('PUT', path, body);
  Future<Object?> _delete(String path, [Object? body]) =>
      _send('DELETE', path, body);

  static List<T> _list<T>(Object? v, T Function(Map<String, dynamic>) f) =>
      (v as List).whereType<Map<String, dynamic>>().map(f).toList();

  // ---- library

  Future<ServerStatus> status() async =>
      ServerStatus.fromJson(asMap(await _get('/api/status')));

  /// Trigger a full rescan; resolves with the new track count when done.
  Future<int> scan() async =>
      asInt(asMap(await _post('/api/scan'))['tracks']) ?? 0;

  /// The whole-library payload (100k+ rows). Decode + Track mapping run in a
  /// background isolate ([Isolate.run], pure Dart — fine on every non-web
  /// target) so the UI isolate never freezes; the tracks come back via
  /// isolate copy, which is much cheaper than parsing on the main thread.
  /// Small endpoints stay on the calling isolate.
  Future<List<Track>> tracks({int? limit, int? offset}) async {
    final bytes = await tracksBytes(limit: limit, offset: offset);
    return Isolate.run(() => decodeTracks(bytes));
  }

  /// Raw `/api/tracks` payload bytes — the app persists these for offline
  /// startup and decodes them (and the disk cache) with [decodeTracks].
  Future<Uint8List> tracksBytes({int? limit, int? offset}) async {
    const path = '/api/tracks';
    final r = await _timed(
        _http.get(_u(path, {
          if (limit != null) 'limit': '$limit',
          if (offset != null) 'offset': '$offset',
        })),
        path);
    if (r.statusCode < 200 || r.statusCode >= 300) _throw(r, path);
    return r.bodyBytes;
  }

  /// Decoder for a `/api/tracks` payload; static so [Isolate.run] closures
  /// only capture the bytes.
  static List<Track> decodeTracks(List<int> bytes) =>
      _list(jsonDecode(utf8.decode(bytes)), Track.fromJson);

  Future<GenreTree> genres() async =>
      GenreTree.fromJson(asMap(await _get('/api/genres')));

  // ---- enrichment

  Future<EnrichStatus> enrichStatus() async =>
      EnrichStatus.fromJson(asMap(await _get('/api/enrich/status')));

  /// Kick a background enrichment pass; returns current progress.
  Future<EnrichStatus> kickEnrich() async =>
      EnrichStatus.fromJson(asMap(await _post('/api/enrich')));

  /// Bulk name -> portrait URL map for avatars.
  Future<Map<String, String>> people() async =>
      asMap(await _get('/api/people')).map((k, v) => MapEntry(k, v as String));

  /// Warm faces/bios for names currently on screen; returns queued count.
  Future<int> warmPeople(List<String> names) async =>
      asInt(asMap(
          await _post('/api/enrich/people', {'names': names}))['queued']) ??
      0;

  Future<AlbumInfo?> albumInfo(String albumId) async {
    final j = await _get('/api/album/${Uri.encodeComponent(albumId)}/info',
        nullOn404: true);
    return j == null ? null : AlbumInfo.fromJson(asMap(j));
  }

  Future<ArtistInfo?> artist(String name) async {
    final j =
        await _get('/api/artist/${Uri.encodeComponent(name)}', nullOn404: true);
    return j == null ? null : ArtistInfo.fromJson(asMap(j));
  }

  Future<ComposerInfo?> composer(String name) async {
    final j = await _get('/api/composer/${Uri.encodeComponent(name)}',
        nullOn404: true);
    return j == null ? null : ComposerInfo.fromJson(asMap(j));
  }

  Future<Lyrics?> lyrics(String trackId) async {
    final j = await _get('/api/lyrics/${Uri.encodeComponent(trackId)}',
        nullOn404: true);
    return j == null ? null : Lyrics.fromJson(asMap(j));
  }

  // ---- identify / re-identify

  Future<List<ArtistCandidate>> identifyArtist(String name) async => _list(
      await _get('/api/identify/artist/${Uri.encodeComponent(name)}'),
      ArtistCandidate.fromJson);

  Future<ArtistInfo> reidentifyArtist(String name, {String? mbid}) async =>
      ArtistInfo.fromJson(asMap(await _post(
          '/api/artist/${Uri.encodeComponent(name)}/reidentify',
          {'mbid': mbid})));

  Future<List<AlbumCandidate>> identifyAlbum(String albumId) async => _list(
      await _get('/api/identify/album/${Uri.encodeComponent(albumId)}'),
      AlbumCandidate.fromJson);

  Future<AlbumInfo> reidentifyAlbum(String albumId, {String? mbid}) async =>
      AlbumInfo.fromJson(asMap(await _post(
          '/api/album/${Uri.encodeComponent(albumId)}/reidentify',
          {'mbid': mbid})));

  // ---- tags

  Future<List<Tag>> tags() async =>
      _list(await _get('/api/tags'), Tag.fromJson);

  /// `parent` is a folder id; pass `folder: true` to create a folder instead.
  Future<Tag> createTag(String name,
          {String? parent, bool folder = false}) async =>
      Tag.fromJson(asMap(await _post('/api/tags', {
        'name': name,
        'parent': parent,
        'folder': folder,
      })));

  /// Pass `parent: null` explicitly to move a tag out of its folder.
  Future<Tag> updateTag(String id,
          {String? name, Object? parent = unset}) async =>
      Tag.fromJson(asMap(await _patch('/api/tags/${Uri.encodeComponent(id)}', {
        if (name != null) 'name': name,
        if (parent is! _Unset) 'parent': parent,
      })));

  Future<void> deleteTag(String id) =>
      _delete('/api/tags/${Uri.encodeComponent(id)}');

  /// `kind`: track | album | artist. Artist keys are free-form names.
  Future<Tag> addTagItem(String id,
          {required String kind, required String key}) async =>
      Tag.fromJson(asMap(await _put(
          '/api/tags/${Uri.encodeComponent(id)}/items',
          {'kind': kind, 'key': key})));

  Future<Tag> removeTagItem(String id,
          {required String kind, required String key}) async =>
      Tag.fromJson(asMap(await _delete(
          '/api/tags/${Uri.encodeComponent(id)}/items',
          {'kind': kind, 'key': key})));

  /// Set the independent favourite flag on a track.
  Future<void> setFavourite(String id, bool favourite) async => _put(
      '/api/tracks/${Uri.encodeComponent(id)}/favourite',
      {'favourite': favourite});

  // ---- metadata edits (DB overrides; a null field value clears the override)

  Future<Map<String, dynamic>> patchTrack(
          String id, Map<String, dynamic> edits) async =>
      asMap(await _patch('/api/tracks/${Uri.encodeComponent(id)}', edits));

  Future<Map<String, dynamic>> patchAlbum(
          String albumId, Map<String, dynamic> edits) async =>
      asMap(await _patch('/api/albums/${Uri.encodeComponent(albumId)}', edits));

  Future<Map<String, dynamic>> patchArtist(
          String name, Map<String, dynamic> edits) async =>
      asMap(await _patch('/api/artists/${Uri.encodeComponent(name)}', edits));

  /// `kind`: track | album | artist. Originals + current overrides for an editor.
  Future<EditState?> edits(String kind, String key) async {
    final j = await _get(
        '/api/edits/${Uri.encodeComponent(kind)}/${Uri.encodeComponent(key)}',
        nullOn404: true);
    return j == null ? null : EditState.fromJson(asMap(j));
  }

  // ---- profiles

  Future<List<Profile>> profiles() async =>
      _list(await _get('/api/profiles'), Profile.fromJson);

  Future<Profile> createProfile(
          {required String name, required String color}) async =>
      Profile.fromJson(
          asMap(await _post('/api/profiles', {'name': name, 'color': color})));

  Future<Profile> updateProfile(String id,
          {String? name, String? color}) async =>
      Profile.fromJson(
          asMap(await _patch('/api/profiles/${Uri.encodeComponent(id)}', {
        if (name != null) 'name': name,
        if (color != null) 'color': color,
      })));

  Future<void> deleteProfile(String id) =>
      _delete('/api/profiles/${Uri.encodeComponent(id)}');

  // ---- settings

  Future<Settings> settings() async =>
      Settings.fromJson(asMap(await _get('/api/settings')));

  /// Empty string clears the token.
  Future<void> saveSettings({String? listenbrainzToken}) => _post(
      '/api/settings',
      {if (listenbrainzToken != null) 'listenbrainzToken': listenbrainzToken});

  // ---- plays / stats

  /// [at] (JS-toISOString format, e.g. "2026-07-08T12:00:00.000Z") backdates
  /// the play — used when flushing plays queued while offline; the server
  /// defaults to its own clock when omitted.
  Future<void> recordPlay(
          {required String trackId, required String profileId, String? at}) =>
      _post('/api/plays', {
        'trackId': trackId,
        'profileId': profileId,
        if (at != null) 'at': at,
      });

  /// `counts: true` adds full per-track play counts (played/never filters).
  Future<Stats> stats({String? profileId, bool counts = false}) async =>
      Stats.fromJson(asMap(await _get('/api/stats', query: {
        if (profileId != null) 'profileId': profileId,
        if (counts) 'counts': '1',
      })));

  Future<List<NewRelease>> newReleases() async =>
      _list(await _get('/api/newreleases'), NewRelease.fromJson);

  // ---- playlists

  Future<List<Playlist>> playlists({String? profileId}) async => _list(
      await _get('/api/playlists',
          query: {if (profileId != null) 'profileId': profileId}),
      Playlist.fromJson);

  /// Manual playlist unless [rules] is given (then type=smart).
  Future<Playlist> createPlaylist({
    required String profileId,
    required String name,
    SmartRules? rules,
  }) async =>
      Playlist.fromJson(asMap(await _post('/api/playlists', {
        'profileId': profileId,
        'name': name,
        'type': rules == null ? 'manual' : 'smart',
        if (rules != null) 'rules': rules.toJson(),
      })));

  Future<Playlist> updatePlaylist(String id,
          {String? name, SmartRules? rules}) async =>
      Playlist.fromJson(
          asMap(await _patch('/api/playlists/${Uri.encodeComponent(id)}', {
        if (name != null) 'name': name,
        if (rules != null) 'rules': rules.toJson(),
      })));

  Future<void> deletePlaylist(String id) =>
      _delete('/api/playlists/${Uri.encodeComponent(id)}');

  Future<Playlist> addPlaylistTrack(String id, String trackId) async =>
      Playlist.fromJson(asMap(await _post(
          '/api/playlists/${Uri.encodeComponent(id)}/tracks',
          {'trackId': trackId})));

  /// Removes ALL occurrences of the track (server semantics).
  Future<Playlist> removePlaylistTrack(String id, String trackId) async =>
      Playlist.fromJson(asMap(await _delete(
          '/api/playlists/${Uri.encodeComponent(id)}/tracks/${Uri.encodeComponent(trackId)}')));

  /// Full track objects; smart playlists are evaluated server-side on demand.
  Future<List<Track>> playlistTracks(String id) async => _list(
      await _get('/api/playlists/${Uri.encodeComponent(id)}/tracks'),
      Track.fromJson);

  // ---- radio

  Future<List<RadioStation>> radioStations() async =>
      _list(await _get('/api/radio'), RadioStation.fromJson);

  Future<RadioStation> addRadioStation(
          {required String name, required String url, String? genre}) async =>
      RadioStation.fromJson(asMap(await _post(
          '/api/radio', {'name': name, 'url': url, 'genre': genre})));

  Future<void> deleteRadioStation(String id) =>
      _delete('/api/radio/${Uri.encodeComponent(id)}');

  // ---- eq

  /// OPRA headphone EQ database (server-cached weekly).
  Future<List<OpraProduct>> eqOpra() async => _list(
      asMap(await _get('/api/eq/opra'))['products'], OpraProduct.fromJson);

  // ---- logs

  /// Batch-upload device log entries ({ts, level, tag, msg, extra?} maps);
  /// returns the stored count. Server caps: 1000 entries / 1 MiB per request.
  Future<int> uploadLogs(
          String device, List<Map<String, dynamic>> entries) async =>
      asInt(asMap(await _post('/api/logs', {
        'device': device,
        'entries': entries,
      }))['stored']) ??
      0;

  // ---- downloads (offline copies; the stream endpoint serves the exact
  // original bytes, so a completed download is bit-perfect by construction)

  /// Streamed GET of a track's original file. No request timeout — large
  /// lossless files legitimately take minutes. Throws [AriaApiException] on
  /// non-2xx.
  Future<http.StreamedResponse> download(String trackId, {String? tier}) {
    final path = '/api/stream/${Uri.encodeComponent(trackId)}';
    final q = _tierQuery(tier);
    return _download(q == null ? path : '$path?tier=$q');
  }

  /// Streamed GET of an album's cover art (same contract as [download]).
  Future<http.StreamedResponse> downloadArt(String albumId) =>
      _download('/api/art/${Uri.encodeComponent(albumId)}');

  Future<http.StreamedResponse> _download(String path) async {
    final res = await _http.send(http.Request('GET', _u(path)));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw AriaApiException(res.statusCode, 'download failed', path: path);
    }
    return res;
  }

  // ---- events (SSE): scan / enrich progress

  /// Long-lived server-sent event stream. Caller handles reconnects.
  Stream<AriaEvent> events({String path = '/api/events'}) async* {
    final req = http.Request('GET', _u(path))
      ..headers['Accept'] = 'text/event-stream';
    // Guard only the initial connection; the stream itself is long-lived and
    // must never be killed by a timeout.
    final res = await _timed(_http.send(req), path);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw AriaApiException(res.statusCode, 'event stream failed', path: path);
    }
    yield* parseSse(res.stream);
  }
}
