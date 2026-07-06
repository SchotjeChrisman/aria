import 'package:aria/core/connection.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Same fake as the aria_player package tests: scripted mpv events, logged
/// commands.
class FakeMpvRaw implements MpvRaw {
  final List<String> log = [];
  final List<MpvEventData> events = [];

  @override
  int create() => 0xA1A;

  @override
  int initialize(int handle) => 0;

  @override
  int setOptionString(int handle, String name, String value) => 0;

  @override
  int setPropertyString(int handle, String name, String value) {
    log.add('propstr $name=$value');
    return 0;
  }

  @override
  int setPropertyDouble(int handle, String name, double value) => 0;

  @override
  int command(int handle, List<String> args) {
    log.add('cmd ${args.join(' ')}');
    return 0;
  }

  @override
  int observeProperty(int handle, int replyUserdata, String name, int format) =>
      0;

  @override
  int requestLogMessages(int handle, String minLevel) => 0;

  @override
  MpvEventData? waitEvent(int handle, double timeoutSeconds) =>
      events.isEmpty ? null : events.removeAt(0);

  @override
  void terminateDestroy(int handle) {}
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

Track track(String id) => Track(id: id, albumId: 'al', title: id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeMpvRaw fake;
  late AriaPlayer player;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    fake = FakeMpvRaw();
    player = AriaPlayer(
      rawFactory: () => fake,
      pollInterval: const Duration(days: 1), // tests drive debugPoll()
    );
    await player.initialize();
    container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        ariaPlayerProvider.overrideWithValue(player),
        apiClientProvider.overrideWithValue(AriaClient(baseUrl: 'http://s')),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await player.dispose();
  });

  String streamUrl(String id) => 'http://s/api/stream/$id';

  test('playing a queue pre-queues the next track for gapless', () {
    final q = container.read(queueProvider.notifier);
    q.playQueue([track('t1'), track('t2'), track('t3')], 0);

    expect(fake.log, contains('cmd loadfile ${streamUrl('t1')} replace'));
    // Gapless: t2 is appended into the engine playlist right away.
    expect(fake.log, contains('cmd loadfile ${streamUrl('t2')} append'));
  });

  test('natural EOF advances via trackStarted without a reload', () {
    final q = container.read(queueProvider.notifier);
    q.playQueue([track('t1'), track('t2'), track('t3')], 0);
    fake.events.addAll([startFile, prop('playlist-pos', 0)]);
    player.debugPoll();

    // t1 ends, engine slides into the prefetched t2 — mpv playlist pos 1.
    fake.events.addAll([endFileEof, startFile, prop('playlist-pos', 1)]);
    player.debugPoll();

    final state = container.read(queueProvider);
    expect(state.index, 1); // app pointer advanced by trackStarted
    expect(state.current!.id, 't2');
    // No second 'replace' load — the transition was gapless.
    expect(fake.log.where((l) => l.contains('replace')).length, 1);
    // And t3 is now queued behind t2.
    expect(fake.log, contains('cmd loadfile ${streamUrl('t3')} append'));
  });

  test('EOF of the last track just stops; queue position is kept', () {
    final q = container.read(queueProvider.notifier);
    q.playQueue([track('t1'), track('t2')], 1); // start at the last track
    fake.events.addAll([startFile, prop('playlist-pos', 0)]);
    player.debugPoll();

    fake.events.addAll([endFileEof, idle]);
    player.debugPoll();

    final state = container.read(queueProvider);
    expect(state.index, 1);
    expect(player.currentState, PlaybackState.stopped);
    // Nothing was queued or reloaded past the end.
    expect(fake.log.where((l) => l.contains('loadfile')).length, 1);
  });

  test('manual next() replaces the load (hard skip, not gapless)', () {
    final q = container.read(queueProvider.notifier);
    q.playQueue([track('t1'), track('t2'), track('t3')], 0);
    fake.events.addAll([startFile, prop('playlist-pos', 0)]);
    player.debugPoll();

    q.next();
    expect(fake.log, contains('cmd loadfile ${streamUrl('t2')} replace'));
    expect(container.read(queueProvider).index, 1);
  });

  test('queue edits re-sync the engine queued-next', () {
    final q = container.read(queueProvider.notifier);
    q.playQueue([track('t1'), track('t2')], 0);
    fake.events.addAll([startFile, prop('playlist-pos', 0)]);
    player.debugPoll();

    // Insert t9 right after the current track: pending must become t9.
    q.queueNext([track('t9')]);
    expect(fake.log, contains('cmd loadfile ${streamUrl('t9')} append'));
    // The previously queued t2 entry was replaced (one playlist-remove).
    expect(
      fake.log.where((l) => l.startsWith('cmd playlist-remove')).length,
      1,
    );
  });

  test('radio: queue ended-listener leaves stream drops to the radio '
      'notifier, which reconnects once', () {
    const st = RadioStation(id: 'r1', name: 'FIP', url: 'http://radio/fip');
    container.read(radioPlaybackProvider); // subscribe
    container.read(radioPlaybackProvider.notifier).play(st);
    expect(fake.log, contains('cmd loadfile http://radio/fip replace'));

    // Stream drops: END_FILE(eof). One reconnect attempt, no queue advance.
    fake.events.addAll([startFile, endFileEof]);
    player.debugPoll();
    expect(
      fake.log
          .where((l) => l == 'cmd loadfile http://radio/fip replace')
          .length,
      2,
    );

    // Second drop: stays stopped, station stays on the bar.
    fake.events.addAll([startFile, endFileEof, idle]);
    player.debugPoll();
    expect(
      fake.log
          .where((l) => l == 'cmd loadfile http://radio/fip replace')
          .length,
      2,
    );
    expect(container.read(radioPlaybackProvider)?.id, 'r1');
  });

  test('playing a track clears radio mode and its persistence', () {
    const st = RadioStation(id: 'r1', name: 'FIP', url: 'http://radio/fip');
    container.read(radioPlaybackProvider.notifier).play(st);
    container.read(queueProvider.notifier).playQueue([track('t1')], 0);
    expect(container.read(radioPlaybackProvider), isNull);
  });
}
