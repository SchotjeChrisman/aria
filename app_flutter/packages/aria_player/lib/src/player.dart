import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'mpv_constants.dart';
import 'mpv_ffi.dart';
import 'mpv_raw.dart';

enum PlaybackState { stopped, playing, paused }

/// Server-supplied source metadata (same shape as legacy player.js meta).
class TrackMeta {
  const TrackMeta({this.duration, this.sampleRate, this.bits, this.channels});

  final double? duration;
  final int? sampleRate;
  final int? bits;
  final int? channels;
}

/// Audio format for the UI badge. [sampleRate]/[bitDepth] are the *decoded*
/// stream (mpv `audio-params`, or server meta before decode starts).
/// [outSampleRate]/[outBitDepth] are what mpv actually sends to the audio
/// device (`audio-out-params`) after any resampling it does — the honest
/// bit-perfect story, and the deepest into the chain the platform lets us see
/// (an OS layer below mpv, e.g. Android AudioFlinger, can still resample
/// invisibly).
@immutable
class AudioFormat {
  const AudioFormat({
    this.sampleRate,
    this.channels,
    this.sampleFormat,
    this.bitDepth,
    this.outSampleRate,
    this.outBitDepth,
  });

  final int? sampleRate;
  final int? channels;

  /// mpv sample format string, e.g. "s16", "s32", "float". Null when the
  /// value came from server meta.
  final String? sampleFormat;
  final int? bitDepth;

  /// The format mpv hands to the audio output (`audio-out-params`). Null until
  /// an output is initialised.
  final int? outSampleRate;
  final int? outBitDepth;

  @override
  bool operator ==(Object other) =>
      other is AudioFormat &&
      other.sampleRate == sampleRate &&
      other.channels == channels &&
      other.sampleFormat == sampleFormat &&
      other.bitDepth == bitDepth &&
      other.outSampleRate == outSampleRate &&
      other.outBitDepth == outBitDepth;

  @override
  int get hashCode => Object.hash(
    sampleRate,
    channels,
    sampleFormat,
    bitDepth,
    outSampleRate,
    outBitDepth,
  );

  @override
  String toString() =>
      'AudioFormat(${sampleRate}Hz, ${channels}ch, ${sampleFormat ?? 'meta'}, '
      '${bitDepth}bit → out ${outSampleRate}Hz ${outBitDepth}bit)';
}

int? _bitDepthFromSampleFormat(String? fmt) {
  if (fmt == null) return null;
  if (fmt.startsWith('float')) return 32;
  if (fmt.startsWith('double')) return 64;
  final digits = RegExp(r'\d+').firstMatch(fmt);
  return digits == null ? null : int.parse(digits.group(0)!);
}

/// Native bit-perfect playback facade over libmpv, mirroring the semantics
/// of legacy app/player.js (mpv JSON-IPC engine) plus gapless queue-next.
///
/// If libmpv cannot be loaded the player degrades to an inert object:
/// [isAvailable] is false, [unavailableReason] explains why, every command
/// is a no-op, and the app keeps running.
class AriaPlayer {
  AriaPlayer({
    MpvRaw Function()? rawFactory,
    this.audioExclusive = false,
    this.pollInterval = const Duration(milliseconds: 50),
  }) : _rawFactory = rawFactory ?? FfiMpvRaw.load;

  /// Desktop-only hog-the-device toggle (--audio-exclusive).
  final bool audioExclusive;
  final Duration pollInterval;
  final MpvRaw Function() _rawFactory;

  /// Poll cadence while the core is stopped/idle: no time-pos ticks arrive,
  /// so draining at [pollInterval] just burns CPU. play() restores the fast
  /// poll immediately; state changes keep it in sync otherwise.
  static const _idlePollInterval = Duration(milliseconds: 500);

  MpvRaw? _raw;
  int _handle = 0;
  Timer? _timer;
  Duration? _timerInterval;
  String? _unavailableReason;
  bool _disposed = false;

  // Playback bookkeeping.
  PlaybackState _state = PlaybackState.stopped;
  double _position = 0;
  double? _duration;
  bool _fileActive = false;
  bool _pausedProp = false;
  int _playlistPos = -1;
  int _localPlaylistCount = 0;
  int? _pendingNextIndex;

  /// True between a loadfile issued by [play] and its START_FILE. The event
  /// controllers are sync, so listeners of [ended] may call [play] while the
  /// poll loop is still draining — a stale IDLE queued before our loadfile
  /// took effect must not clobber the fresh playlist bookkeeping or emit a
  /// transient stopped state (play-button flicker on every auto-advance).
  bool _loadPending = false;

  /// One [audioError] per load: mpv retries a failed audio output in a tight
  /// loop, logging the same error each time.
  bool _aoErrorNotified = false;

  // No-sound safety net: an ao that fails to init makes mpv EOF straight
  // through the queue with no playback. Track the furthest position reached
  // per file; a sub-0.5s EOF means the file produced no sound.
  double _maxPosThisFile = 0;
  String? _lastErrorText;
  String? _audioDevice;

  /// Absolute position to seek to once the (reloaded) file starts. Set by
  /// [play]'s startAt so an EQ change can reload the current file cleanly (a
  /// live `af` swap reconfigures the open output and fails on some devices)
  /// without losing the listener's spot.
  double? _pendingSeek;

  /// Sticky stop after dead audio: mpv may have already prefetched the next
  /// gapless entry, so its START_FILE/advance events are still queued. Swallow
  /// every event until the next explicit [play] re-arms, so a silent output
  /// can never race the queue.
  bool _deadStopped = false;

  /// User's desired exclusive-output state, tracked so setAudioFilter can
  /// force it off while an EQ filter is active (desktop only) and restore it.
  bool _exclusiveIntent = false;

  TrackMeta? _meta;
  int? _fmtRate;
  int? _fmtChannels;
  String? _fmtSampleFormat;
  int? _outRate;
  String? _outSampleFormat;

  final _positionCtrl = StreamController<double>.broadcast(sync: true);
  final _durationCtrl = StreamController<double>.broadcast(sync: true);
  final _stateCtrl = StreamController<PlaybackState>.broadcast(sync: true);
  final _endedCtrl = StreamController<void>.broadcast(sync: true);
  final _formatCtrl = StreamController<AudioFormat>.broadcast(sync: true);
  final _trackStartedCtrl = StreamController<int>.broadcast(sync: true);
  final _audioErrorCtrl = StreamController<String>.broadcast(sync: true);
  final _audioDeviceCtrl = StreamController<String>.broadcast(sync: true);

  /// Seconds into the current track.
  Stream<double> get position => _positionCtrl.stream;

  /// Track duration in seconds, as reported by mpv.
  Stream<double> get duration => _durationCtrl.stream;

  Stream<PlaybackState> get state => _stateCtrl.stream;

  /// Fires once per track that plays to its natural end (end-file/eof).
  Stream<void> get ended => _endedCtrl.stream;

  Stream<AudioFormat> get format => _formatCtrl.stream;

  /// Playlist index each time a (possibly gapless-queued) entry starts.
  Stream<int> get trackStarted => _trackStartedCtrl.stream;

  /// Fires (with mpv's message) when the audio output fails during playback —
  /// e.g. exclusive access denied because another stream holds the device.
  /// Playback is stopped first: without an ao, mpv silently races through
  /// the track instead of playing it.
  Stream<String> get audioError => _audioErrorCtrl.stream;

  /// The audio output currently in use (mpv current-ao), e.g. "pipewire",
  /// "coreaudio", "wasapi". Empty until playback initialises an output.
  Stream<String> get audioDevice => _audioDeviceCtrl.stream;

  PlaybackState get currentState => _state;
  double get currentPosition => _position;
  double? get currentDuration => _duration;
  String? get currentAudioDevice => _audioDevice;
  TrackMeta? get currentMeta => _meta;

  bool get isAvailable => _handle != 0 && !_disposed;
  String? get unavailableReason => _unavailableReason;

  /// Loads libmpv, creates and configures the handle, starts event polling.
  /// Never throws for a missing library — check [isAvailable] afterwards.
  Future<void> initialize() async {
    if (_handle != 0 || _disposed) return;
    final MpvRaw raw;
    try {
      raw = _rawFactory();
    } on PlayerUnavailableException catch (e) {
      _unavailableReason = e.message;
      return;
    } catch (e) {
      _unavailableReason = 'libmpv failed to load: $e';
      return;
    }

    final handle = raw.create();
    if (handle == 0) {
      _unavailableReason = 'mpv_create failed (check LC_NUMERIC locale)';
      return;
    }

    // Options must precede mpv_initialize. Audio-only, gapless, idle core —
    // same posture as legacy mpv engine (--idle --no-video).
    raw.setOptionString(handle, 'vid', 'no');
    raw.setOptionString(handle, 'audio-display', 'no');
    raw.setOptionString(handle, 'idle', 'yes');
    raw.setOptionString(handle, 'keep-open', 'no');
    raw.setOptionString(handle, 'gapless-audio', 'yes');
    // Open the next queued URL before the current one ends so gapless works
    // over HTTP streams from the aria server, not just local files.
    raw.setOptionString(handle, 'prefetch-playlist', 'yes');
    raw.setOptionString(handle, 'volume-max', '100');
    // ponytail: audio-exclusive is desktop-only bit-perfect; on Android the
    // OS mixer (AudioTrack/AAudio) may still resample after our lossless
    // decode — true bit-perfect there needs a USB DAC on Android 14+.
    if (!Platform.isAndroid) {
      raw.setOptionString(
        handle,
        'audio-exclusive',
        audioExclusive ? 'yes' : 'no',
      );
    }

    final rc = raw.initialize(handle);
    if (rc < 0) {
      raw.terminateDestroy(handle);
      _unavailableReason = 'mpv_initialize failed (error $rc)';
      return;
    }

    raw.observeProperty(handle, 1, 'time-pos', MpvFormat.doubleValue);
    raw.observeProperty(handle, 2, 'duration', MpvFormat.doubleValue);
    raw.observeProperty(handle, 3, 'pause', MpvFormat.flag);
    raw.observeProperty(handle, 4, 'playlist-pos', MpvFormat.int64);
    raw.observeProperty(handle, 5, 'audio-params/samplerate', MpvFormat.int64);
    raw.observeProperty(handle, 6, 'audio-params/format', MpvFormat.string);
    raw.observeProperty(
      handle,
      7,
      'audio-params/channel-count',
      MpvFormat.int64,
    );
    raw.observeProperty(handle, 8, 'current-ao', MpvFormat.string);
    // What actually reaches the audio device after mpv's own resampling —
    // the honest output leg for the signal path.
    raw.observeProperty(handle, 9, 'audio-out-params/samplerate', MpvFormat.int64);
    raw.observeProperty(handle, 10, 'audio-out-params/format', MpvFormat.string);

    // Surface audio-output failures (see [audioError]).
    raw.requestLogMessages(handle, 'error');

    _exclusiveIntent = audioExclusive;
    _raw = raw;
    _handle = handle;
    _syncPollRate();
  }

  /// Fast poll whenever a file is (about to be) active, slow poll when the
  /// core idles — event delivery during playback and track transitions is
  /// untouched (state stays playing across gapless advances).
  void _syncPollRate() {
    if (_disposed || _handle == 0) return;
    final idle = _state == PlaybackState.stopped && !_loadPending;
    final want = idle ? _idlePollInterval : pollInterval;
    if (_timer != null && want == _timerInterval) return;
    _timer?.cancel();
    _timerInterval = want;
    _timer = Timer.periodic(want, (_) => _poll());
  }

  /// Replace the playlist with [url] and start playing. [startAt] resumes at a
  /// position once the file starts — used to reload the current track in place
  /// after an EQ change without losing the listener's spot.
  void play(String url, {TrackMeta? meta, double startAt = 0}) {
    if (!isAvailable) return;
    _meta = meta;
    _pendingSeek = startAt > 0 ? startAt : null;
    _deadStopped = false;
    _playlistPos = -1;
    _localPlaylistCount = 1;
    _pendingNextIndex = null;
    _loadPending = true;
    _syncPollRate(); // back to the fast poll before START_FILE arrives
    _aoErrorNotified = false;
    _fmtRate = null;
    _fmtChannels = null;
    _fmtSampleFormat = null;
    _outRate = null;
    _outSampleFormat = null;
    _raw!.command(_handle, ['loadfile', url, 'replace']);
    _raw!.setPropertyString(_handle, 'pause', 'no');
    if (meta != null) {
      _formatCtrl.add(
        AudioFormat(
          sampleRate: meta.sampleRate,
          channels: meta.channels,
          bitDepth: meta.bits,
        ),
      );
    }
  }

  /// Append [url] after the current track for gapless transition. Calling
  /// again before the queued track starts replaces the previous queue-next.
  /// Returns false when nothing is playing (the engine playlist is empty).
  bool queueNext(String url) {
    if (!isAvailable || _localPlaylistCount == 0) return false;
    final pending = _pendingNextIndex;
    if (pending != null && pending > _playlistPos) {
      _raw!.command(_handle, ['playlist-remove', '$pending']);
      _localPlaylistCount--;
    }
    _raw!.command(_handle, ['loadfile', url, 'append']);
    _pendingNextIndex = _localPlaylistCount;
    _localPlaylistCount++;
    return true;
  }

  /// Drop a not-yet-started queued-next entry (the upcoming track changed
  /// or the queue now ends after the current track).
  void clearQueueNext() {
    if (!isAvailable) return;
    final pending = _pendingNextIndex;
    if (pending != null && pending > _playlistPos) {
      _raw!.command(_handle, ['playlist-remove', '$pending']);
      _localPlaylistCount--;
    }
    _pendingNextIndex = null;
  }

  /// State is emitted when mpv's observed `pause` property confirms, same
  /// as the legacy IPC engine.
  void pause() {
    if (!isAvailable) return;
    _raw!.setPropertyString(_handle, 'pause', 'yes');
  }

  void resume() {
    if (!isAvailable) return;
    _raw!.setPropertyString(_handle, 'pause', 'no');
  }

  void stop() {
    if (!isAvailable) return;
    _loadPending = false; // an explicit stop outranks any in-flight load
    _raw!.command(_handle, ['stop']);
    _setState(PlaybackState.stopped);
  }

  /// Stop on dead audio (a silent EOF or an ao failure) and stay stopped:
  /// drop any prefetched gapless entry and swallow the already-queued advance
  /// events for it, so the queue can never race through producing no sound.
  void _deadAudioStop(String message) {
    clearQueueNext();
    _deadStopped = true;
    stop();
    _audioErrorCtrl.add(message);
  }

  /// Absolute seek in seconds.
  void seek(double seconds) {
    if (!isAvailable) return;
    final s = seconds < 0 ? 0.0 : seconds;
    _raw!.command(_handle, ['seek', '$s', 'absolute']);
  }

  /// 0–100, clamped (matches legacy player.js).
  void setVolume(double volume) {
    if (!isAvailable) return;
    _raw!.setPropertyDouble(_handle, 'volume', volume.clamp(0, 100));
  }

  /// Replace the mpv audio filter chain ('' clears it) — the EQ hook. Callers
  /// that change this mid-playback should reload the current file afterwards
  /// (see QueueNotifier.reapplyForFilterChange): a live `af` swap reconfigures
  /// the open output and fails on some devices.
  void setAudioFilter(String af) {
    if (!isAvailable) return;
    // Exclusive off must land BEFORE the filter: the af change reconfigures the
    // audio output, which fails against a held (exclusive) device. EQ and
    // bit-perfect exclusive output are mutually exclusive; clearing the filter
    // restores the user's intent. Desktop-only — a no-op on Android.
    if (!Platform.isAndroid) {
      _raw!.setPropertyString(
        _handle,
        'audio-exclusive',
        af.isNotEmpty ? 'no' : (_exclusiveIntent ? 'yes' : 'no'),
      );
    }
    _raw!.setPropertyString(_handle, 'af', af);
  }

  /// Runtime toggle for exclusive device access (desktop).
  void setAudioExclusive(bool on) {
    _exclusiveIntent = on;
    if (!isAvailable || Platform.isAndroid) return;
    _raw!.setPropertyString(_handle, 'audio-exclusive', on ? 'yes' : 'no');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    if (_handle != 0) {
      _raw!.terminateDestroy(_handle);
      _handle = 0;
    }
    await _positionCtrl.close();
    await _durationCtrl.close();
    await _stateCtrl.close();
    await _endedCtrl.close();
    await _formatCtrl.close();
    await _trackStartedCtrl.close();
    await _audioErrorCtrl.close();
    await _audioDeviceCtrl.close();
  }

  /// Drains pending mpv events now — what the poll timer does each tick.
  @visibleForTesting
  void debugPoll() => _poll();

  void _poll() {
    final raw = _raw;
    if (raw == null || _handle == 0 || _disposed) return;
    // Cap the drain so a flood of events can never starve the UI thread.
    for (var i = 0; i < 128; i++) {
      final ev = raw.waitEvent(_handle, 0);
      if (ev == null) break;
      _handleEvent(ev);
    }
  }

  void _handleEvent(MpvEventData ev) {
    // Sticky dead-audio stop: once we stop for no-sound, mpv's already-queued
    // events for a prefetched gapless entry (START_FILE/playlist-pos) would
    // otherwise un-stop us and advance the queue. Swallow everything until the
    // next explicit play() clears the flag.
    if (_deadStopped) {
      if (ev.eventId == MpvEventId.shutdown) {
        _timer?.cancel();
        _timer = null;
        _timerInterval = null;
      }
      return;
    }
    switch (ev.eventId) {
      case MpvEventId.propertyChange:
        _handleProperty(ev.propertyName, ev.propertyValue);
      case MpvEventId.startFile:
        _fileActive = true;
        _loadPending = false;
        _maxPosThisFile = 0;
        _setState(_pausedProp ? PlaybackState.paused : PlaybackState.playing);
        // Resume at the saved spot after an in-place reload (EQ change).
        final seekTo = _pendingSeek;
        if (seekTo != null) {
          _pendingSeek = null;
          seek(seekTo);
        }
      case MpvEventId.endFile:
        if (ev.endFileReason == MpvEndFileReason.eof) {
          // No-sound safety net: a file that never reached 0.5s produced no
          // sound. Only stop when a gapless entry is prefetched — that is the
          // race we must not blow through (mpv would auto-advance into it). A
          // lone dead EOF (radio drop, single/last track) falls through to the
          // normal end so radio can reconnect and the queue ends cleanly.
          // ponytail: 0.5s is a heuristic; real music tracks are never
          // sub-0.5s. Loosen only on a false stop.
          if (_maxPosThisFile < 0.5 && _pendingNextIndex != null) {
            _deadAudioStop(
              _lastErrorText?.isNotEmpty == true
                  ? _lastErrorText!
                  : 'Audio output produced no sound — playback stopped.',
            );
            return;
          }
          _endedCtrl.add(null);
        }
      case MpvEventId.logMessage:
        _handleLogMessage(ev.logPrefix, ev.logText);
      case MpvEventId.idle:
        // Idle core == nothing left to play (mpv without keep-open never
        // reports eof-reached; end-file/idle is the reliable stop signal).
        // A stale idle raced against a fresh loadfile is discarded — see
        // _loadPending.
        if (_loadPending) break;
        _fileActive = false;
        _playlistPos = -1;
        _localPlaylistCount = 0;
        _pendingNextIndex = null;
        _setState(PlaybackState.stopped);
      case MpvEventId.shutdown:
        _timer?.cancel();
        _timer = null;
        _timerInterval = null;
      default:
        break;
    }
  }

  /// Error-level mpv log lines (requestLogMessages 'error'). An `ao`-prefixed
  /// error while a file is active means the output is broken; stop instead of
  /// letting mpv race through the queue silently.
  void _handleLogMessage(String? prefix, String? text) {
    // Remember the last error text regardless of prefix so the no-sound
    // safety net can surface the real mpv error (see endFile eof handling).
    _lastErrorText = (text ?? '').trim();
    if (prefix == null || !prefix.startsWith('ao')) return;
    if (_aoErrorNotified || (!_fileActive && !_loadPending)) return;
    _aoErrorNotified = true;
    _deadAudioStop((text ?? 'audio output error').trim());
  }

  void _handleProperty(String? name, Object? value) {
    switch (name) {
      case 'time-pos':
        if (value is double) {
          _position = value;
          if (value > _maxPosThisFile) _maxPosThisFile = value;
          _positionCtrl.add(value);
        }
      case 'duration':
        if (value is double) {
          _duration = value;
          _durationCtrl.add(value);
        }
      case 'pause':
        if (value is bool) {
          _pausedProp = value;
          // Ignore the initial idle-core notification; only a loaded file
          // has a meaningful playing/paused state.
          if (_fileActive) {
            _setState(value ? PlaybackState.paused : PlaybackState.playing);
          }
        }
      case 'playlist-pos':
        if (value is int && value >= 0 && value != _playlistPos) {
          _playlistPos = value;
          if (_pendingNextIndex != null && value >= _pendingNextIndex!) {
            _pendingNextIndex = null;
          }
          _trackStartedCtrl.add(value);
        }
      case 'audio-params/samplerate':
        if (value is int) {
          _fmtRate = value;
          _emitFormat();
        }
      case 'audio-params/format':
        if (value is String) {
          _fmtSampleFormat = value;
          _emitFormat();
        }
      case 'audio-params/channel-count':
        if (value is int) {
          _fmtChannels = value;
          _emitFormat();
        }
      case 'current-ao':
        if (value is String && value.isNotEmpty) {
          _audioDevice = value;
          _audioDeviceCtrl.add(value);
        }
      case 'audio-out-params/samplerate':
        if (value is int) {
          _outRate = value;
          _emitFormat();
        }
      case 'audio-out-params/format':
        if (value is String) {
          _outSampleFormat = value;
          _emitFormat();
        }
    }
  }

  void _emitFormat() {
    _formatCtrl.add(
      AudioFormat(
        sampleRate: _fmtRate,
        channels: _fmtChannels,
        sampleFormat: _fmtSampleFormat,
        bitDepth: _bitDepthFromSampleFormat(_fmtSampleFormat) ?? _meta?.bits,
        outSampleRate: _outRate,
        outBitDepth: _bitDepthFromSampleFormat(_outSampleFormat),
      ),
    );
  }

  void _setState(PlaybackState s) {
    if (s == _state) return;
    _state = s;
    _stateCtrl.add(s);
    _syncPollRate();
  }
}
