import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/phosphor_icons.dart';

import '../../core/eq.dart';
import '../../core/formats.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import 'providers.dart';

/// Signal-path quality tiers — Roon's exact colour grades. Ordered worst-last
/// so `.index` ranks them and the overall dot is the worst stage in the chain.
enum SignalTier {
  bitPerfect(Color(0xFF7C4DFF), 'Lossless'), // purple
  enhanced(Color(0xFF2563EB), 'Enhanced'), // blue
  highQuality(Color(0xFF16A34A), 'High quality'), // green
  lossy(Color(0xFFD97706), 'Lossy'), // amber
  // ponytail: red is Roon's "problem/broken". Reserved until the player
  // exposes a persistent output-failure state to drive it (the audioError
  // stream is a transient event, not a state, so it would only flash).
  problem(Color(0xFFDC2626), 'Problem'); // red

  const SignalTier(this.color, this.label);

  final Color color;
  final String label;
}

/// One node in the chain: [short] rides the compact inline view, [name]/[detail]
/// the expanded sheet.
typedef SignalStage =
    ({String name, String detail, String short, SignalTier tier});

/// A resolved signal path: ordered stages, the overall (worst) tier, the
/// compact one-line chain, and an honest platform caveat.
typedef _Path =
    ({List<SignalStage> stages, SignalTier tier, String chain, String note});

String _khz(int hz) => (hz / 1000).toString().replaceFirst(RegExp(r'\.0$'), '');

/// Source → processing → output, graded per [SignalTier]. The output leg
/// reads mpv's `audio-out-params` (what it hands the OS), and on Android the
/// whole path is downgraded because AudioFlinger mixes everything at 48 kHz
/// — we cannot honestly claim bit-perfect there until a direct USB-DAC path
/// exists.
class SignalPath extends ConsumerWidget {
  const SignalPath({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = _resolvePath(ref);
    if (path == null) return const SizedBox.shrink();
    final c = AriaColors.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(AriaRadius.sm),
      onTap: () => _showPathDetails(context, path),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SignalDot(color: path.tier.color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                path.chain,
                style: TextStyle(
                  fontSize: 12,
                  color: c.fgDim,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Icon(PhosphorIconsRegular.info, size: 13, color: c.fgDim),
          ],
        ),
      ),
    );
  }

}

/// Just the coloured quality dot, tappable to the same signal-path sheet.
/// Lives beside the transport controls; the full chain is the sheet.
class SignalPathDot extends ConsumerWidget {
  const SignalPathDot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = _resolvePath(ref);
    if (path == null) return const SizedBox.shrink();
    return InkWell(
      borderRadius: BorderRadius.circular(AriaRadius.pill),
      onTap: () => _showPathDetails(context, path),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Tooltip(
          message: path.tier.label,
          // Small solid dot inside a translucent halo of the same tier colour.
          child: Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: path.tier.color.withValues(alpha: 0.2),
            ),
            child: SignalDot(color: path.tier.color, size: 7),
          ),
        ),
      ),
    );
  }
}

_Path? _resolvePath(WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final radio = track == null ? ref.watch(radioPlaybackProvider) : null;
    if (track == null && radio == null) return null;
    final fmt = ref.watch(playbackFormatProvider).value;
    final eqActive = ref.watch(eqProvider).active;
    final ao = ref.watch(audioDeviceProvider).value;
    // AudioFlinger sits below every app; the USB DAC path that would bypass it
    // isn't wired yet, so Android can't be graded bit-perfect on the normal
    // route. ponytail: lift this gate once a direct USB output path lands.
    final onAndroid = defaultTargetPlatform == TargetPlatform.android;

    final stages = <SignalStage>[];
    var worst = SignalTier.bitPerfect;
    void bump(SignalTier t) {
      if (t.index > worst.index) worst = t;
    }

    if (radio != null) {
      final lossless = radio.url.toLowerCase().contains('flac');
      final tier = lossless ? SignalTier.bitPerfect : SignalTier.lossy;
      stages.add((
        name: 'Source',
        detail: lossless ? 'FLAC stream' : 'Streaming · lossy',
        short: 'STREAM',
        tier: tier,
      ));
      bump(tier);
      if (eqActive) {
        stages.add((
          name: 'EQ',
          detail: 'Parametric EQ',
          short: 'EQ',
          tier: SignalTier.enhanced,
        ));
        bump(SignalTier.enhanced);
      }
    } else {
      final t = track!;
      final src = formatBadgeText(
        format: t.format,
        bitsPerSample: t.bitsPerSample,
        sampleRate: t.sampleRate,
      );
      final tier = t.lossless ? SignalTier.bitPerfect : SignalTier.lossy;
      stages.add((
        name: 'Source',
        detail: '${src.isEmpty ? 'Audio' : src} · ${t.lossless ? 'lossless' : 'lossy'}',
        short: src.isEmpty ? 'AUDIO' : src,
        tier: tier,
      ));
      bump(tier);

      if (eqActive) {
        stages.add((
          name: 'EQ',
          detail: 'Parametric EQ',
          short: 'EQ',
          tier: SignalTier.enhanced,
        ));
        bump(SignalTier.enhanced);
      }

      // Keyed off the gain ACTUALLY on the chain, not off the setting: an
      // unanalysed track under normalisation gets no gain and still reads
      // bit-perfect, truthfully — and a normalised one can never read
      // bit-perfect while a volume element is multiplying its samples.
      final gain = appliedGain(gainFor(t, ref.watch(loudnessProvider)));
      if (gain != null) {
        stages.add((
          name: 'Gain',
          detail: '${gain.toStringAsFixed(2)} dB · loudness normalisation',
          short: 'GAIN',
          tier: SignalTier.enhanced,
        ));
        bump(SignalTier.enhanced);
      }

      // mpv's `volume` is software gain in the same output chain, so anything
      // below unity is DSP by exactly the same argument as the line above. It
      // is not shown as a stage — the user set it deliberately and knows where
      // the slider is — but it must not be allowed to read as bit-perfect.
      if (ref.watch(volumeProvider) < 100) {
        bump(SignalTier.enhanced);
      }

      // Resample: mpv's real output rate vs. the source rate.
      final outRate = fmt?.outSampleRate ?? fmt?.sampleRate;
      final srcRate = t.sampleRate;
      if (outRate != null && srcRate != null && outRate != srcRate) {
        stages.add((
          name: 'Resample',
          detail: '${_khz(srcRate)} → ${_khz(outRate)} kHz',
          short: '${_khz(outRate)}kHz',
          tier: SignalTier.highQuality,
        ));
        bump(SignalTier.highQuality);
      }

      // Requantise: mpv narrows the word length.
      final outBits = fmt?.outBitDepth;
      final srcBits = t.bitsPerSample;
      if (outBits != null && srcBits != null && outBits < srcBits) {
        stages.add((
          name: 'Requantise',
          detail: '$srcBits → $outBits-bit',
          short: '${outBits}bit',
          tier: SignalTier.highQuality,
        ));
        bump(SignalTier.highQuality);
      }
    }

    final String note;
    if (onAndroid) {
      // Never claim bit-perfect through AudioFlinger's shared 48 kHz mixer.
      if (worst.index < SignalTier.highQuality.index) {
        bump(SignalTier.highQuality);
      }
      note = 'Android mixes all audio (typically at 48 kHz), so bit-perfect '
          'isn\'t guaranteed. A direct USB-DAC output path would remove this.';
    } else {
      note = 'The output rate is what the player hands the system. Guaranteed '
          'bit-perfect needs an exclusive-mode device path.';
    }

    stages.add((
      name: 'Output',
      detail: [
        'mpv',
        if (ao != null && ao.isNotEmpty) ao,
      ].join(' · '),
      short: 'mpv',
      tier: worst,
    ));

    final chain = stages.map((s) => s.short).join(' → ');
    return (stages: stages, tier: worst, chain: chain, note: note);
  }

void _showPathDetails(BuildContext context, _Path path) {
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      builder: (context) {
        final c = AriaColors.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AriaSpace.s5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Signal path',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    SignalTierChip(tier: path.tier),
                  ],
                ),
                const SizedBox(height: AriaSpace.s4),
                for (final (i, s) in path.stages.indexed)
                  SignalStageRow(
                    stage: s,
                    first: i == 0,
                    last: i == path.stages.length - 1,
                  ),
                const SizedBox(height: AriaSpace.s3),
                Text(
                  path.note,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall!.copyWith(color: c.fgDim),
                ),
                const SizedBox(height: AriaSpace.s4),
                // Legend of every grade (Roon's colour key).
                Wrap(
                  spacing: AriaSpace.s3,
                  runSpacing: AriaSpace.s2,
                  children: [
                    for (final t in SignalTier.values)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SignalDot(color: t.color, size: 8),
                          const SizedBox(width: 5),
                          Text(
                            t.label,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
}

class SignalDot extends StatelessWidget {
  const SignalDot({super.key, required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}

/// A vertical chain node: a rail (line · dot · line) beside name + detail.
class SignalStageRow extends StatelessWidget {
  const SignalStageRow({
    super.key,
    required this.stage,
    required this.first,
    required this.last,
  });

  final SignalStage stage;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    Widget rail(bool hidden) => Expanded(
      child: Center(
        child: Container(
          width: 2,
          color: hidden ? Colors.transparent : c.lineStrong,
        ),
      ),
    );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 18,
            child: Column(
              children: [
                rail(first),
                SignalDot(color: stage.tier.color, size: 11),
                rail(last),
              ],
            ),
          ),
          const SizedBox(width: AriaSpace.s3),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stage.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(stage.detail, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The overall-quality pill (Roon's coloured label).
class SignalTierChip extends StatelessWidget {
  const SignalTierChip({super.key, required this.tier});

  final SignalTier tier;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: tier.color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(AriaRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SignalDot(color: tier.color, size: 8),
        const SizedBox(width: 6),
        Text(
          tier.label,
          style: TextStyle(
            color: tier.color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}
