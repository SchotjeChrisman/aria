import 'package:aria/core/connection.dart';
import 'package:aria/features/now_playing/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The bit-perfect default has two halves. The loudness gain being opt-in is the
// first (loudness_af_test.dart); this is the second: mpv's `volume` is software
// gain in the same output chain, so a default below 100 attenuates every sample
// of a fresh install — the legacy slider's 80 is a silent −1.94 dB.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> container(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final sp = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(sp)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a fresh install plays at unity gain', () async {
    final c = await container({});
    expect(c.read(volumeProvider), 100);
  });

  test('a stored volume is respected as given', () async {
    final c = await container({'aria.volume': 62.0});
    expect(c.read(volumeProvider), 62);
  });
}
