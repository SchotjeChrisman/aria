import 'package:aria_player/aria_player.dart' as engine;
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection.dart';
import 'player_providers.dart';

// Android-only: main() guards the single call site with Platform.isAndroid.
// A media session + foreground service keep the process (and its HTTP
// stream) alive in the background; the audio session pauses playback when
// the output device goes away. Desktop never reaches this code.

Future<void> initBackgroundAudio(ProviderContainer container) async {
  await AudioService.init(
    builder: () => AriaAudioHandler(container),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'app.aria.audio',
      androidNotificationChannelName: 'Aria playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  // Output device lost (headphones unplugged): pause, not stop — position
  // is kept, standard platform UX; the audible result is the music stops.
  session.becomingNoisyEventStream.listen(
    (_) => container.read(ariaPlayerProvider).pause(),
  );
  // Calls/assistants: pause on interruption begin, never auto-resume.
  session.interruptionEventStream.listen((e) {
    if (e.begin) container.read(ariaPlayerProvider).pause();
  });
  // audio_session only registers the noisy receiver and the focus-change
  // listener inside requestAudioFocus — configure() alone wires nothing, so
  // the two handlers above are dead (and Aria mixes over other apps) until
  // setActive(true). Request on every transition to playing; a denial means
  // another app owns audio right now, so stay paused.
  // ponytail: focus stays held after stop — releasing on idle is churn with
  // no observable win, revisit if OEM battery watchdogs complain.
  container.read(ariaPlayerProvider).state.listen((s) async {
    if (s == engine.PlaybackState.playing && !await session.setActive(true)) {
      container.read(ariaPlayerProvider).pause();
    }
  });
}

/// Engine state + position -> media-session state. Top-level pure function
/// so it is unit-testable without the plugin.
PlaybackState mapPlaybackState(
  engine.PlaybackState s,
  double positionSeconds, {
  required bool radio,
}) {
  final playing = s == engine.PlaybackState.playing;
  final toggle = playing ? MediaControl.pause : MediaControl.play;
  return PlaybackState(
    // Radio has no next/prev/seek (legacy playRadio semantics).
    controls: radio
        ? [toggle]
        : [MediaControl.skipToPrevious, toggle, MediaControl.skipToNext],
    systemActions: radio ? const {} : const {MediaAction.seek},
    androidCompactActionIndices: radio ? const [0] : const [0, 1, 2],
    processingState: s == engine.PlaybackState.stopped
        ? AudioProcessingState.idle
        : AudioProcessingState.ready,
    playing: playing,
    updatePosition: Duration(milliseconds: (positionSeconds * 1000).round()),
  );
}

/// Thin bridge: notification/MediaSession buttons forward to the existing
/// QueueNotifier/engine; engine + queue state map onto playbackState and
/// mediaItem. No playback logic lives here.
class AriaAudioHandler extends BaseAudioHandler {
  AriaAudioHandler(this._c) {
    _player.state.listen((_) => _pushState());
    // The OS extrapolates position from the last push while playing; only a
    // seek breaks that, so re-push when the position jumps off projection.
    _player.position.listen((pos) {
      final elapsed = _player.currentState == engine.PlaybackState.playing
          ? DateTime.now().difference(_pushedAt).inMilliseconds / 1000
          : 0.0;
      if ((pos - (_pushedPos + elapsed)).abs() > 1) _pushState();
    });
    _c.listen(
      currentTrackProvider,
      (_, _) => _pushItem(),
      fireImmediately: true,
    );
    _c.listen(radioPlaybackProvider, (_, _) {
      _pushItem();
      _pushState(); // the control set changes with radio mode
    });
  }

  final ProviderContainer _c;
  double _pushedPos = 0;
  DateTime _pushedAt = DateTime.now();

  engine.AriaPlayer get _player => _c.read(ariaPlayerProvider);
  bool get _radio => _c.read(radioPlaybackProvider) != null;

  void _pushState() {
    _pushedPos = _player.currentPosition;
    _pushedAt = DateTime.now();
    playbackState.add(
      mapPlaybackState(_player.currentState, _pushedPos, radio: _radio),
    );
  }

  void _pushItem() {
    final st = _c.read(radioPlaybackProvider);
    final t = _c.read(currentTrackProvider);
    mediaItem.add(switch ((st, t)) {
      (final s?, _) => MediaItem(id: s.url, title: s.name),
      (_, final t?) => MediaItem(
        id: t.id,
        title: t.title ?? '—',
        artist: t.artist,
        album: t.album,
        duration: t.duration == null
            ? null
            : Duration(milliseconds: (t.duration! * 1000).round()),
        artUri: Uri.parse(_c.read(apiClientProvider).artUrl(t.albumId)),
      ),
      _ => null,
    });
  }

  @override
  Future<void> play() async {
    // togglePlay covers paused-resume, stopped-with-track and the radio
    // reconnect; the guard keeps a redundant play from pausing.
    if (_player.currentState != engine.PlaybackState.playing) {
      _c.read(queueProvider.notifier).togglePlay();
    }
  }

  @override
  Future<void> pause() async => _player.pause();

  @override
  Future<void> stop() async => _radio
      ? _c.read(radioPlaybackProvider.notifier).stop()
      : _player.stop();

  @override
  Future<void> skipToNext() async {
    if (!_radio) _c.read(queueProvider.notifier).next();
  }

  @override
  Future<void> skipToPrevious() async {
    if (!_radio) _c.read(queueProvider.notifier).prev();
  }

  @override
  Future<void> seek(Duration position) async =>
      _player.seek(position.inMilliseconds / 1000);
}
