import 'dart:convert';
import 'dart:math';

import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection.dart';
import 'data_usage.dart';
import 'downloads.dart';
import 'eq.dart';
import 'log.dart';
import 'quality.dart';

const _prefsKeyQueue = 'aria.queue';
const _prefsKeyRadio = 'aria.radio';
const _prefsKeyExclusive = 'aria.audioExclusive';
const _prefsKeyEq = 'aria.eq';
const _prefsKeyEqCustom = 'aria.eq.custom';
const _prefsKeyEqFavourites = 'aria.eq.favourites';

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
    Log.i('settings', 'exclusive audio ${on ? 'on' : 'off'}');
    state = on;
    ref.read(ariaPlayerProvider).setAudioExclusive(on);
    await ref.read(sharedPrefsProvider).setBool(_prefsKeyExclusive, on);
  }
}

/// Headphone EQ selection: two independent layers (a headphone correction from
/// OPRA/a favourite, plus one custom preset) stacked into one mpv `af` chain,
/// persisted and pushed to the engine. Re-applied after init by
/// playerInitProvider, same as volume/exclusive.
final eqProvider = NotifierProvider<EqNotifier, EqState>(EqNotifier.new);

class EqState {
  const EqState({this.enabled = false, this.headphone, this.custom});

  final bool enabled;
  final EqProfile? headphone; // from OPRA (or a favourite)
  final EqProfile? custom; // one selected custom preset

  bool get active => enabled && (headphone != null || custom != null);
}

class EqNotifier extends Notifier<EqState> {
  @override
  EqState build() {
    final raw = ref.read(sharedPrefsProvider).getString(_prefsKeyEq);
    if (raw == null) return const EqState();
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      // Old flat shape (name/bands at top level, no layer keys) → headphone.
      if (!j.containsKey('headphone') && !j.containsKey('custom')) {
        return EqState(
          enabled: j['enabled'] == true,
          headphone: j['name'] == null ? null : EqProfile.fromJson(j),
        );
      }
      return EqState(
        enabled: j['enabled'] == true,
        headphone: _layer(j['headphone']),
        custom: _layer(j['custom']),
      );
    } catch (e) {
      Log.w('settings', 'corrupt eq prefs', e);
      return const EqState(); // corrupt entry — start clean
    }
  }

  static EqProfile? _layer(Object? j) =>
      j is Map<String, dynamic> ? EqProfile.fromJson(j) : null;

  /// Set/clear the headphone layer; enables when a layer remains, else leaves
  /// the master switch untouched (clearing the last layer just yields silence).
  void selectHeadphone(EqProfile? p) {
    Log.i('settings', 'eq headphone ${p?.name ?? 'off'}');
    _set(headphone: p, custom: state.custom);
  }

  /// Set/clear the custom layer; enable semantics as [selectHeadphone].
  void selectCustom(EqProfile? p) {
    Log.i('settings', 'eq custom ${p?.name ?? 'off'}');
    _set(headphone: state.headphone, custom: p);
  }

  void _set({required EqProfile? headphone, required EqProfile? custom}) {
    final hasLayer = headphone != null || custom != null;
    state = EqState(
      enabled: hasLayer ? true : state.enabled,
      headphone: headphone,
      custom: custom,
    );
    apply();
    _persist();
  }

  /// Replace the custom layer in place after an in-place edit, matching on the
  /// preset's *previous* name so a rename still re-points the slot (and its
  /// audio) to [edited]. Preserves the enabled flag — editing while off must
  /// not re-enable.
  void updateCustom(String previousName, EqProfile edited) {
    if (state.custom?.name != previousName) return;
    state = EqState(
      enabled: state.enabled,
      headphone: state.headphone,
      custom: edited,
    );
    apply();
    _persist();
  }

  void setEnabled(bool on) {
    Log.i('settings', 'eq ${on ? 'enabled' : 'disabled'}');
    state = EqState(
      enabled: on,
      headphone: state.headphone,
      custom: state.custom,
    );
    apply();
    _persist();
  }

  /// Push the current chain to the engine (also called post-init).
  void apply() {
    final p = state.enabled ? combineEq(state.headphone, state.custom) : null;
    ref.read(ariaPlayerProvider).setAudioFilter(p == null ? '' : eqToAf(p));
    // Setting `af` live reconfigures the open audio output and fails on some
    // devices (silent, skipping playback). Reload the current track in place so
    // the filter lands on a clean init; no-op at startup / when stopped.
    ref.read(queueProvider.notifier).reapplyForFilterChange();
  }

  void _persist() {
    ref.read(sharedPrefsProvider).setString(
          _prefsKeyEq,
          jsonEncode({
            'enabled': state.enabled,
            if (state.headphone != null) 'headphone': state.headphone!.toJson(),
            if (state.custom != null) 'custom': state.custom!.toJson(),
          }),
        );
  }
}

/// Decode/encode a prefs-backed `List<EqProfile>` (favourites, custom presets).
/// Corrupt or missing → empty; skips non-object entries.
List<EqProfile> _decodeEqList(String? raw) {
  if (raw == null) return const [];
  try {
    return [
      for (final j in jsonDecode(raw) as List)
        if (j is Map<String, dynamic>) EqProfile.fromJson(j),
    ];
  } catch (_) {
    return const [];
  }
}

String _encodeEqList(List<EqProfile> list) =>
    jsonEncode([for (final e in list) e.toJson()]);

/// Favourited OPRA curves (aria.eq.favourites) — self-contained named
/// [EqProfile]s so a favourite applies without waiting on the OPRA fetch.
/// Same storage shape as [customEqPresetsProvider].
final favouriteEqProvider =
    NotifierProvider<FavouriteEqNotifier, List<EqProfile>>(
      FavouriteEqNotifier.new,
    );

class FavouriteEqNotifier extends Notifier<List<EqProfile>> {
  @override
  List<EqProfile> build() => _decodeEqList(
        ref.read(sharedPrefsProvider).getString(_prefsKeyEqFavourites),
      );

  bool contains(String name) => state.any((p) => p.name == name);

  /// Add [p] if no entry shares its name, else remove that entry; persist.
  void toggle(EqProfile p) {
    state = contains(p.name ?? '')
        ? [for (final e in state) if (e.name != p.name) e]
        : [...state, p];
    ref
        .read(sharedPrefsProvider)
        .setString(_prefsKeyEqFavourites, _encodeEqList(state));
  }
}

/// User-authored EQ presets (aria.eq.custom); editing UI lives in settings.
final customEqPresetsProvider =
    NotifierProvider<CustomEqPresetsNotifier, List<EqProfile>>(
      CustomEqPresetsNotifier.new,
    );

class CustomEqPresetsNotifier extends Notifier<List<EqProfile>> {
  @override
  List<EqProfile> build() => _decodeEqList(
        ref.read(sharedPrefsProvider).getString(_prefsKeyEqCustom),
      );

  void set(List<EqProfile> presets) {
    state = presets;
    ref
        .read(sharedPrefsProvider)
        .setString(_prefsKeyEqCustom, _encodeEqList(presets));
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

/// The audio output in use (mpv current-ao). Drives the now-playing output
/// device readout.
final audioDeviceProvider = StreamProvider<String>(
  (ref) => ref.watch(ariaPlayerProvider).audioDevice,
);

final queueProvider = NotifierProvider<QueueNotifier, QueueState>(
  QueueNotifier.new,
);

/// One-shot user-facing playback notices (e.g. "Streaming disabled on
/// cellular"). TransportBar listens and shows a SnackBar — the same pathway
/// as audio errors. Each notice is a fresh instance (identity equality) so
/// repeating the same message still notifies.
final playbackNoticeProvider =
    NotifierProvider<PlaybackNoticeNotifier, PlaybackNotice?>(
      PlaybackNoticeNotifier.new,
    );

class PlaybackNotice {
  PlaybackNotice(this.message);

  final String message;
}

class PlaybackNoticeNotifier extends Notifier<PlaybackNotice?> {
  @override
  PlaybackNotice? build() => null;

  void show(String message) => state = PlaybackNotice(message);
}

/// Convenience: the playing (or paused) track, null when idle.
final currentTrackProvider = Provider<Track?>(
  (ref) => ref.watch(queueProvider).current,
);

/// Declaration order is the cycle order: off -> all -> one -> off.
enum LoopMode { off, all, one }

class QueueState {
  const QueueState({
    this.tracks = const [],
    this.index = -1,
    this.shuffle = false,
    this.loop = LoopMode.off,
  });

  final List<Track> tracks;

  /// Index of the current track, -1 when nothing is loaded. Tracks before it
  /// are "played history", after it are upcoming — legacy queue panel model.
  final int index;
  final bool shuffle;
  final LoopMode loop;

  Track? get current =>
      index >= 0 && index < tracks.length ? tracks[index] : null;

  QueueState copyWith({
    List<Track>? tracks,
    int? index,
    bool? shuffle,
    LoopMode? loop,
  }) => QueueState(
    tracks: tracks ?? this.tracks,
    index: index ?? this.index,
    shuffle: shuffle ?? this.shuffle,
    loop: loop ?? this.loop,
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
  int _engineBase = -1;

  /// App-queue index of the engine's queued-next entry, null when none.
  /// Repeat-one/wrap make advances non-linear, so the mapping is recorded
  /// instead of derived from base + n.
  int? _pendingAppIndex;

  bool get _enginePending => _pendingAppIndex != null;

  @override
  QueueState build() {
    final player = ref.read(ariaPlayerProvider);
    final endSub = player.ended.listen((_) => _onEnded());
    final startSub = player.trackStarted.listen(_onTrackStarted);
    ref.onDispose(endSub.cancel);
    ref.onDispose(startSub.cancel);
    // Keep the connectivity stream live so the data-usage gate reads a real
    // network kind (listen, not watch — network flips must not rebuild the
    // queue; an unlistened provider is paused in Riverpod 3). Network flips
    // re-evaluate the gapless queued-next, which is gated on data usage.
    ref.listen(networkKindProvider, (_, _) => _syncEngineNext());
    // A streaming-tier change re-drives the queued-next so the engine
    // prefetches the newly-selected tier (mirrors the networkKindProvider
    // listen — the tier is chosen by network kind at play time).
    ref.listen(qualityProvider, (_, _) => _syncEngineNext());
    // Downloads completing or being deleted flip a track between local and
    // stream — re-resolve the queued-next URL so it never points at a
    // deleted file (or keeps streaming a track that finished downloading).
    ref.listen(
      downloadsProvider.select((s) => s.index),
      (_, _) => _syncEngineNext(),
    );
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

  /// Advance; at the end of the queue wrap with loop all, else stop
  /// (legacy next()).
  void next() {
    if (state.index < state.tracks.length - 1) {
      state = state.copyWith(index: state.index + 1);
      _playCurrent();
    } else if (state.loop == LoopMode.all && state.tracks.isNotEmpty) {
      playAt(0);
    } else {
      Log.i('playback', 'stop (end of queue)');
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
    _pendingAppIndex = null;
    _persist();
  }

  /// Radio taking over: drop the queue WITHOUT stopping the engine — the
  /// station URL loads next (legacy playRadio queue=[]).
  void clearForRadio() {
    state = state.copyWith(tracks: const [], index: -1);
    _pendingAppIndex = null;
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

  /// Repeat off -> all -> one -> off. The gapless queued-next depends on the
  /// mode (repeat/wrap), so re-sync it.
  void cycleLoop() {
    state = state.copyWith(
      loop: LoopMode.values[(state.loop.index + 1) % LoopMode.values.length],
    );
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

  /// Re-init the current track in place at its position so an audio-filter (EQ)
  /// change lands via a clean load instead of a live `af` swap — the live swap
  /// reconfigures the open audio output and fails on some devices, racing the
  /// queue with no sound. No-op unless a library track is actively loaded (EQ
  /// applied at startup, when stopped, or over radio just sets the property).
  void reapplyForFilterChange() {
    if (state.current == null) return;
    final st = ref.read(playbackStateProvider).value;
    if (st != PlaybackState.playing && st != PlaybackState.paused) return;
    _playCurrent(startAt: ref.read(playbackPositionProvider).value ?? 0);
  }

  void _playCurrent({double startAt = 0}) {
    final t = state.current;
    if (t == null) return;
    // Data-usage gate: local downloads always play; streaming asks the
    // data-usage settings for the current network kind. Blocked = stay put
    // paused (never auto-skip through the queue burning data checks).
    final local = ref.read(localSourceResolverProvider)(t.id);
    final kind = ref.read(networkKindProvider).value ?? NetKind.other;
    if (local == null && !ref.read(dataUsageProvider).allowsStream(kind)) {
      Log.i('playback', 'stream blocked on ${kind.name} by data usage', t.id);
      ref
          .read(playbackNoticeProvider.notifier)
          .show(
            'Streaming disabled on '
            '${kind == NetKind.wifi ? 'Wi-Fi' : 'cellular'}',
          );
      _player.pause();
      // Callers advance state.index BEFORE calling; roll back to the track
      // the engine is still on so audio and UI agree (togglePlay would
      // otherwise resume the old track under the new title), and drop the
      // stale queued-next so the engine can't slide past the gate.
      if (_engineBase >= 0 && _engineBase < state.tracks.length) {
        state = state.copyWith(index: _engineBase);
      }
      _player.clearQueueNext();
      _pendingAppIndex = null;
      _persist();
      return;
    }
    Log.i('playback', 'start ${t.title ?? t.id}', t.id);
    // Any normal track leaves radio mode (legacy playCurrent radio = null).
    ref.read(radioPlaybackProvider.notifier).trackPlaybackStarted();
    _engineBase = state.index;
    _pendingAppIndex = null;
    // Server tag meta seeds the format badge until mpv reports the real
    // decoded audio-params (legacy player.js meta handshake).
    final tier = ref
        .read(qualityProvider)
        .streamTierFor(kind)
        .clamp(ref.read(transcodeAvailableProvider));
    _player.play(
      local ?? ref.read(apiClientProvider).streamUrl(t.id, tier: tier.wire),
      meta: TrackMeta(
        duration: t.duration,
        sampleRate: t.sampleRate,
        bits: t.bitsPerSample,
        channels: t.channels,
      ),
      startAt: startAt,
    );
    _persist();
    _syncEngineNext();
  }

  /// Keep the engine's queued-next in step with the app queue so natural
  /// transitions are gapless: the current track again on repeat-one, track 0
  /// past the end on repeat-all. No-op while the engine is idle.
  void _syncEngineNext() {
    final ni = switch (state.loop) {
      LoopMode.one => state.index,
      LoopMode.all when state.index == state.tracks.length - 1 => 0,
      _ => state.index + 1,
    };
    if (state.index >= 0 && ni < state.tracks.length) {
      final t = state.tracks[ni];
      final local = ref.read(localSourceResolverProvider)(t.id);
      // Same data-usage gate as _playCurrent: never pre-queue a stream the
      // gate would block. The advance then falls through _onEnded -> next()
      // -> _playCurrent, which blocks and shows the notice.
      final kind = ref.read(networkKindProvider).value ?? NetKind.other;
      if (local == null && !ref.read(dataUsageProvider).allowsStream(kind)) {
        _player.clearQueueNext();
        _pendingAppIndex = null;
        return;
      }
      final tier = ref
          .read(qualityProvider)
          .streamTierFor(kind)
          .clamp(ref.read(transcodeAvailableProvider));
      final ok = _player.queueNext(
        local ?? ref.read(apiClientProvider).streamUrl(t.id, tier: tier.wire),
      );
      _pendingAppIndex = ok ? ni : null;
    } else {
      _player.clearQueueNext();
      _pendingAppIndex = null;
    }
  }

  /// Engine playlist position changed — a manual load starting (base) or a
  /// gapless advance into the queued entry: move the app pointer without
  /// reloading. The pending mapping outranks base + n because repeat-one and
  /// wrap advance non-linearly.
  void _onTrackStarted(int enginePos) {
    final expected = _engineBase + enginePos;
    if (expected == state.index) return; // initial start of a manual load
    final pending = _pendingAppIndex;
    if (pending != null) {
      _engineBase = pending - enginePos;
      _pendingAppIndex = null;
      // Repeat-one lands on the same index; still persist and re-queue the
      // next repeat.
      state = state.copyWith(index: pending);
    } else {
      if (expected < 0 || expected >= state.tracks.length) return;
      state = state.copyWith(index: expected);
    }
    _persist();
    _syncEngineNext();
  }

  /// End-file(eof). With gapless wired the queued entry starts on its own and
  /// _onTrackStarted advances; this is the no-gapless fallback and the true
  /// end of the queue.
  void _onEnded() {
    // Stream drop is the radio notifier's business (one-shot reconnect).
    if (ref.read(radioPlaybackProvider) != null) return;
    if (_enginePending) return;
    if (state.loop == LoopMode.one) {
      _playCurrent();
    } else if (state.loop == LoopMode.off &&
        state.index >= state.tracks.length - 1) {
      _persist(); // end of queue — the engine idles on its own
    } else {
      next(); // no gapless entry was queued — hard advance / loop-all wrap
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
            'loop': state.loop.name,
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
    } catch (e) {
      Log.w('queue', 'restore failed: corrupt prefs', e);
      return;
    }
    final ids = (saved['ids'] as List?)?.cast<String>() ?? const [];
    final tracks = [for (final id in ids) byId(id)].nonNulls.toList();
    if (tracks.isEmpty) return;
    final i = ((saved['i'] as num?)?.toInt() ?? 0)
        .clamp(0, tracks.length - 1)
        .toInt();
    Log.i('queue', 'restored ${tracks.length} of ${ids.length} tracks');
    state = QueueState(
      tracks: tracks,
      index: i,
      shuffle: saved['shuffle'] == true,
      loop: LoopMode.values.asNameMap()[saved['loop']] ?? LoopMode.off,
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
      } catch (e) {
        Log.w('radio', 'corrupt station prefs', e);
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
