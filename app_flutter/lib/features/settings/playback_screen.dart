import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/player_providers.dart';
import '../../core/quality.dart';
import '../../core/theme.dart';
import 'quality_selector.dart';

/// Playback settings: exclusive output, headphone EQ, and streaming quality
/// tiers per network kind.
class PlaybackScreen extends ConsumerWidget {
  const PlaybackScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final quality = ref.watch(qualityProvider);
    final notifier = ref.read(qualityProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Playback')),
      body: ListView(
        padding: const EdgeInsets.all(AriaSpace.s6),
        children: [
          // Exclusive access is a desktop-only mpv option (the engine no-ops
          // it on Android) — a dead switch just misleads.
          if (!Platform.isAndroid) const _ExclusiveToggle(),
          const _EqTile(),
          const SizedBox(height: AriaSpace.s6),
          Text('Streaming quality', style: theme.textTheme.titleMedium),
          const SizedBox(height: AriaSpace.s2),
          QualitySelector(
            label: 'Wi-Fi',
            value: quality.tierWifi,
            onChanged: (t) =>
                notifier.set(quality.copyWith(tierWifi: t)),
          ),
          QualitySelector(
            label: 'Cellular',
            value: quality.tierCellular,
            onChanged: (t) =>
                notifier.set(quality.copyWith(tierCellular: t)),
          ),
        ],
      ),
    );
  }
}

class _ExclusiveToggle extends ConsumerWidget {
  const _ExclusiveToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(audioExclusiveProvider);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Exclusive audio access'),
      subtitle: const Text(
        'Bit-perfect output: the audio device is opened exclusively '
        '(desktop only; other apps go silent while playing).',
      ),
      value: on,
      onChanged: (v) => ref.read(audioExclusiveProvider.notifier).set(v),
    );
  }
}

/// Active headphone-EQ profile + on/off switch; the picker is /settings/eq.
class _EqTile extends ConsumerWidget {
  const _EqTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eq = ref.watch(eqProvider);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Headphone EQ'),
      subtitle: Text(eq.profile?.name ?? 'Off'),
      trailing: Switch(
        value: eq.enabled,
        // No profile selected: nothing to enable.
        onChanged: eq.profile == null
            ? null
            : (v) => ref.read(eqProvider.notifier).setEnabled(v),
      ),
      onTap: () => context.push('/settings/eq'),
    );
  }
}
