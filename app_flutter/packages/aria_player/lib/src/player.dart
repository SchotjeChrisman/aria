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

/// Decoded audio format for the UI badge. Emitted from server meta on play,
/// then overwritten by mpv's real `audio-params` once decode starts.
@immutable
class AudioFormat {
  const AudioFormat({
    this.sampleRate,
    this.channels,
    this.sampleFormat,
    this.bitDepth,
  });

  final int? sampleRate;
  final int? channels;

  /// mpv sample format string, e.g. "s16", "s32", "float". Null when the
  /// value came from server meta.
  final String? sampleFormat;
  final int? bitDepth;

  @override
  bool operator ==(Object other) =>
      other is AudioFormat &&
      other.sampleRate == sampleRate &&
      other.channels == channels &&
      other.sampleFormat == sampleFormat &&
      other.bitDepth == bitDepth;

  @override
  int get hashCode => Object.hash(sampleRate, channels, sampleFormat, bitDepth);

  @override
  String toString() =>
      'AudioFormat(${sampleRate}Hz, ${channels}ch, ${sampleFormat ?? 'meta'}, ${bitDepth}bit)';
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

  MpvRaw? _raw;
  int _handle = 0;
  Timer? _timer;
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
  TrackMeta? _meta;
  int? _fmtRate;
  int? _fmtChannels;
  String? _fmtSampleFormat;

  final _positionCtrl = StreamController<double>.broadcast(sync: true);
  final _durationCtrl = StreamController<double>.broadcast(sync: true);
  final _stateCtrl = StreamController<PlaybackState>.broadcast(sync: true);
  final _endedCtrl = StreamController<void>.broadcast(sync: true);
  final _formatCtrl = StreamController<AudioFormat>.broadcast(sync: true);
  final _trackStartedCtrl = StreamController<int>.broadcast(sync: true);

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

  PlaybackState get currentState => _state;
  double get currentPosition => _position;
  double? get currentDuration => _duration;
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

    _raw = raw;
    _handle = handle;
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  /// Replace the playlist with [url] and start playing.
  void play(String url, {TrackMeta? meta}) {
    if (!isAvailable) return;
    _meta = meta;
    _playlistPos = -1;
    _localPlaylistCount = 1;
    _pendingNextIndex = null;
    _loadPending = true;
    _fmtRate = null;
    _fmtChannels = null;
    _fmtSampleFormat = null;
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

  /// Runtime toggle for exclusive device access (desktop).
  void setAudioExclusive(bool on) {
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
    switch (ev.eventId) {
      case MpvEventId.propertyChange:
        _handleProperty(ev.propertyName, ev.propertyValue);
      case MpvEventId.startFile:
        _fileActive = true;
        _loadPending = false;
        _setState(_pausedProp ? PlaybackState.paused : PlaybackState.playing);
      case MpvEventId.endFile:
        if (ev.endFileReason == MpvEndFileReason.eof) {
          _endedCtrl.add(null);
        }
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
      default:
        break;
    }
  }

  void _handleProperty(String? name, Object? value) {
    switch (name) {
      case 'time-pos':
        if (value is double) {
          _position = value;
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
    }
  }

  void _emitFormat() {
    _formatCtrl.add(
      AudioFormat(
        sampleRate: _fmtRate,
        channels: _fmtChannels,
        sampleFormat: _fmtSampleFormat,
        bitDepth: _bitDepthFromSampleFormat(_fmtSampleFormat) ?? _meta?.bits,
      ),
    );
  }

  void _setState(PlaybackState s) {
    if (s == _state) return;
    _state = s;
    _stateCtrl.add(s);
  }
}
