import 'dart:convert';

import 'package:aria/core/connection.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria_api/aria_api.dart';
import 'package:aria_player/aria_player.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// EqNotifier.apply() reads ariaPlayerProvider; stub it so build() has an
/// engine to push the chain to. No-op — the migration test only reads state.
class _FakePlayer extends Fake implements AriaPlayer {
  @override
  void setAudioFilter(String af) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> container(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final sp = await SharedPreferences.getInstance();
    return ProviderContainer(overrides: [
      sharedPrefsProvider.overrideWithValue(sp),
      ariaPlayerProvider.overrideWithValue(_FakePlayer()),
    ]);
  }

  const preset = EqProfile(
    name: 'Sennheiser HD650',
    gainDb: -6,
    bands: [EqBand(type: 'peak_dip', frequency: 100, gainDb: 2, q: 1)],
  );

  test('old flat aria.eq shape loads into the headphone slot', () async {
    final c = await container({
      // Legacy flat shape: {enabled} + flattened EqProfile fields.
      'aria.eq': jsonEncode({'enabled': true, ...preset.toJson()}),
    });
    final eq = c.read(eqProvider);
    expect(eq.enabled, true);
    expect(eq.headphone?.name, 'Sennheiser HD650');
    expect(eq.custom, isNull);
  });

  test('new two-slot shape round-trips', () async {
    final c = await container({
      'aria.eq': jsonEncode({
        'enabled': false,
        'headphone': preset.toJson(),
        'custom': const EqProfile(name: 'Bass', gainDb: 3).toJson(),
      }),
    });
    final eq = c.read(eqProvider);
    expect(eq.enabled, false);
    expect(eq.headphone?.name, 'Sennheiser HD650');
    expect(eq.custom?.name, 'Bass');
  });
}
