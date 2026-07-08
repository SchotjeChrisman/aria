import 'dart:io';

import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../profiles/profiles_section.dart';
import 'settings_providers.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            // Readable measure on tablet/desktop; no-op on mobile.
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(AriaSpace.s6),
              children: [
                Text(
                  'Settings',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: AriaSpace.s6),
                const _Section(title: 'Server', child: _ServerUrlField()),
                _Section(
                  title: 'Playback',
                  child: Column(
                    children: [
                      // Exclusive access is a desktop-only mpv option (the
                      // engine no-ops it on Android) — a dead switch just
                      // misleads.
                      if (!Platform.isAndroid) const _ExclusiveToggle(),
                      const _EqTile(),
                    ],
                  ),
                ),
                const _Section(
                  title: 'Scrobbling',
                  child: _ListenBrainzField(),
                ),
                const _Section(title: 'Library', child: _LibraryTools()),
                const _Section(title: 'Profiles', child: ProfilesSection()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AriaSpace.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AriaSpace.s3),
          child,
        ],
      ),
    );
  }
}

/// Server URL — same normalize + probe flow as first-run setup; saving
/// repoints every api-backed provider via serverUrlProvider.
class _ServerUrlField extends ConsumerStatefulWidget {
  const _ServerUrlField();

  @override
  ConsumerState<_ServerUrlField> createState() => _ServerUrlFieldState();
}

class _ServerUrlFieldState extends ConsumerState<_ServerUrlField> {
  late final TextEditingController _ctrl = TextEditingController(
    text: ref.read(serverUrlProvider) ?? kDefaultServerUrl,
  );
  bool _busy = false;
  String? _note;
  bool _failed = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _note = null;
      _failed = false;
    });
    final url = normalizeServerUrl(_ctrl.text);
    final client = AriaClient(baseUrl: url);
    try {
      final status = await client.status();
      await ref.read(serverUrlProvider.notifier).set(url);
      if (mounted) {
        setState(() => _note = 'Connected — ${status.tracks} tracks.');
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _note = 'Could not reach the server at $url — not saved.';
        });
      }
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(hintText: kDefaultServerUrl),
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: AriaSpace.s3),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'Testing…' : 'Save'),
            ),
          ],
        ),
        if (_note != null)
          Padding(
            padding: const EdgeInsets.only(top: AriaSpace.s2),
            child: Text(
              _note!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _failed ? theme.colorScheme.error : null,
              ),
            ),
          ),
      ],
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

class _ListenBrainzField extends ConsumerStatefulWidget {
  const _ListenBrainzField();

  @override
  ConsumerState<_ListenBrainzField> createState() => _ListenBrainzFieldState();
}

class _ListenBrainzFieldState extends ConsumerState<_ListenBrainzField> {
  final _ctrl = TextEditingController();
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      // Trimmed empty token deletes the stored one (server semantics).
      await ref
          .read(apiClientProvider)
          .saveSettings(listenbrainzToken: _ctrl.text.trim());
      ref.invalidate(serverSettingsProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Saved.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save settings.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Seed the field once from the server (legacy openSettings fetch).
    final settings = ref.watch(serverSettingsProvider);
    if (!_loaded && settings.hasValue) {
      _ctrl.text = settings.requireValue.listenbrainzToken;
      _loaded = true;
    }

    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            obscureText: true,
            decoration: const InputDecoration(
              hintText: 'ListenBrainz token (blank to disable scrobbling)',
            ),
            onSubmitted: (_) => _save(),
          ),
        ),
        const SizedBox(width: AriaSpace.s3),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _LibraryTools extends ConsumerWidget {
  const _LibraryTools();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(scanControllerProvider);
    final enrich = ref.watch(enrichStatusProvider).value;
    final theme = Theme.of(context);

    final enrichBusy = enrich != null && enrich.phase != 'idle';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: scan.running
                  ? null
                  : () => ref.read(scanControllerProvider.notifier).start(),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(scan.running ? 'Scanning…' : 'Rescan library'),
            ),
            const SizedBox(width: AriaSpace.s3),
            if (scan.running)
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: scan.total > 0 ? scan.done / scan.total : null,
                        minHeight: 4,
                      ),
                    ),
                    const SizedBox(width: AriaSpace.s2),
                    Text(
                      scan.total > 0 ? '${scan.done}/${scan.total}' : '…',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              )
            else if (scan.error != null)
              Expanded(
                child: Text(
                  'Scan failed.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              )
            else if (scan.lastTracks != null)
              Text(
                '${scan.lastTracks} tracks.',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
        const SizedBox(height: AriaSpace.s3),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: enrichBusy
                  ? null
                  : () async {
                      try {
                        await ref.read(apiClientProvider).kickEnrich();
                      } catch (_) {
                        /* status poll shows reality */
                      }
                    },
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('Enrich metadata'),
            ),
            const SizedBox(width: AriaSpace.s3),
            Text(
              enrichBusy
                  ? '✨ ${enrich.phase} ${enrich.done}/${enrich.total}'
                  : 'Enrichment idle.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }
}
