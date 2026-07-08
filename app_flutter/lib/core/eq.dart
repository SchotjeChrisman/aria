import 'package:aria_api/aria_api.dart';

/// Compact number: no trailing zeros ("105", "-6.8", "0.7").
String _n(num v) {
  var s = v.toStringAsFixed(2);
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return s;
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
    // ponytail: ffmpeg low/highpass biquads max out at 2 poles — OPRA slope
    // is clamped to 12 dB/oct.
    final part = switch (b.type) {
      'peak_dip' => 'equalizer=f=$f:t=q:w=$q:g=$g',
      'low_shelf' => 'lowshelf=f=$f:t=q:w=$q:g=$g',
      'high_shelf' => 'highshelf=f=$f:t=q:w=$q:g=$g',
      'high_pass' => 'highpass=f=$f:p=2',
      'low_pass' => 'lowpass=f=$f:p=2',
      'band_pass' => 'bandpass=f=$f:t=q:w=$q',
      'band_stop' => 'bandreject=f=$f:t=q:w=$q',
      _ => null,
    };
    if (part != null) parts.add(part);
  }
  if (parts.isEmpty) return '';
  final pre = p.gainDb.clamp(-24, 24);
  if (pre != 0) parts.insert(0, 'volume=${_n(pre)}dB');
  return 'lavfi=[${parts.join(',')}]';
}
