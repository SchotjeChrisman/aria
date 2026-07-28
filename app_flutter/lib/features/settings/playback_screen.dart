import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/player_providers.dart';
import '../../core/theme.dart';

/// Playback settings: exclusive output and headphone EQ.
class PlaybackScreen extends ConsumerWidget {
  const PlaybackScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playback')),
      body: ListView(
        padding: ariaPagePadding(context),
        children: [
          // Exclusive access is a desktop-only mpv option (Android's mixer and
          // iOS's audiounit ao both ignore it) — a dead switch just misleads.
          if (!Platform.isAndroid && !Platform.isIOS) const _ExclusiveToggle(),
          const _EqTile(),
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
    // mpv renames the output when exclusive actually engages (macOS reports
    // "coreaudio_exclusive" instead of "coreaudio"), and silently ignores the
    // option on outputs that don't support it at all — ALSA and PulseAudio
    // among them. Showing the live ao is the only honest feedback: the switch
    // alone says nothing about whether the device agreed.
    final ao = ref.watch(audioDeviceProvider).value;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Exclusive audio access'),
      subtitle: Text(
        'Bit-perfect output: the audio device is opened exclusively '
        '(desktop only; other apps go silent while playing).'
        '\nOutput in use: ${ao == null || ao.isEmpty ? '— (play something)' : ao}',
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
    final hasLayer = eq.headphone != null || eq.custom != null;
    // Summarize the active layers; nothing set reads as 'Off'.
    final summary = [
      if (eq.headphone != null) eq.headphone!.name ?? 'Headphone',
      if (eq.custom != null) eq.custom!.name ?? 'Custom',
    ].join(' + ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Headphone EQ'),
      subtitle: Text(hasLayer ? summary : 'Off'),
      trailing: Switch(
        value: eq.enabled,
        // No layer selected: nothing to enable.
        onChanged: hasLayer
            ? (v) => ref.read(eqProvider.notifier).setEnabled(v)
            : null,
      ),
      onTap: () => context.push('/settings/eq'),
    );
  }
}
