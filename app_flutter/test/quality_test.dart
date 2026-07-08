import 'package:aria/core/connection.dart';
import 'package:aria/core/data_usage.dart';
import 'package:aria/core/quality.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('QualityTier', () {
    test('wire values and fromWire round-trip; unknown → original', () {
      expect(QualityTier.original.wire, 'original');
      expect(QualityTier.high.wire, 'high');
      expect(QualityTier.low.wire, 'low');
      expect(QualityTier.fromWire('high'), QualityTier.high);
      expect(QualityTier.fromWire('low'), QualityTier.low);
      expect(QualityTier.fromWire(null), QualityTier.original);
      expect(QualityTier.fromWire('bogus'), QualityTier.original);
    });
  });

  group('QualityPrefs', () {
    test('defaults: wifi=original, cellular=high, download=original', () {
      const q = QualityPrefs();
      expect(q.tierWifi, QualityTier.original);
      expect(q.tierCellular, QualityTier.high);
      expect(q.tierDownload, QualityTier.original);
    });

    test('streamTierFor maps by network kind; offline/other → original', () {
      const q = QualityPrefs(
        tierWifi: QualityTier.low,
        tierCellular: QualityTier.high,
      );
      expect(q.streamTierFor(NetKind.wifi), QualityTier.low);
      expect(q.streamTierFor(NetKind.cellular), QualityTier.high);
      expect(q.streamTierFor(NetKind.offline), QualityTier.original);
      expect(q.streamTierFor(NetKind.other), QualityTier.original);
    });

    test('fromJson/toJson/copyWith round-trip', () {
      const q = QualityPrefs(
        tierWifi: QualityTier.high,
        tierCellular: QualityTier.low,
        tierDownload: QualityTier.high,
      );
      final back = QualityPrefs.fromJson(q.toJson());
      expect(back.tierWifi, QualityTier.high);
      expect(back.tierCellular, QualityTier.low);
      expect(back.tierDownload, QualityTier.high);

      final edited = q.copyWith(tierWifi: QualityTier.original);
      expect(edited.tierWifi, QualityTier.original);
      expect(edited.tierCellular, QualityTier.low); // untouched
      expect(edited.tierDownload, QualityTier.high);
    });
  });

  group('qualityProvider', () {
    Future<ProviderContainer> containerWith(Map<String, Object> seed) async {
      SharedPreferences.setMockInitialValues(seed);
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('defaults with no prefs', () async {
      final c = await containerWith({});
      final q = c.read(qualityProvider);
      expect(q.tierWifi, QualityTier.original);
      expect(q.tierCellular, QualityTier.high);
      expect(q.tierDownload, QualityTier.original);
    });

    test('set() persists; a fresh container restores it', () async {
      final c = await containerWith({});
      await c.read(qualityProvider.notifier).set(
            c
                .read(qualityProvider)
                .copyWith(tierWifi: QualityTier.high, tierDownload: QualityTier.low),
          );

      final c2 = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(c.read(sharedPrefsProvider)),
        ],
      );
      addTearDown(c2.dispose);
      final q = c2.read(qualityProvider);
      expect(q.tierWifi, QualityTier.high);
      expect(q.tierDownload, QualityTier.low);
      expect(q.tierCellular, QualityTier.high); // untouched default
      expect(
        c.read(sharedPrefsProvider).getString('aria.quality'),
        contains('"tierWifi":"high"'),
      );
    });

    test('corrupt prefs fall back to defaults', () async {
      final c = await containerWith({'aria.quality': 'not json'});
      final q = c.read(qualityProvider);
      expect(q.tierWifi, QualityTier.original);
      expect(q.tierCellular, QualityTier.high);
    });
  });
}
