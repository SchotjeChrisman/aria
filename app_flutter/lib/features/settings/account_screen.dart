import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/theme.dart';
import '../profiles/profiles_section.dart';
import 'settings_providers.dart';

/// Account settings: server URL, ListenBrainz scrobbling, and listener
/// profiles.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    Widget header(String t) => Padding(
      padding: const EdgeInsets.only(bottom: AriaSpace.s3),
      child: Text(t, style: theme.textTheme.titleMedium),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.all(AriaSpace.s6),
        children: [
          header('Server'),
          const _ServerUrlField(),
          const SizedBox(height: AriaSpace.s8),
          header('Scrobbling'),
          const _ListenBrainzField(),
          const SizedBox(height: AriaSpace.s8),
          header('Profiles'),
          const ProfilesSection(),
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
