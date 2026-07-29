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
          const Divider(height: 32),
          const _LoudnessTile(),
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

/// Loudness normalisation. Off by default, and the cost of turning it on is
/// stated in full whether it is on or off — a bit-perfect promise the user
/// only discovers they've broken after the fact isn't a promise.
class _LoudnessTile extends ConsumerWidget {
  const _LoudnessTile();

  static const _options = [
    (
      LoudnessMode.off,
      'Off',
      'Bit-perfect. The decoded audio reaches your device untouched.',
    ),
    (
      LoudnessMode.track,
      'Match tracks',
      'Every track plays at the same loudness. Best for shuffle and mixed '
          'playlists.',
    ),
    (
      LoudnessMode.album,
      'Match albums',
      'One adjustment per album, so quiet and loud tracks within an album keep '
          'the relationship the artist intended.',
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(loudnessProvider);
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Loudness normalisation'),
          subtitle: Text(switch (mode) {
            LoudnessMode.off => 'Off — bit-perfect',
            LoudnessMode.track => 'Match tracks',
            LoudnessMode.album => 'Match albums',
          }),
        ),
        RadioGroup<LoudnessMode>(
          groupValue: mode,
          onChanged: (v) =>
              v == null ? null : ref.read(loudnessProvider.notifier).set(v),
          child: Column(
            children: [
              for (final (value, title, detail) in _options)
                RadioListTile<LoudnessMode>(
                  contentPadding: EdgeInsets.zero,
                  value: value,
                  title: Text(title),
                  subtitle: Text(detail),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Turning this on applies a digital gain inside the player. That is '
          'DSP: the output is no longer bit-perfect, and the signal path in '
          'Now Playing will say so. Your volume slider is unaffected.',
          style: small,
        ),
        const SizedBox(height: 8),
        Text(
          "Tracks that haven't been analysed yet play with no adjustment.",
          style: small,
        ),
        if (mode == LoudnessMode.track) ...[
          const SizedBox(height: 8),
          Text(
            'Gapless transitions are interrupted when two consecutive tracks '
            'need different adjustments. Match albums keeps them.',
            style: small,
          ),
        ],
      ],
    );
  }
}
