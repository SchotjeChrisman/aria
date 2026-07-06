import 'dart:convert';
import 'dart:math';

import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection.dart';

const _prefsKeyQueue = 'aria.queue';
const _prefsKeyRadio = 'aria.radio';
const _prefsKeyExclusive = 'aria.audioExclusive';

/// Single engine instance for the app's lifetime. The persisted exclusive
/// flag is passed to the constructor so --audio-exclusive is set before
/// mpv_initialize — the bit-perfect path survives restarts.
final ariaPlayerProvider = Provider<AriaPlayer>((ref) {
  final exclusive =
      ref.read(sharedPrefsProvider).getBool(_prefsKeyExclusive) ?? false;
  final player = AriaPlayer(audioExclusive: exclusive);
  ref.onDispose(player.dispose);
  return player;
});

/// Desktop bit-perfect hog-the-device toggle (legacy cfg.exclusive →
/// mpv --audio-exclusive). Persisted app-side; pushed to the engine live and
/// re-applied after initialize() by playerInitProvider.
final audioExclusiveProvider = NotifierProvider<AudioExclusiveNotifier, bool>(
  AudioExclusiveNotifier.new,
);

class AudioExclusiveNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.read(sharedPrefsProvider).getBool(_prefsKeyExclusive) ?? false;

  Future<void> set(bool on) async {
    state = on;
    ref.read(ariaPlayerProvider).setAudioExclusive(on);
    await ref.read(sharedPrefsProvider).setBool(_prefsKeyExclusive, on);
  }
}

final playbackStateProvider = StreamProvider<PlaybackState>(
  (ref) => ref.watch(ariaPlayerProvider).state,
);

/// Position in seconds of the current track.
final playbackPositionProvider = StreamProvider<double>(
  (ref) => ref.watch(ariaPlayerProvider).position,
);

/// What the engine is actually decoding/outputting — drives the signal path
/// and bit-perfect badge in now-playing.
final playbackFormatProvider = StreamProvider<AudioFormat>(
  (ref) => ref.watch(ariaPlayerProvider).format,
);

final queueProvider = NotifierProvider<QueueNotifier, QueueState>(
  QueueNotifier.new,
);

/// Convenience: the playing (or paused) track, null when idle.
final currentTrackProvider = Provider<Track?>(
  (ref) => ref.watch(queueProvider).current,
);

class QueueState {
  const QueueState({
    this.tracks = const [],
    this.index = -1,
    this.shuffle = false,
  });

  final List<Track> tracks;

  /// Index of the current track, -1 when nothing is loaded. Tracks before it
  /// are "played history", after it are upcoming — legacy queue panel model.
  final int index;
  final bool shuffle;

  Track? get current =>
      index >= 0 && index < tracks.length ? tracks[index] : null;

  QueueState copyWith({List<Track>? tracks, int? index, bool? shuffle}) =>
      QueueState(
        tracks: tracks ?? this.tracks,
        index: index ?? this.index,
        shuffle: shuffle ?? this.shuffle,
      );
}

/// Play-queue semantics ported from legacy app.js (playQueue/queueNext/
/// queueAdd/next/prev/qMove/qRemove). The queue lives in the app; the engine
/// additionally holds the NEXT track's URL (AriaPlayer.queueNext) so natural
/// track transitions are gapless — mpv prefetches and crossfeeds the demuxer
/// without a loadfile round-trip. trackStarted advances the app index;
/// `ended` only matters at the end of the queue (or as a fallback when no
/// gapless entry was queued).
class QueueNotifier extends Notifier<QueueState> {
  /// App-queue index that the engine's playlist entry 0 maps to; gapless
  /// advances arrive as engine playlist positions (base + n).
  int _engineBase = 0;

  /// Whether the engine currently holds a queued-next entry.
  bool _enginePending = false;

  @override
  QueueState build() {
    final player = ref.read(ariaPlayerProvider);
    final endSub = player.ended.listen((_) => _onEnded());
    final startSub = player.trackStarted.listen(_onTrackStarted);
    ref.onDispose(endSub.cancel);
    ref.onDispose(startSub.cancel);
    return const QueueState();
  }

  AriaPlayer get _player => ref.read(ariaPlayerProvider);

  // -------------------------------------------------------------- building

  /// Replace the queue and start at [index] (legacy playQueue).
  void playQueue(List<Track> list, int index) {
    state = state.copyWith(tracks: List.of(list), index: index);
    if (state.shuffle) _shuffleUpcoming();
    _playCurrent();
  }

  /// Insert after the current track; start playing if idle (legacy queueNext).
  void queueNext(List<Track> list) {
    if (state.current == null) return playQueue(list, 0);
    final tracks = List.of(state.tracks)..insertAll(state.index + 1, list);
    state = state.copyWith(tracks: tracks);
    _persist();
    _syncEngineNext();
  }

  /// Append at the end; start playing if idle (legacy queueAdd).
  void queueAdd(List<Track> list) {
    if (state.current == null) return playQueue(list, 0);
    state = state.copyWith(tracks: [...state.tracks, ...list]);
    _persist();
    _syncEngineNext();
  }

  // -------------------------------------------------------------- transport

  void playAt(int i) {
    if (i < 0 || i >= state.tracks.length) return;
    state = state.copyWith(index: i);
    _playCurrent();
  }

  /// Advance; at the end of the queue just stop (legacy next()).
  void next() {
    if (state.index < state.tracks.length - 1) {
      state = state.copyWith(index: state.index + 1);
      _playCurrent();
    } else {
      _player.stop();
      _persist();
    }
  }

  /// Legacy prev(): >3s into the track (or already first) restarts it,
  /// otherwise steps back.
  void prev() {
    final pos = ref.read(playbackPositionProvider).value ?? 0;
    if (pos > 3 || state.index <= 0) {
      _player.seek(0);
    } else {
      state = state.copyWith(index: state.index - 1);
      _playCurrent();
    }
  }

  void togglePlay() {
    switch (ref.read(playbackStateProvider).value) {
      case PlaybackState.playing:
        _player.pause();
      case PlaybackState.paused:
        _player.resume();
      default:
        if (state.current != null) {
          _playCurrent();
        } else {
          // Stopped stream with a station on the bar: reconnect (legacy
          // togglePlay `else if (radio) playRadio(radio)`).
          final st = ref.read(radioPlaybackProvider);
          if (st != null) ref.read(radioPlaybackProvider.notifier).play(st);
        }
    }
  }

  // -------------------------------------------------------------- editing

  /// Move [indices] so the block starts at [dest] (insertion index in the
  /// pre-move list). Current-track pointer follows by position, so duplicate
  /// tracks stay correct — ported verbatim from legacy qMove.
  void move(List<int> indices, int dest) {
    final set = indices.toSet();
    final items = [
      for (var i = 0; i < state.tracks.length; i++) (t: state.tracks[i], i: i),
    ];
    final rest = items.where((x) => !set.contains(x.i)).toList();
    final moved = items.where((x) => set.contains(x.i)).toList();
    final at = dest - indices.where((i) => i < dest).length;
    rest.insertAll(at.clamp(0, rest.length).toInt(), moved);
    final newIndex = rest.indexWhere((x) => x.i == state.index);
    state = state.copyWith(
      tracks: [for (final x in rest) x.t],
      index: newIndex,
    );
    _persist();
    _syncEngineNext();
  }

  /// Legacy qRemove: removing the playing track slides the next one into its
  /// slot and plays it, or stops at the end of the queue.
  void removeIndices(List<int> indices) {
    final set = indices.toSet();
    final wasCurrent = set.contains(state.index);
    final before = indices.where((i) => i < state.index).length;
    final tracks = [
      for (var i = 0; i < state.tracks.length; i++)
        if (!set.contains(i)) state.tracks[i],
    ];
    var index = state.index - before;
    if (!wasCurrent) {
      state = state.copyWith(tracks: tracks, index: index);
      _persist();
      _syncEngineNext();
      return;
    }
    if (index < tracks.length) {
      state = state.copyWith(tracks: tracks, index: index);
      _playCurrent();
    } else {
      state = state.copyWith(tracks: tracks, index: tracks.length - 1);
      _player.stop();
      _persist();
    }
  }

  void clear() {
    state = state.copyWith(tracks: const [], index: -1);
    _player.stop();
    _enginePending = false;
    _persist();
  }

  /// Radio taking over: drop the queue WITHOUT stopping the engine — the
  /// station URL loads next (legacy playRadio queue=[]).
  void clearForRadio() {
    state = state.copyWith(tracks: const [], index: -1);
    _enginePending = false;
    _persist();
  }

  /// Legacy had no shuffle; minimal semantics: turning it on shuffles the
  /// upcoming tracks once (history and current stay put), turning it off
  /// just clears the flag — no unshuffle.
  void toggleShuffle() {
    state = state.copyWith(shuffle: !state.shuffle);
    if (state.shuffle) _shuffleUpcoming();
    _persist();
    _syncEngineNext();
  }

  void _shuffleUpcoming() {
    final from = state.index + 1;
    if (from >= state.tracks.length - 1) return;
    final tracks = List.of(state.tracks);
    final upcoming = tracks.sublist(from)..shuffle(Random());
    tracks.replaceRange(from, tracks.length, upcoming);
    state = state.copyWith(tracks: tracks);
  }

  // -------------------------------------------------------------- internals

  void _playCurrent() {
    final t = state.current;
    if (t == null) return;
    // Any normal track leaves radio mode (legacy playCurrent radio = null).
    ref.read(radioPlaybackProvider.notifier).trackPlaybackStarted();
    _engineBase = state.index;
    _enginePending = false;
    // Server tag meta seeds the format badge until mpv reports the real
    // decoded audio-params (legacy player.js meta handshake).
    _player.play(
      ref.read(apiClientProvider).streamUrl(t.id),
      meta: TrackMeta(
        duration: t.duration,
        sampleRate: t.sampleRate,
        bits: t.bitsPerSample,
        channels: t.channels,
      ),
    );
    _persist();
    _syncEngineNext();
  }

  /// Keep the engine's queued-next in step with the app queue so natural
  /// transitions are gapless. No-op while the engine is idle.
  void _syncEngineNext() {
    final ni = state.index + 1;
    if (state.index >= 0 && ni < state.tracks.length) {
      final t = state.tracks[ni];
      _enginePending = _player.queueNext(
        ref.read(apiClientProvider).streamUrl(t.id),
      );
    } else {
      _player.clearQueueNext();
      _enginePending = false;
    }
  }

  /// Engine playlist position changed — a manual load starting (base) or a
  /// gapless advance (base + n): move the app pointer without reloading.
  void _onTrackStarted(int enginePos) {
    final expected = _engineBase + enginePos;
    if (expected == state.index) return; // initial start of a manual load
    if (expected < 0 || expected >= state.tracks.length) return;
    state = state.copyWith(index: expected);
    _persist();
    _syncEngineNext();
  }

  /// End-file(eof). With gapless wired this only matters at the end of the
  /// queue; mid-queue the queued entry starts and _onTrackStarted advances.
  void _onEnded() {
    // Stream drop is the radio notifier's business (one-shot reconnect).
    if (ref.read(radioPlaybackProvider) != null) return;
    if (state.index >= state.tracks.length - 1) {
      _persist(); // end of queue — the engine idles on its own
    } else if (!_enginePending) {
      next(); // no gapless entry was queued — hard advance as fallback
    }
  }

  // ---------------------------------------------------------- persistence
  // Legacy: aria.queue in localStorage = {ids, i}; here shared_preferences.
  // Only ids persist — restore() rehydrates against the loaded library.

  void _persist() {
    ref
        .read(sharedPrefsProvider)
        .setString(
          _prefsKeyQueue,
          jsonEncode({
            'ids': [for (final t in state.tracks) t.id],
            'i': state.index,
            'shuffle': state.shuffle,
          }),
        );
  }

  /// Rehydrate the saved queue once the library is loaded. Unknown ids are
  /// dropped (legacy behavior). Playback does NOT start — it resumes on
  /// demand, matching legacy restorePlayback without a live engine.
  void restore(Track? Function(String id) byId) {
    // Never clobber a queue the user already built this session (the library
    // provider re-fires on refresh; restore is first-load-only).
    if (state.tracks.isNotEmpty) return;
    final raw = ref.read(sharedPrefsProvider).getString(_prefsKeyQueue);
    if (raw == null) return;
    Map<String, dynamic> saved;
    try {
      saved = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final ids = (saved['ids'] as List?)?.cast<String>() ?? const [];
    final tracks = [for (final id in ids) byId(id)].nonNulls.toList();
    if (tracks.isEmpty) return;
    final i = ((saved['i'] as num?)?.toInt() ?? 0)
        .clamp(0, tracks.length - 1)
        .toInt();
    state = QueueState(
      tracks: tracks,
      index: i,
      shuffle: saved['shuffle'] == true,
    );
  }
}

// ------------------------------------------------------------------- radio
// Live streams ride the same native player path (legacy playRadio): no web
// audio, no seek, no skip, no play logging. Owned by core so the transport
// bar (now_playing) and the radio feature share one source of truth.

/// The station currently on air, null when library playback owns the engine.
/// Survives restarts via prefs: the station reappears on the transport with
/// playback resumable via play (the stream itself cannot outlive the app).
final radioPlaybackProvider =
    NotifierProvider<RadioPlaybackNotifier, RadioStation?>(
      RadioPlaybackNotifier.new,
    );

class RadioPlaybackNotifier extends Notifier<RadioStation?> {
  /// One reconnect attempt per drop (legacy radioRetried).
  bool _retried = false;

  @override
  RadioStation? build() {
    final sub = ref
        .read(ariaPlayerProvider)
        .ended
        .listen((_) => _onStreamEnded());
    ref.onDispose(sub.cancel);
    final raw = ref.read(sharedPrefsProvider).getString(_prefsKeyRadio);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        return RadioStation(
          id: j['id'] as String,
          name: j['name'] as String,
          url: j['url'] as String,
        );
      } catch (_) {
        // corrupt entry — start clean
      }
    }
    return null;
  }

  void play(RadioStation st) {
    // Legacy playRadio: queue = [], then stream the URL directly. No meta:
    // live streams report their own format.
    ref.read(queueProvider.notifier).clearForRadio();
    _retried = false;
    ref.read(ariaPlayerProvider).play(st.url);
    state = st;
    ref
        .read(sharedPrefsProvider)
        .setString(
          _prefsKeyRadio,
          jsonEncode({'id': st.id, 'name': st.name, 'url': st.url}),
        );
  }

  void stop() {
    if (state == null) return;
    ref.read(ariaPlayerProvider).stop();
    state = null;
    ref.read(sharedPrefsProvider).remove(_prefsKeyRadio);
  }

  /// Library playback taking over ends radio mode (legacy playCurrent).
  void trackPlaybackStarted() {
    if (state == null) return;
    state = null;
    ref.read(sharedPrefsProvider).remove(_prefsKeyRadio);
  }

  /// Stream dropped: one reconnect attempt, then stay stopped with the
  /// station still on the bar (legacy onEnded radio branch).
  void _onStreamEnded() {
    final st = state;
    if (st == null) return;
    if (!_retried) {
      _retried = true;
      ref.read(ariaPlayerProvider).play(st.url);
    }
  }
}
