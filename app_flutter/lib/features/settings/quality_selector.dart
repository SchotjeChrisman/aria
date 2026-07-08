import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/quality.dart';
import '../../core/theme.dart';

/// A labelled tier dropdown bound to a [QualityTier]. When the server can't
/// transcode (transcodeAvailableProvider == false) only the original tier is
/// offered and the control is disabled — high/low would 501.
class QualitySelector extends ConsumerWidget {
  const QualitySelector({
    required this.label,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String label;
  final QualityTier value;
  final ValueChanged<QualityTier> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canTranscode = ref.watch(transcodeAvailableProvider);
    final tiers = canTranscode
        ? QualityTier.values
        : const [QualityTier.original];
    // Guard the dropdown assertion: a stored high/low value must map back to
    // something in `tiers` when transcoding is unavailable.
    final effective = tiers.contains(value) ? value : QualityTier.original;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AriaSpace.s2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: AriaSpace.s3),
          DropdownButton<QualityTier>(
            value: effective,
            onChanged: canTranscode
                ? (t) {
                    if (t != null) onChanged(t);
                  }
                : null,
            items: [
              for (final t in tiers)
                DropdownMenuItem(value: t, child: Text(t.label)),
            ],
          ),
        ],
      ),
    );
  }
}
