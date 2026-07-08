import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection.dart';
import 'data_usage.dart';
import 'log.dart';
import 'quality.dart';

// Offline downloads live in core because playback resolves local sources at
// play time; the Settings UI re-imports via settings_providers.dart per the
// core-vs-feature rule. Files land in <app-support>/downloads/ — at the
// original tier the endpoint serves the exact source bytes (bit-perfect by
// construction); a high/low download is the server's Opus transcode, and a
// local copy always wins at play time whatever tier it was fetched at.

/// trackId -> absolute local file path when downloaded, else null.
/// QueueNotifier prefers this over streamUrl in _playCurrent/_syncEngineNext
/// (mpv takes a plain path like any URL, so gapless works offline too).
final localSourceResolverProvider = Provider<String? Function(String trackId)>(
  (ref) => (id) => ref.read(downloadsProvider).index[id]?.path,
);

/// albumId -> local cover-art path, null when never fetched. ArtImage falls
/// back to it when the network image errors (offline).
final localArtResolverProvider = Provider<String? Function(String albumId)>(
  (ref) => (albumId) => ref.read(downloadsProvider.notifier).localArt(albumId),
);

/// File extension for a downloaded track: track.format lowercased, else the
/// response Content-Type, else ".bin" (the bytes are still playable — mpv
/// sniffs the container).
String extensionFor(String? format, String? contentType) {
  final f = format?.toLowerCase();
  if (f != null && RegExp(r'^[a-z0-9]+$').hasMatch(f)) return '.$f';
  const byType = {
    'audio/flac': '.flac',
    'audio/mpeg': '.mp3',
    'audio/mp4': '.m4a',
    // The transcoder serves Opus-in-Ogg as audio/ogg; a native .ogg is
    // resolved by its track.format before we reach this map.
    'audio/ogg': '.opus',
    'audio/wav': '.wav',
    'audio/aiff': '.aiff',
    'audio/x-ape': '.ape',
    'audio/x-wavpack': '.wv',
    'audio/x-dsf': '.dsf',
  };
  return byType[contentType?.split(';').first.trim()] ?? '.bin';
}

class DownloadEntry {
  const DownloadEntry({
    required this.path,
    required this.bytes,
    this.etag,
    this.tier = QualityTier.original,
  });

  factory DownloadEntry.fromJson(Map<String, dynamic> j) => DownloadEntry(
    path: j['path'] as String,
    bytes: (j['bytes'] as num?)?.toInt() ?? 0,
    etag: j['etag'] as String?,
    tier: QualityTier.fromWire(j['tier'] as String?),
  );

  final String path;
  final int bytes;

  /// Server ETag at download time ("modtimeNano-size") — a retagged file
  /// changes it, so a future re-verify pass can detect stale copies.
  final String? etag;

  /// Transcode tier the file was fetched at (a low download plays low
  /// everywhere — intended; a higher-tier redownload is future work).
  final QualityTier tier;

  Map<String, dynamic> toJson() => {
    'path': path,
    'bytes': bytes,
    if (etag != null) 'etag': etag,
    'tier': tier.wire,
  };
}

class DownloadsState {
  const DownloadsState({
    this.index = const {},
    this.queue = const [],
    this.active,
    this.progress,
  });

  /// trackId -> completed download.
  final Map<String, DownloadEntry> index;

  /// Pending trackIds, download order.
  final List<String> queue;

  /// trackId currently downloading, null when idle/paused.
  final String? active;

  /// 0..1 for [active]; null when unknown (no Content-Length) or idle.
  final double? progress;

  static const _unset = Object();

  DownloadsState copyWith({
    Map<String, DownloadEntry>? index,
    List<String>? queue,
    Object? active = _unset,
    Object? progress = _unset,
  }) => DownloadsState(
    index: index ?? this.index,
    queue: queue ?? this.queue,
    active: identical(active, _unset) ? this.active : active as String?,
    progress: identical(progress, _unset)
        ? this.progress
        : progress as double?,
  );
}

final downloadsProvider = NotifierProvider<DownloadsNotifier, DownloadsState>(
  DownloadsNotifier.new,
);

/// Sequential download worker + persistent index. One file at a time (a home
/// server, not a CDN); the queue pauses when data-usage settings block the
/// current network kind and resumes on the next network or settings change.
class DownloadsNotifier extends Notifier<DownloadsState> {
  Directory? _root;

  /// Queued tracks by id — the worker needs format/albumId, not just the id.
  final Map<String, Track> _pending = {};

  bool _running = false;

  /// Failed attempts per trackId; cleared on success/remove.
  final Map<String, int> _attempts = {};

  /// One-shot re-pump after a failure pauses the worker.
  Timer? _retry;

  /// Chains index writes so concurrent saves can never interleave.
  Future<void> _saves = Future.value();

  @override
  DownloadsState build() {
    Directory support;
    try {
      support = ref.read(appSupportDirProvider);
    } catch (_) {
      // No support dir (widget tests without an override): inert notifier —
      // nothing is ever local, downloads no-op.
      return const DownloadsState();
    }
    _root = Directory('${support.path}/downloads');
    // Resume a paused queue when the network kind changes (listen, not
    // watch — a wifi flip must not rebuild the notifier).
    ref.listen(networkKindProvider, (_, _) => _pump());
    // Data-usage changes (e.g. enabling cellular downloads) must also wake a
    // paused queue — networkKindProvider dedupes, so it never re-fires.
    ref.listen(dataUsageProvider, (_, _) => _pump());
    ref.onDispose(() => _retry?.cancel());
    return DownloadsState(index: _loadIndex());
  }

  File get _indexFile => File('${_root!.path}/index.json');

  Map<String, DownloadEntry> _loadIndex() {
    try {
      final j = jsonDecode(_indexFile.readAsStringSync());
      final index = {
        for (final e in (j as Map<String, dynamic>).entries)
          if (e.value is Map<String, dynamic>)
            e.key: DownloadEntry.fromJson(e.value as Map<String, dynamic>),
      };
      // Crash mid-remove or external cleanup: never trust an entry whose
      // file is gone — the track just re-downloads.
      index.removeWhere((_, e) => !File(e.path).existsSync());
      return index;
    } catch (_) {
      return const {}; // missing or corrupt — start clean, files re-download
    }
  }

  Future<void> _saveIndex() {
    // Snapshot now, then serialize writes through [_saves] and go via
    // .part + rename (the library_providers cache convention) so overlapping
    // saves or a crash mid-write can never tear index.json.
    final json = jsonEncode({
      for (final e in state.index.entries) e.key: e.value.toJson(),
    });
    return _saves = _saves.then((_) async {
      await _root!.create(recursive: true);
      final tmp = File('${_indexFile.path}.part');
      await tmp.writeAsString(json);
      await tmp.rename(_indexFile.path);
    });
  }

  /// Absolute local path for a downloaded track, null otherwise.
  String? localPath(String trackId) => state.index[trackId]?.path;

  /// Local cover-art path for an album, null when never fetched.
  String? localArt(String albumId) {
    if (_root == null) return null;
    final p = '${_root!.path}/art/$albumId';
    return File(p).existsSync() ? p : null;
  }

  /// Queue tracks for download, skipping ones already downloaded or queued.
  /// Returns when the queue drains (or pauses) — callers may fire-and-forget.
  Future<void> downloadTracks(Iterable<Track> tracks) async {
    if (_root == null) return;
    final add = <String>[];
    for (final t in tracks) {
      if (state.index.containsKey(t.id) || _pending.containsKey(t.id)) {
        continue;
      }
      _pending[t.id] = t;
      add.add(t.id);
    }
    if (add.isEmpty) return _pump(); // re-tapping Download kicks a paused queue
    Log.i('downloads', 'queued ${add.length} tracks');
    state = state.copyWith(queue: [...state.queue, ...add]);
    await _pump();
  }

  Future<void> remove(String trackId) async {
    _attempts.remove(trackId);
    if (state.queue.contains(trackId)) {
      _pending.remove(trackId);
      state = state.copyWith(
        queue: [
          for (final q in state.queue)
            if (q != trackId) q,
        ],
      );
    }
    final e = state.index[trackId];
    if (e == null) return;
    state = state.copyWith(index: {...state.index}..remove(trackId));
    // Index first, then the file: it must never claim bytes that are gone.
    await _saveIndex();
    try {
      await File(e.path).delete();
    } catch (_) {
      // already gone — the index entry was the lie, and it's dropped now
    }
    Log.i('downloads', 'removed download', trackId);
  }

  /// Drop every download, the queue, and the cached art.
  /// ponytail: an in-flight download finishes and re-indexes itself after
  /// this — remove it again once it completes (cancel would need an abortable
  /// byte stream).
  Future<void> removeAll() async {
    _pending.clear();
    _attempts.clear();
    final old = state.index;
    state = const DownloadsState();
    // Empty index first, then the files: it must never claim bytes that are
    // gone.
    if (_root != null) await _saveIndex();
    for (final e in old.values) {
      try {
        await File(e.path).delete();
      } catch (_) {}
    }
    if (_root != null) {
      try {
        await Directory('${_root!.path}/art').delete(recursive: true);
      } catch (_) {}
    }
    Log.i('downloads', 'removed all downloads (${old.length})');
  }

  // ------------------------------------------------------------- worker

  Future<void> _pump() async {
    if (_running || _root == null) return;
    _running = true;
    try {
      while (state.queue.isNotEmpty) {
        final kind = ref.read(networkKindProvider).value ?? NetKind.other;
        if (!ref.read(dataUsageProvider).allowsDownload(kind)) {
          Log.i('downloads', 'paused: blocked on ${kind.name} by data usage');
          return; // build()'s network listener re-pumps on change
        }
        final id = state.queue.first;
        final t = _pending[id]!;
        state = state.copyWith(
          queue: state.queue.sublist(1),
          active: id,
          progress: 0.0,
        );
        try {
          await _downloadOne(t);
          _attempts.remove(id);
        } catch (e) {
          // ponytail: 3 attempts, flat 30s pause — no backoff curve until a
          // real network proves it needs one.
          final tries = (_attempts[id] ?? 0) + 1;
          if (tries < 3) {
            _attempts[id] = tries;
            Log.w('downloads', 'failed ${t.title ?? t.id} (attempt $tries)', e);
            state = state.copyWith(
              queue: [...state.queue, id], // keep _pending[id] for the retry
              active: null,
              progress: null,
            );
            _retry?.cancel();
            _retry = Timer(const Duration(seconds: 30), _pump);
            return; // pause; timer or network/data-usage listeners re-pump
          }
          _attempts.remove(id);
          Log.w('downloads', 'dropped ${t.title ?? t.id} after $tries attempts', e);
        }
        _pending.remove(id);
        state = state.copyWith(active: null, progress: null);
      }
    } catch (_) {
      // provider disposed mid-download (teardown) — stop quietly
    } finally {
      _running = false;
    }
  }

  Future<void> _downloadOne(Track t) async {
    Log.i('downloads', 'start ${t.title ?? t.id}', t.id);
    final tier = ref
        .read(qualityProvider)
        .tierDownload
        .clamp(ref.read(transcodeAvailableProvider));
    final res = await ref.read(apiClientProvider).download(t.id, tier: tier.wire);
    // For a transcoded tier the bytes are Opus regardless of the source
    // format, so trust the response Content-Type (audio/ogg → .opus); the
    // original tier keeps deriving from track.format.
    final ext = extensionFor(
      tier == QualityTier.original ? t.format : null,
      res.headers['content-type'],
    );
    await _root!.create(recursive: true);
    final path = '${_root!.path}/${t.id}$ext';
    final part = File('$path.part');
    final total = res.contentLength ?? 0;
    var received = 0;
    final sink = part.openWrite();
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) state = state.copyWith(progress: received / total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (total > 0 && received != total) {
      await part.delete();
      throw StateError('short read: $received of $total bytes');
    }
    await part.rename(path);
    state = state.copyWith(
      index: {
        ...state.index,
        t.id: DownloadEntry(
          path: path,
          bytes: received,
          etag: res.headers['etag'],
          tier: tier,
        ),
      },
    );
    await _saveIndex();
    Log.i('downloads', 'done ${t.title ?? t.id} ($received bytes)', t.id);
    await _fetchArt(t.albumId);
  }

  /// Cover art once per album — nice-to-have next to the audio; failures are
  /// logged and forgotten.
  Future<void> _fetchArt(String albumId) async {
    final f = File('${_root!.path}/art/$albumId');
    if (f.existsSync()) return;
    try {
      final res = await ref.read(apiClientProvider).downloadArt(albumId);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(await res.stream.toBytes());
    } catch (e) {
      Log.w('downloads', 'art fetch failed for album $albumId', e);
    }
  }
}
