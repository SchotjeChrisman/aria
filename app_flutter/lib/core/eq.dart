import 'package:aria_api/aria_api.dart';

/// Compact number: no trailing zeros ("105", "-6.8", "0.7").
String _n(num v) {
  var s = v.toStringAsFixed(2);
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return s;
}

/// Stack two EQ layers into one chain: bands concatenated, preamps summed.
/// Null when both layers are empty. eqToAf() already clamps the summed preamp.
EqProfile? combineEq(EqProfile? h, EqProfile? c) {
  if (h == null && c == null) return null;
  return EqProfile(
    gainDb: (h?.gainDb ?? 0) + (c?.gainDb ?? 0),
    bands: [...?h?.bands, ...?c?.bands],
  );
}

/// [EqProfile] -> mpv `af` string using ffmpeg biquads via lavfi, e.g.
/// 'lavfi=[volume=-6.8dB,equalizer=f=105:t=q:w=0.7:g=3.1]'. The preamp
/// volume element is omitted at 0 dB; unknown band types are skipped;
/// no usable bands -> '' (filter chain cleared).
String eqToAf(EqProfile p) {
  final parts = <String>[];
  for (final b in p.bands) {
    // ponytail: clamp to mpv-safe biquad ranges — out-of-range values make
    // mpv reject the whole lavfi chain silently, and this also caps a
    // hostile/broken OPRA payload.
    final f = _n(b.frequency.clamp(1, 96000));
    final q = _n((b.q ?? 1).clamp(0.1, double.infinity));
    final g = _n(b.gainDb.clamp(-30, 30));
    // ffmpeg low/highpass biquads do at most 2 poles (12 dB/oct): slope 6 is
    // a single pole, steeper slopes cascade round(slope/12) identical stages.
    // ponytail: identical-Q stages droop ~3 dB per extra stage at the cutoff
    // vs a true Butterworth; per-stage Q staging if anyone hears it.
    List<String> pass(String name) {
      final slope = (b.slope ?? 12).clamp(6, 36);
      if (slope < 12) return ['$name=f=$f:p=1'];
      return List.filled((slope / 12).round(), '$name=f=$f:p=2');
    }

    final part = switch (b.type) {
      'peak_dip' => ['equalizer=f=$f:t=q:w=$q:g=$g'],
      'low_shelf' => ['lowshelf=f=$f:t=q:w=$q:g=$g'],
      'high_shelf' => ['highshelf=f=$f:t=q:w=$q:g=$g'],
      'high_pass' => pass('highpass'),
      'low_pass' => pass('lowpass'),
      'band_pass' => ['bandpass=f=$f:t=q:w=$q'],
      'band_stop' => ['bandreject=f=$f:t=q:w=$q'],
      _ => null,
    };
    if (part != null) parts.addAll(part);
  }
  if (parts.isEmpty) return '';
  final pre = p.gainDb.clamp(-24, 24);
  if (pre != 0) parts.insert(0, 'volume=${_n(pre)}dB');
  return 'lavfi=[${parts.join(',')}]';
}
