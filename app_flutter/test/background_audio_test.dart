import 'package:aria/core/background_audio.dart';
import 'package:aria_player/aria_player.dart' as engine;
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playing maps to ready + prev/pause/next controls', () {
    final s = mapPlaybackState(engine.PlaybackState.playing, 12.5, radio: false);
    expect(s.playing, true);
    expect(s.processingState, AudioProcessingState.ready);
    expect(s.controls.map((c) => c.action), [
      MediaAction.skipToPrevious,
      MediaAction.pause,
      MediaAction.skipToNext,
    ]);
    expect(s.androidCompactActionIndices, [0, 1, 2]);
    expect(s.updatePosition, const Duration(milliseconds: 12500));
  });

  test('paused shows play; stopped maps to idle', () {
    final paused = mapPlaybackState(engine.PlaybackState.paused, 0, radio: false);
    expect(paused.playing, false);
    expect(paused.processingState, AudioProcessingState.ready);
    expect(paused.controls[1].action, MediaAction.play);

    final stopped = mapPlaybackState(engine.PlaybackState.stopped, 0, radio: false);
    expect(stopped.processingState, AudioProcessingState.idle);
  });

  test('stopped but resumable stays ready — headset keys keep routing to us', () {
    final s = mapPlaybackState(
      engine.PlaybackState.stopped,
      0,
      radio: false,
      canResume: true,
    );
    expect(s.processingState, AudioProcessingState.ready);
    expect(s.playing, false);
    expect(s.controls[1].action, MediaAction.play);
  });

  test('radio omits skip controls and seek', () {
    final s = mapPlaybackState(engine.PlaybackState.playing, 0, radio: true);
    expect(s.controls.map((c) => c.action), [MediaAction.pause]);
    expect(s.systemActions, isEmpty);
    expect(s.androidCompactActionIndices, [0]);
  });
}
