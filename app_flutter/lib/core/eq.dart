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
String eqToAf(EqProfile p) => buildAf(p, null);

/// The loudness gain [buildAf] will actually emit for [gainDb], or null when
/// it emits nothing at all. The Now Playing signal path keys its Gain stage
/// off THIS, not off the setting, so an unanalysed track under normalisation
/// still reads bit-perfect — truthfully.
///
/// ponytail: attenuate only, so normalisation can never clip. ReplayGain 2.0
/// ships a true-peak figure precisely so a player can boost safely, and the
/// server measures and serves it (Track.trackPeak), but nothing reads it yet;
/// until it does, a quiet track stays quiet rather than risking a clipped loud
/// one. Upgrade: allow up to -20*log10(peak) dB of positive gain.
double? appliedGain(double? gainDb) {
  // mpv stores any af string at set time and only rejects it at load, where it
  // surfaces as a dead-audio stop rather than an ignored filter — so a NaN or
  // infinite gain must die here, not in the chain.
  if (gainDb == null || gainDb.isNaN || gainDb.isInfinite) return null;
  final g = gainDb.clamp(-24.0, 0.0).toDouble();
  // Anything that renders as '-0' at _n's two decimals is an identity
  // multiply; emitting it costs a real filter stage (mpv converts to float and
  // back) and makes the signal path read 'Gain -0.00 dB' for nothing. A track
  // measured at -17.999 LUFS lands exactly here.
  return g > -0.005 ? null : g;
}

/// af chain = loudness gain, then the EQ chain. Returns exactly what
/// [eqToAf] returns when [gainDb] is null or produces no element, so the
/// bit-perfect default path is the same bytes it has always been.
///
/// The gain is its own leading `volume=` element rather than being summed into
/// the EQ preamp: ffmpeg multiplies the two stages anyway, and keeping them
/// separate leaves the EQ portion a verbatim substring, which is what makes
/// "normalisation off is byte-identical" a one-line assertion.
String buildAf(EqProfile? eq, double? gainDb) {
  final parts = eq == null ? <String>[] : _eqParts(eq);
  if (parts.isNotEmpty) {
    final pre = eq!.gainDb.clamp(-24, 24);
    if (pre != 0) parts.insert(0, 'volume=${_n(pre)}dB');
  }
  final g = appliedGain(gainDb);
  if (g != null) parts.insert(0, 'volume=${_n(g)}dB');
  if (parts.isEmpty) return '';
  return 'lavfi=[${parts.join(',')}]';
}

/// The band elements of [p], in order. No preamp, no lavfi wrapper.
List<String> _eqParts(EqProfile p) {
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
  return parts;
}
