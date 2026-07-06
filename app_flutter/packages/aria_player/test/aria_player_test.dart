import 'package:aria_player/aria_player.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMpvRaw implements MpvRaw {
  int createResult = 0xA1A;
  int initializeResult = 0;
  bool destroyed = false;
  final List<String> log = [];
  final List<MpvEventData> events = [];

  @override
  int create() {
    log.add('create');
    return createResult;
  }

  @override
  int initialize(int handle) {
    log.add('initialize');
    return initializeResult;
  }

  @override
  int setOptionString(int handle, String name, String value) {
    log.add('option $name=$value');
    return 0;
  }

  @override
  int setPropertyString(int handle, String name, String value) {
    log.add('propstr $name=$value');
    return 0;
  }

  @override
  int setPropertyDouble(int handle, String name, double value) {
    log.add('propdbl $name=$value');
    return 0;
  }

  @override
  int command(int handle, List<String> args) {
    log.add('cmd ${args.join(' ')}');
    return 0;
  }

  @override
  int observeProperty(int handle, int replyUserdata, String name, int format) {
    log.add('observe $name');
    return 0;
  }

  @override
  MpvEventData? waitEvent(int handle, double timeoutSeconds) =>
      events.isEmpty ? null : events.removeAt(0);

  @override
  void terminateDestroy(int handle) {
    destroyed = true;
    log.add('destroy');
  }
}

MpvEventData prop(String name, Object? value) => MpvEventData(
  MpvEventId.propertyChange,
  propertyName: name,
  propertyValue: value,
);

const startFile = MpvEventData(MpvEventId.startFile);
const idle = MpvEventData(MpvEventId.idle);
const endFileEof = MpvEventData(
  MpvEventId.endFile,
  endFileReason: MpvEndFileReason.eof,
);
const endFileStop = MpvEventData(
  MpvEventId.endFile,
  endFileReason: MpvEndFileReason.stop,
);

Future<(AriaPlayer, FakeMpvRaw)> makePlayer({bool exclusive = false}) async {
  final fake = FakeMpvRaw();
  final player = AriaPlayer(
    rawFactory: () => fake,
    audioExclusive: exclusive,
    // Tests drive event draining via debugPoll(); keep the timer inert.
    pollInterval: const Duration(days: 1),
  );
  await player.initialize();
  return (player, fake);
}

void main() {
  group('availability', () {
    test('library load failure degrades gracefully', () async {
      final player = AriaPlayer(
        rawFactory: () =>
            throw PlayerUnavailableException('libmpv could not be loaded'),
      );
      await player.initialize();
      expect(player.isAvailable, isFalse);
      expect(player.unavailableReason, contains('libmpv'));
      // Every command is a safe no-op.
      player.play('http://x/t.flac');
      player.queueNext('http://x/t2.flac');
      player.pause();
      player.resume();
      player.stop();
      player.seek(10);
      player.setVolume(50);
      player.setAudioExclusive(true);
      player.debugPoll();
      await player.dispose();
    });

    test('mpv_create failure degrades gracefully', () async {
      final fake = FakeMpvRaw()..createResult = 0;
      final player = AriaPlayer(rawFactory: () => fake);
      await player.initialize();
      expect(player.isAvailable, isFalse);
      expect(player.unavailableReason, contains('mpv_create'));
      await player.dispose();
    });

    test('mpv_initialize failure destroys handle and degrades', () async {
      final fake = FakeMpvRaw()..initializeResult = -5;
      final player = AriaPlayer(rawFactory: () => fake);
      await player.initialize();
      expect(player.isAvailable, isFalse);
      expect(player.unavailableReason, contains('mpv_initialize'));
      expect(fake.destroyed, isTrue);
      await player.dispose();
    });
  });

  group('initialization', () {
    test('sets audio-only gapless options before initialize', () async {
      final (player, fake) = await makePlayer();
      expect(player.isAvailable, isTrue);
      final initAt = fake.log.indexOf('initialize');
      for (final opt in [
        'option vid=no',
        'option idle=yes',
        'option gapless-audio=yes',
        'option prefetch-playlist=yes',
        'option audio-exclusive=no',
      ]) {
        expect(fake.log.indexOf(opt), lessThan(initAt), reason: opt);
      }
      await player.dispose();
    });

    test('audio-exclusive honored at init', () async {
      final (player, fake) = await makePlayer(exclusive: true);
      expect(fake.log, contains('option audio-exclusive=yes'));
      await player.dispose();
    });

    test('observes transport, playlist and format properties', () async {
      final (player, fake) = await makePlayer();
      for (final name in [
        'time-pos',
        'duration',
        'pause',
        'playlist-pos',
        'audio-params/samplerate',
        'audio-params/format',
        'audio-params/channel-count',
      ]) {
        expect(fake.log, contains('observe $name'));
      }
      await player.dispose();
    });
  });

  group('transport', () {
    test('play issues loadfile replace and unpauses', () async {
      final (player, fake) = await makePlayer();
      player.play('http://s/api/stream/abc');
      expect(
        fake.log,
        contains('cmd loadfile http://s/api/stream/abc replace'),
      );
      expect(fake.log, contains('propstr pause=no'));
      await player.dispose();
    });

    test(
      'pause/resume set the pause property; state follows mpv events',
      () async {
        final (player, fake) = await makePlayer();
        final states = <PlaybackState>[];
        player.state.listen(states.add);

        player.play('u');
        fake.events.addAll([startFile, prop('pause', false)]);
        player.debugPoll();
        expect(states, [PlaybackState.playing]);

        player.pause();
        expect(fake.log, contains('propstr pause=yes'));
        fake.events.add(prop('pause', true));
        player.debugPoll();
        expect(states, [PlaybackState.playing, PlaybackState.paused]);

        player.resume();
        fake.events.add(prop('pause', false));
        player.debugPoll();
        expect(states, [
          PlaybackState.playing,
          PlaybackState.paused,
          PlaybackState.playing,
        ]);
        await player.dispose();
      },
    );

    test(
      'initial idle-core pause notification does not emit playing',
      () async {
        final (player, fake) = await makePlayer();
        final states = <PlaybackState>[];
        player.state.listen(states.add);
        fake.events.add(prop('pause', false)); // before any file is loaded
        player.debugPoll();
        expect(states, isEmpty);
        await player.dispose();
      },
    );

    test('stop sends stop command and emits stopped immediately', () async {
      final (player, fake) = await makePlayer();
      final states = <PlaybackState>[];
      player.state.listen(states.add);
      player.play('u');
      fake.events.add(startFile);
      player.debugPoll();
      player.stop();
      expect(fake.log, contains('cmd stop'));
      expect(states, [PlaybackState.playing, PlaybackState.stopped]);
      // The idle event that follows must not re-emit stopped.
      fake.events.add(idle);
      player.debugPoll();
      expect(states, [PlaybackState.playing, PlaybackState.stopped]);
      await player.dispose();
    });

    test('seek clamps to zero and issues absolute seek', () async {
      final (player, fake) = await makePlayer();
      player.play('u');
      player.seek(12.5);
      player.seek(-3);
      expect(fake.log, contains('cmd seek 12.5 absolute'));
      expect(fake.log, contains('cmd seek 0.0 absolute'));
      await player.dispose();
    });

    test('setVolume clamps 0-100', () async {
      final (player, fake) = await makePlayer();
      player.setVolume(150);
      player.setVolume(-10);
      player.setVolume(63.5);
      expect(fake.log, contains('propdbl volume=100.0'));
      expect(fake.log, contains('propdbl volume=0.0'));
      expect(fake.log, contains('propdbl volume=63.5'));
      await player.dispose();
    });
  });

  group('streams', () {
    test('position and duration from property events', () async {
      final (player, fake) = await makePlayer();
      final positions = <double>[];
      final durations = <double>[];
      player.position.listen(positions.add);
      player.duration.listen(durations.add);
      fake.events.addAll([
        prop('duration', 251.4),
        prop('time-pos', 1.0),
        prop('time-pos', 2.5),
        prop('time-pos', null), // MPV_FORMAT_NONE: track unloaded
      ]);
      player.debugPoll();
      expect(positions, [1.0, 2.5]);
      expect(durations, [251.4]);
      expect(player.currentPosition, 2.5);
      expect(player.currentDuration, 251.4);
      await player.dispose();
    });

    test('ended fires on end-file eof, then idle stops', () async {
      final (player, fake) = await makePlayer();
      var endedCount = 0;
      final states = <PlaybackState>[];
      player.ended.listen((_) => endedCount++);
      player.state.listen(states.add);
      player.play('u');
      fake.events.addAll([startFile, endFileEof, idle]);
      player.debugPoll();
      expect(endedCount, 1);
      expect(states, [PlaybackState.playing, PlaybackState.stopped]);
      await player.dispose();
    });

    test('end-file with stop reason does not fire ended', () async {
      final (player, fake) = await makePlayer();
      var endedCount = 0;
      player.ended.listen((_) => endedCount++);
      player.play('u');
      fake.events.addAll([startFile, endFileStop, idle]);
      player.debugPoll();
      expect(endedCount, 0);
      await player.dispose();
    });

    test('format from meta immediately, then from mpv audio-params', () async {
      final (player, fake) = await makePlayer();
      final formats = <AudioFormat>[];
      player.format.listen(formats.add);
      player.play(
        'u',
        meta: const TrackMeta(sampleRate: 96000, bits: 24, channels: 2),
      );
      expect(formats, [
        const AudioFormat(sampleRate: 96000, channels: 2, bitDepth: 24),
      ]);
      fake.events.addAll([
        startFile,
        prop('audio-params/samplerate', 96000),
        prop('audio-params/format', 's32'),
        prop('audio-params/channel-count', 2),
      ]);
      player.debugPoll();
      expect(
        formats.last,
        const AudioFormat(
          sampleRate: 96000,
          channels: 2,
          sampleFormat: 's32',
          bitDepth: 32,
        ),
      );
      await player.dispose();
    });

    test('float sample format maps to 32-bit depth', () async {
      final (player, fake) = await makePlayer();
      final formats = <AudioFormat>[];
      player.format.listen(formats.add);
      player.play('u');
      fake.events.add(prop('audio-params/format', 'float'));
      player.debugPoll();
      expect(formats.last.bitDepth, 32);
      await player.dispose();
    });
  });

  group('gapless queue', () {
    test('queueNext appends and trackStarted follows playlist-pos', () async {
      final (player, fake) = await makePlayer();
      final tracks = <int>[];
      var endedCount = 0;
      final states = <PlaybackState>[];
      player.trackStarted.listen(tracks.add);
      player.ended.listen((_) => endedCount++);
      player.state.listen(states.add);

      player.play('t1');
      fake.events.addAll([startFile, prop('playlist-pos', 0)]);
      player.debugPoll();

      player.queueNext('t2');
      expect(fake.log, contains('cmd loadfile t2 append'));

      // Gapless advance: eof of t1, start of t2, no stopped state between.
      fake.events.addAll([endFileEof, startFile, prop('playlist-pos', 1)]);
      player.debugPoll();
      expect(tracks, [0, 1]);
      expect(endedCount, 1);
      expect(states, [PlaybackState.playing]);
      await player.dispose();
    });

    test(
      'second queueNext before advance replaces the pending entry',
      () async {
        final (player, fake) = await makePlayer();
        player.play('t1');
        fake.events.addAll([startFile, prop('playlist-pos', 0)]);
        player.debugPoll();

        player.queueNext('t2');
        player.queueNext('t3');
        expect(fake.log, contains('cmd playlist-remove 1'));
        expect(fake.log, contains('cmd loadfile t3 append'));
        // Replacement lands back at index 1, not 2.
        expect(
          fake.log.where((l) => l.startsWith('cmd playlist-remove')).length,
          1,
        );

        // After t3 starts, a further queueNext must not remove anything.
        fake.events.addAll([endFileEof, startFile, prop('playlist-pos', 1)]);
        player.debugPoll();
        player.queueNext('t4');
        expect(
          fake.log.where((l) => l.startsWith('cmd playlist-remove')).length,
          1,
        );
        expect(fake.log, contains('cmd loadfile t4 append'));
        await player.dispose();
      },
    );

    test('queueNext before play is a no-op', () async {
      final (player, fake) = await makePlayer();
      expect(player.queueNext('t1'), isFalse);
      expect(fake.log.where((l) => l.contains('loadfile')), isEmpty);
      await player.dispose();
    });

    test('queueNext reports success while a file is loaded', () async {
      final (player, _) = await makePlayer();
      player.play('t1');
      expect(player.queueNext('t2'), isTrue);
      await player.dispose();
    });

    test('clearQueueNext removes a pending entry once, then no-ops', () async {
      final (player, fake) = await makePlayer();
      player.play('t1');
      fake.events.addAll([startFile, prop('playlist-pos', 0)]);
      player.debugPoll();
      player.queueNext('t2');
      player.clearQueueNext();
      player.clearQueueNext(); // second call must not remove anything else
      expect(
        fake.log.where((l) => l.startsWith('cmd playlist-remove')).length,
        1,
      );
      // A later queueNext lands at index 1 again (count was decremented).
      player.queueNext('t3');
      fake.events.addAll([endFileEof, startFile, prop('playlist-pos', 1)]);
      player.debugPoll();
      expect(player.currentState, PlaybackState.playing);
      await player.dispose();
    });

    test('stale idle after an ended-driven play() is discarded', () async {
      final (player, fake) = await makePlayer();
      final states = <PlaybackState>[];
      player.state.listen(states.add);
      // App-style auto-advance: the ended listener immediately loads the
      // next track (sync controllers: this runs inside the drain loop).
      player.ended.listen((_) => player.play('t2'));

      player.play('t1');
      fake.events.addAll([startFile, prop('playlist-pos', 0)]);
      player.debugPoll();
      expect(states, [PlaybackState.playing]);

      // mpv queued END_FILE(eof) + IDLE before our loadfile took effect. The
      // stale IDLE must neither emit stopped nor zero the bookkeeping.
      fake.events.addAll([endFileEof, idle]);
      player.debugPoll();
      expect(states, [PlaybackState.playing]); // no transient stopped

      fake.events.addAll([startFile, prop('playlist-pos', 0)]);
      player.debugPoll();
      // Bookkeeping survived: queueNext still works on the fresh load.
      expect(player.queueNext('t3'), isTrue);
      expect(fake.log, contains('cmd loadfile t3 append'));
      await player.dispose();
    });

    test('genuine idle after end of playlist still stops', () async {
      final (player, fake) = await makePlayer();
      final states = <PlaybackState>[];
      player.state.listen(states.add);
      player.play('t1');
      fake.events.addAll([startFile, prop('playlist-pos', 0)]);
      player.debugPoll();
      fake.events.addAll([endFileEof, idle]);
      player.debugPoll();
      expect(states, [PlaybackState.playing, PlaybackState.stopped]);
      expect(player.queueNext('t2'), isFalse); // playlist bookkeeping zeroed
      await player.dispose();
    });
  });

  group('lifecycle', () {
    test('dispose terminates the handle and disables commands', () async {
      final (player, fake) = await makePlayer();
      await player.dispose();
      expect(fake.destroyed, isTrue);
      expect(player.isAvailable, isFalse);
      player.play('u'); // must not throw after dispose
      await player.dispose(); // idempotent
    });
  });
}
