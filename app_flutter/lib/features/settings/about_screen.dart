import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/log.dart';
import '../../core/theme.dart';

/// About: app version and the diagnostics log viewer entry.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: ariaPagePadding(context),
        children: const [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Aria'),
            subtitle: Text('Version $appVersion'),
          ),
          _LogsTile(),
        ],
      ),
    );
  }
}

/// Debug log viewer entry; the list itself is /settings/logs.
class _LogsTile extends StatelessWidget {
  const _LogsTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Logs'),
      subtitle: const Text('Recent app events and errors'),
      onTap: () => context.push('/settings/logs'),
    );
  }
}
