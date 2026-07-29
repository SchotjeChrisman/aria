import 'package:aria/core/connection.dart';
import 'package:aria/core/eq.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Same fake as queue_gapless_test / the aria_player package tests: scripted
/// mpv events, logged property writes and commands.
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

Track track(String id, {double? gain, double? albumGain}) => Track(
  id: id,
  albumId: 'al',
  title: id,
  trackGainDb: gain,
  albumGainDb: albumGain,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------- pure strings

  group('buildAf with no gain is byte-identical to eqToAf', () {
    // Every profile the frozen eq_af_test baseline covers.
    const profiles = [
      EqProfile(
        gainDb: -6.8,
        bands: [
          EqBand(type: 'peak_dip', frequency: 105, gainDb: 3.1, q: 0.7),
          EqBand(type: 'low_shelf', frequency: 105, gainDb: -1.4, q: 0.7),
          EqBand(type: 'high_shelf', frequency: 10000, gainDb: 2.25, q: 0.7),
          EqBand(type: 'high_pass', frequency: 20, slope: 24),
          EqBand(type: 'low_pass', frequency: 18000, slope: 12),
          EqBand(type: 'band_pass', frequency: 1000, q: 2),
          EqBand(type: 'band_stop', frequency: 60, q: 4),
          EqBand(type: 'weird_future_type', frequency: 1),
        ],
      ),
      EqProfile(
        bands: [EqBand(type: 'peak_dip', frequency: 105, gainDb: 3, q: 0.7)],
      ),
      EqProfile(
        gainDb: -99,
        bands: [EqBand(type: 'peak_dip', frequency: 0, gainDb: 100, q: 0)],
      ),
      EqProfile(gainDb: -4), // no usable bands -> ''
      EqProfile(gainDb: -4, bands: [EqBand(type: 'unknown', frequency: 1)]),
    ];

    test('null gain', () {
      for (final p in profiles) {
        expect(buildAf(p, null), eqToAf(p), reason: '$p');
      }
    });

    test('0 dB is a measured value that still emits nothing', () {
      for (final p in profiles) {
        expect(buildAf(p, 0), eqToAf(p), reason: '$p');
      }
    });

    test('no EQ and no gain clears the chain', () {
      expect(buildAf(null, null), '');
      expect(buildAf(null, 0), '');
    });
  });

  test('the gain leads the chain and leaves the EQ a verbatim substring', () {
    const p = EqProfile(
      gainDb: -6.8,
      bands: [EqBand(type: 'peak_dip', frequency: 105, gainDb: 3.1, q: 0.7)],
    );
    expect(
      buildAf(p, -4.25),
      'lavfi=[volume=-4.25dB,volume=-6.8dB,equalizer=f=105:t=q:w=0.7:g=3.1]',
    );
    // the EQ portion is untouched, character for character
    expect(buildAf(p, -4.25), contains(eqToAf(p).substring('lavfi=['.length)));
    // and a gain with no EQ is a chain of exactly one element
    expect(buildAf(null, -4.25), 'lavfi=[volume=-4.25dB]');
  });

  group('appliedGain', () {
    test('attenuates only — positive gain is clamped away, never clips', () {
      expect(appliedGain(3.3), isNull);
      expect(appliedGain(0.001), isNull);
      expect(appliedGain(-3.3), -3.3);
      // rounds to '-0' at the two decimals buildAf renders: an identity
      // multiply must not buy a filter stage (-17.999 LUFS measures here)
      expect(appliedGain(-0.001), isNull);
    });

    test('clamps to a range mpv will graph', () {
      expect(appliedGain(-99), -24.0);
    });

    test('NaN and infinity never reach the chain', () {
      // mpv accepts any af string at set time and only rejects it at load,
      // where it hard-stops playback rather than being ignored.
      expect(appliedGain(double.nan), isNull);
      expect(appliedGain(double.negativeInfinity), isNull);
      expect(appliedGain(double.infinity), isNull);
      expect(buildAf(null, double.nan), '');
    });
  });

  group('gainFor never guesses', () {
    final full = track('t', gain: -5, albumGain: -3);
    final trackOnly = track('t', gain: -5);
    final bare = track('t');

    test('off means off, whatever the data says', () {
      expect(gainFor(full, LoudnessMode.off), isNull);
    });

    test('no track (radio, idle) means no gain', () {
      expect(gainFor(null, LoudnessMode.track), isNull);
      expect(gainFor(null, LoudnessMode.album), isNull);
    });

    test('unanalysed tracks get no adjustment, not 0', () {
      expect(gainFor(bare, LoudnessMode.track), isNull);
      expect(gainFor(bare, LoudnessMode.album), isNull);
    });

    test('album mode never falls back to the track gain', () {
      // Substituting it would silently re-introduce the inter-track jumps
      // album mode exists to prevent.
      expect(gainFor(trackOnly, LoudnessMode.album), isNull);
      expect(gainFor(trackOnly, LoudnessMode.track), -5);
    });

    test('measured values pass through', () {
      expect(gainFor(full, LoudnessMode.track), -5);
      expect(gainFor(full, LoudnessMode.album), -3);
    });
  });

  // --------------------------------------------------------- engine level

  /// Plays a two-track queue under [mode] and returns everything the engine
  /// saw.
  Future<FakeMpvRaw> drive(
    LoudnessMode mode,
    List<Track> tracks, {
    void Function(ProviderContainer c)? then,
  }) async {
    SharedPreferences.setMockInitialValues({'aria.loudness': mode.name});
    final prefs = await SharedPreferences.getInstance();
    final fake = FakeMpvRaw();
    final player = AriaPlayer(
      rawFactory: () => fake,
      pollInterval: const Duration(days: 1),
    );
    await player.initialize();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        ariaPlayerProvider.overrideWithValue(player),
        apiClientProvider.overrideWithValue(AriaClient(baseUrl: 'http://s')),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await player.dispose();
    });
    container.read(queueProvider.notifier).playQueue(tracks, 0);
    then?.call(container);
    return fake;
  }

  List<String> afWrites(FakeMpvRaw f) =>
      f.log.where((l) => l.startsWith('propstr af=')).toList();

  test('normalisation off is indistinguishable from having no gain data', () {
    // The whole bit-perfect promise, stated at the mpv boundary.
    late List<String> off, noData;
    return drive(LoudnessMode.off, [
      track('t1', gain: -5, albumGain: -3),
      track('t2', gain: -9, albumGain: -3),
    ]).then((f) {
      off = afWrites(f);
      return drive(LoudnessMode.track, [track('t1'), track('t2')]);
    }).then((f) {
      noData = afWrites(f);
      expect(off, equals(noData));
      // ...and neither of them put a gain on the chain at all
      expect(off.where((l) => l.contains('volume=')), isEmpty);
    });
  });

  test('a measured gain does reach the chain (the negative control)', () async {
    final f = await drive(LoudnessMode.track, [
      track('t1', gain: -5),
      track('t2', gain: -5),
    ]);
    expect(afWrites(f), contains('propstr af=lavfi=[volume=-5dB]'));
  });

  test('the gain never touches the volume property (the user slider)', () async {
    final f = await drive(LoudnessMode.track, [
      track('t1', gain: -5),
      track('t2', gain: -9),
    ]);
    expect(f.log.where((l) => l.startsWith('propdbl volume=')), isEmpty);
  });

  test('a station never inherits the outgoing track\'s gain', () async {
    // RadioPlaybackNotifier.play() loads the URL straight into the engine,
    // bypassing _playCurrent — so the drop has to happen in clearForRadio.
    // The signal path's radio branch has no Gain stage, so a leaked filter
    // would also be invisible.
    final f = await drive(
      LoudnessMode.track,
      [track('t1', gain: -7.5)],
      then: (c) => c
          .read(radioPlaybackProvider.notifier)
          .play(const RadioStation(id: 'r', name: 'R', url: 'http://x/s.flac')),
    );
    expect(afWrites(f).last, 'propstr af=');
    expect(f.log.last, 'propstr pause=no'); // ...and it landed before the load
    expect(
      f.log.indexOf('cmd loadfile http://x/s.flac replace'),
      greaterThan(f.log.lastIndexOf('propstr af=')),
    );
  });

  group('gapless', () {
    String url(String id) => 'http://s/api/stream/$id';

    test('off: the next track is still pre-queued', () async {
      final f = await drive(LoudnessMode.off, [
        track('t1', gain: -5),
        track('t2', gain: -9),
      ]);
      expect(f.log, contains('cmd loadfile ${url('t2')} append'));
    });

    test('album mode keeps the join — one album, one gain', () async {
      final f = await drive(LoudnessMode.album, [
        track('t1', gain: -5, albumGain: -3),
        track('t2', gain: -9, albumGain: -3),
      ]);
      expect(f.log, contains('cmd loadfile ${url('t2')} append'));
    });

    test('track mode drops the join when the gains differ', () async {
      // `af` is global and _onTrackStarted fires after mpv has already begun
      // the next file, so the only honest option is a clean reload.
      final f = await drive(LoudnessMode.track, [
        track('t1', gain: -5),
        track('t2', gain: -9),
      ]);
      expect(f.log, isNot(contains('cmd loadfile ${url('t2')} append')));
    });

    test('track mode keeps the join when the gains happen to match', () async {
      final f = await drive(LoudnessMode.track, [
        track('t1', gain: -5),
        track('t2', gain: -5),
      ]);
      expect(f.log, contains('cmd loadfile ${url('t2')} append'));
    });
  });
}

