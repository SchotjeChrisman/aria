import 'dart:convert';

import 'package:aria/core/connection.dart';
import 'package:aria/core/data_usage.dart';
import 'package:aria/core/downloads.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria/core/quality.dart';
import 'package:aria/features/settings/data_screen.dart';
import 'package:aria/features/settings/settings_providers.dart';
import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Scripted-mpv fake and track/event helpers shared with the gapless suite.
import 'queue_gapless_test.dart' show FakeMpvRaw, prop, startFile, track;

/// Downloads notifier without filesystem/worker side effects; tests mutate
/// the index directly to simulate completed/deleted downloads.
class FakeDownloads extends DownloadsNotifier {
  @override
  DownloadsState build() => const DownloadsState();

  void setIndex(Map<String, DownloadEntry> index) {
    state = state.copyWith(index: index);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('netKindOf', () {
    test('maps connectivity_plus results', () {
      expect(netKindOf([ConnectivityResult.wifi]), NetKind.wifi);
      // Ethernet is unmetered — counts as wifi.
      expect(netKindOf([ConnectivityResult.ethernet]), NetKind.wifi);
      expect(netKindOf([ConnectivityResult.mobile]), NetKind.cellular);
      expect(
        netKindOf([ConnectivityResult.vpn, ConnectivityResult.mobile]),
        NetKind.cellular,
      );
      expect(netKindOf([ConnectivityResult.none]), NetKind.offline);
      expect(netKindOf(const []), NetKind.offline);
      // Ambiguous on a desktop test host: wifi when in doubt (unmetered).
      expect(netKindOf([ConnectivityResult.vpn]), NetKind.wifi);
    });
  });

  group('DataUsage', () {
    test('gates wifi/cellular; offline/other always allow the attempt', () {
      const d = DataUsage(
        streamOnWifi: false,
        downloadOnWifi: true,
        streamOnCellular: true,
        downloadOnCellular: false,
      );
      expect(d.allowsStream(NetKind.wifi), isFalse);
      expect(d.allowsStream(NetKind.cellular), isTrue);
      expect(d.allowsDownload(NetKind.wifi), isTrue);
      expect(d.allowsDownload(NetKind.cellular), isFalse);
      expect(d.allowsStream(NetKind.offline), isTrue);
      expect(d.allowsStream(NetKind.other), isTrue);
      expect(d.allowsDownload(NetKind.offline), isTrue);
      expect(d.allowsDownload(NetKind.other), isTrue);
    });

    Future<ProviderContainer> containerWith(Map<String, Object> seed) async {
      SharedPreferences.setMockInitialValues(seed);
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('defaults: everything on except cellular downloads', () async {
      final c = await containerWith({});
      final d = c.read(dataUsageProvider);
      expect(d.streamOnWifi, isTrue);
      expect(d.downloadOnWifi, isTrue);
      expect(d.streamOnCellular, isTrue);
      expect(d.downloadOnCellular, isFalse);
    });

    test('set() persists; a fresh container restores it', () async {
      final c = await containerWith({});
      await c
          .read(dataUsageProvider.notifier)
          .set(
            c
                .read(dataUsageProvider)
                .copyWith(streamOnCellular: false, downloadOnCellular: true),
          );

      // Fresh container over the same prefs = app restart.
      final c2 = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(c.read(sharedPrefsProvider)),
        ],
      );
      addTearDown(c2.dispose);
      final d = c2.read(dataUsageProvider);
      expect(d.streamOnCellular, isFalse);
      expect(d.downloadOnCellular, isTrue);
      expect(d.streamOnWifi, isTrue);
    });

    test('corrupt prefs fall back to defaults', () async {
      final c = await containerWith({'aria.dataUsage': 'not json'});
      final d = c.read(dataUsageProvider);
      expect(d.streamOnCellular, isTrue);
      expect(d.downloadOnCellular, isFalse);
    });
  });

  group('playback gate', () {
    Future<(ProviderContainer, FakeMpvRaw)> harness({
      NetKind kind = NetKind.cellular,
      Map<String, Object> prefs = const {},
      String? Function(String)? resolver,
      bool fakeDownloads = false,
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      final sharedPrefs = await SharedPreferences.getInstance();
      final fake = FakeMpvRaw();
      final player = AriaPlayer(
        rawFactory: () => fake,
        pollInterval: const Duration(days: 1),
      );
      await player.initialize();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(sharedPrefs),
          ariaPlayerProvider.overrideWithValue(player),
          apiClientProvider.overrideWithValue(AriaClient(baseUrl: 'http://s')),
          networkKindProvider.overrideWith((ref) => Stream.value(kind)),
          if (resolver != null)
            localSourceResolverProvider.overrideWith((ref) => resolver),
          if (fakeDownloads) downloadsProvider.overrideWith(FakeDownloads.new),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await player.dispose();
      });
      // Let the seeded network kind land before playback asks for it (a
      // listener keeps the stream un-paused).
      container.listen(networkKindProvider, (_, _) {});
      await container.read(networkKindProvider.future);
      return (container, fake);
    }

    final cellularOff = {
      'aria.dataUsage': jsonEncode({'streamOnCellular': false}),
    };

    test('cellular with streaming off: no load, paused, notice, no skip', () async {
      final (c, fake) = await harness(prefs: cellularOff);
      c.read(queueProvider.notifier).playQueue([track('t1'), track('t2')], 0);

      expect(fake.log.where((l) => l.contains('loadfile')), isEmpty);
      expect(fake.log, contains('propstr pause=yes'));
      // Stays on the blocked track — never auto-skips through the queue.
      expect(c.read(queueProvider).index, 0);
      expect(
        c.read(playbackNoticeProvider)?.message,
        'Streaming disabled on cellular',
      );
    });

    test('local downloads bypass the gate, for gapless queue-next too', () async {
      final (c, fake) = await harness(
        prefs: cellularOff,
        resolver: (id) => '/dl/$id.flac',
      );
      c.read(queueProvider.notifier).playQueue([track('t1'), track('t2')], 0);

      expect(fake.log, contains('cmd loadfile /dl/t1.flac replace'));
      expect(fake.log, contains('cmd loadfile /dl/t2.flac append'));
      expect(c.read(playbackNoticeProvider), isNull);
    });

    test('cellular streaming allowed by default (at the cellular tier)',
        () async {
      // Default quality: cellular=high, so the stream URL carries ?tier=high.
      final (c, fake) = await harness();
      c.read(queueProvider.notifier).playQueue([track('t1')], 0);
      expect(
        fake.log,
        contains('cmd loadfile http://s/api/stream/t1?tier=high replace'),
      );
    });

    test('wifi gate uses the wifi flag and says Wi-Fi', () async {
      final (c, fake) = await harness(
        kind: NetKind.wifi,
        prefs: {
          'aria.dataUsage': jsonEncode({'streamOnWifi': false}),
        },
      );
      c.read(queueProvider.notifier).playQueue([track('t1')], 0);

      expect(fake.log.where((l) => l.contains('loadfile')), isEmpty);
      expect(
        c.read(playbackNoticeProvider)?.message,
        'Streaming disabled on Wi-Fi',
      );
    });

    test('gapless queued-next is gated too: a blocked stream is never '
        'pre-queued behind a local track', () async {
      final (c, fake) = await harness(
        prefs: cellularOff,
        // t1 is downloaded, t2 would have to stream.
        resolver: (id) => id == 't1' ? '/dl/t1.flac' : null,
      );
      c.read(queueProvider.notifier).playQueue([track('t1'), track('t2')], 0);

      expect(fake.log, contains('cmd loadfile /dl/t1.flac replace'));
      // t2's stream URL must NOT be appended into the engine playlist.
      expect(fake.log.where((l) => l.contains('append')), isEmpty);
    });

    test('blocked next() rolls the index back to the engine\'s track', () async {
      final (c, fake) = await harness(
        prefs: cellularOff,
        resolver: (id) => id == 't1' ? '/dl/t1.flac' : null,
      );
      final player = c.read(ariaPlayerProvider);
      final q = c.read(queueProvider.notifier);
      q.playQueue([track('t1'), track('t2')], 0);
      fake.events.addAll([startFile, prop('playlist-pos', 0)]);
      player.debugPoll();

      q.next(); // t2 needs the network — blocked
      expect(fake.log.where((l) => l.contains('stream/t2')), isEmpty);
      expect(fake.log, contains('propstr pause=yes'));
      expect(c.read(queueProvider).index, 0); // UI stays on the engine's t1
      expect(
        c.read(playbackNoticeProvider)?.message,
        'Streaming disabled on cellular',
      );

      // Resuming plays the track the UI shows, not a hidden one.
      q.togglePlay();
      expect(c.read(queueProvider).current!.id, 't1');
    });

    test('deleting a download re-syncs the queued-next to the stream URL',
        () async {
      final (c, fake) = await harness(fakeDownloads: true);
      final dl = c.read(downloadsProvider.notifier) as FakeDownloads;
      dl.setIndex({
        't2': const DownloadEntry(path: '/dl/t2.flac', bytes: 1),
      });
      c.read(queueProvider.notifier).playQueue([track('t1'), track('t2')], 0);
      expect(fake.log, contains('cmd loadfile /dl/t2.flac append'));

      // The download is deleted mid-track: the queued-next must not keep
      // pointing at the removed file.
      dl.setIndex(const {});
      expect(fake.log, contains('cmd playlist-remove 1'));
      expect(
        fake.log,
        contains('cmd loadfile http://s/api/stream/t2?tier=high append'),
      );
    });

    test('offline never blocks — the attempt fails on its own', () async {
      final (c, fake) = await harness(
        kind: NetKind.offline,
        prefs: {
          'aria.dataUsage': jsonEncode({
            'streamOnWifi': false,
            'streamOnCellular': false,
          }),
        },
      );
      c.read(queueProvider.notifier).playQueue([track('t1')], 0);
      // offline → original tier → bare URL (no ?tier).
      expect(fake.log, contains('cmd loadfile http://s/api/stream/t1 replace'));
    });

    test('wifi default is the original tier → bare stream URL', () async {
      final (c, fake) = await harness(kind: NetKind.wifi);
      c.read(queueProvider.notifier).playQueue([track('t1')], 0);
      expect(fake.log, contains('cmd loadfile http://s/api/stream/t1 replace'));
    });

    test('the network kind selects the streaming tier at _playCurrent',
        () async {
      // wifi set to low → the current-track load carries ?tier=low.
      final (c, fake) = await harness(
        kind: NetKind.wifi,
        prefs: {
          'aria.quality': jsonEncode({'tierWifi': 'low'}),
        },
      );
      c.read(queueProvider.notifier).playQueue([track('t1'), track('t2')], 0);
      expect(
        fake.log,
        contains('cmd loadfile http://s/api/stream/t1?tier=low replace'),
      );
      // _syncEngineNext prefetches t2 at the same tier.
      expect(
        fake.log,
        contains('cmd loadfile http://s/api/stream/t2?tier=low append'),
      );
    });

    test('a qualityProvider change re-drives _syncEngineNext', () async {
      // Default cellular=high: queued-next is t2?tier=high.
      final (c, fake) = await harness();
      c.read(queueProvider.notifier).playQueue([track('t1'), track('t2')], 0);
      expect(
        fake.log,
        contains('cmd loadfile http://s/api/stream/t2?tier=high append'),
      );

      // Drop the cellular tier to low: the listener re-queues the next entry.
      await c.read(qualityProvider.notifier).set(
            c.read(qualityProvider).copyWith(tierCellular: QualityTier.low),
          );
      expect(fake.log, contains('cmd playlist-remove 1'));
      expect(
        fake.log,
        contains('cmd loadfile http://s/api/stream/t2?tier=low append'),
      );
    });
  });

  group('settings section', () {
    testWidgets('toggles flip and persist the data-usage prefs', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            // Keep the quality selector's capability check off the network.
            transcodeAvailableProvider.overrideWithValue(true),
            networkKindProvider.overrideWith(
              (ref) => Stream.value(NetKind.cellular),
            ),
          ],
          child: const MaterialApp(home: DataScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(DataScreen)),
      );

      expect(find.text('Current network: Cellular'), findsOneWidget);
      expect(find.text('Stream music'), findsNWidgets(2));

      // Wi-Fi rows come first, cellular rows second.
      await tester.tap(find.text('Stream music').last);
      await tester.pump();
      expect(container.read(dataUsageProvider).streamOnCellular, isFalse);
      expect(
        prefs.getString('aria.dataUsage'),
        contains('"streamOnCellular":false'),
      );

      await tester.tap(find.text('Download music').last);
      await tester.pump();
      expect(container.read(dataUsageProvider).downloadOnCellular, isTrue);

      await tester.tap(find.text('Stream music').first);
      await tester.pump();
      final d = container.read(dataUsageProvider);
      expect(d.streamOnWifi, isFalse);
      expect(d.downloadOnWifi, isTrue); // untouched
    });
  });
}
