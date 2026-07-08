import 'package:aria_api/aria_api.dart';
import 'package:aria/core/eq.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every band type maps to its ffmpeg filter', () {
    const p = EqProfile(gainDb: -6.8, bands: [
      EqBand(type: 'peak_dip', frequency: 105, gainDb: 3.1, q: 0.7),
      EqBand(type: 'low_shelf', frequency: 105, gainDb: -1.4, q: 0.7),
      EqBand(type: 'high_shelf', frequency: 10000, gainDb: 2.25, q: 0.7),
      EqBand(type: 'high_pass', frequency: 20, slope: 24),
      EqBand(type: 'low_pass', frequency: 18000, slope: 12),
      EqBand(type: 'band_pass', frequency: 1000, q: 2),
      EqBand(type: 'band_stop', frequency: 60, q: 4),
      EqBand(type: 'weird_future_type', frequency: 1), // skipped
    ]);
    expect(
      eqToAf(p),
      'lavfi=[volume=-6.8dB,'
      'equalizer=f=105:t=q:w=0.7:g=3.1,'
      'lowshelf=f=105:t=q:w=0.7:g=-1.4,'
      'highshelf=f=10000:t=q:w=0.7:g=2.25,'
      'highpass=f=20:p=2,'
      'lowpass=f=18000:p=2,'
      'bandpass=f=1000:t=q:w=2,'
      'bandreject=f=60:t=q:w=4]',
    );
  });

  test('zero preamp omits the volume element', () {
    const p = EqProfile(bands: [
      EqBand(type: 'peak_dip', frequency: 105, gainDb: 3, q: 0.7),
    ]);
    expect(eqToAf(p), 'lavfi=[equalizer=f=105:t=q:w=0.7:g=3]');
  });

  test('out-of-range values are clamped to mpv-safe ranges', () {
    const p = EqProfile(gainDb: -99, bands: [
      EqBand(type: 'peak_dip', frequency: 0, gainDb: 100, q: 0),
      EqBand(type: 'peak_dip', frequency: 200000, gainDb: -100, q: 5),
    ]);
    expect(
      eqToAf(p),
      'lavfi=[volume=-24dB,'
      'equalizer=f=1:t=q:w=0.1:g=30,'
      'equalizer=f=96000:t=q:w=5:g=-30]',
    );
  });

  test('no usable bands clears the chain', () {
    expect(eqToAf(const EqProfile(gainDb: -4)), '');
    expect(
      eqToAf(const EqProfile(gainDb: -4, bands: [
        EqBand(type: 'unknown', frequency: 1),
      ])),
      '',
    );
  });
}
