import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';

/// Settings root: a grouped list of tappable tiles that push detail
/// sub-pages. The actual controls live on those pages (playback/data/
/// library/account/about).
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
              padding: const EdgeInsets.fromLTRB(AriaSpace.s6, AriaSpace.s6,
                  AriaSpace.s6, AriaSpace.s6 + transportFloatInset),
              children: [
                Text(
                  'Settings',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: AriaSpace.s6),
                const _SettingsTile(
                  icon: Icons.play_circle_outline,
                  title: 'Playback',
                  subtitle: 'Exclusive output, EQ',
                  slug: 'playback',
                ),
                const _SettingsTile(
                  icon: Icons.data_usage,
                  title: 'Data & Downloads',
                  subtitle: 'Network limits, streaming & download quality, offline tracks',
                  slug: 'data',
                ),
                const _SettingsTile(
                  icon: Icons.library_music_outlined,
                  title: 'Library',
                  subtitle: 'Rescan and enrich metadata',
                  slug: 'library',
                ),
                const _SettingsTile(
                  icon: Icons.account_circle_outlined,
                  title: 'Account',
                  subtitle: 'Server, scrobbling, profiles',
                  slug: 'account',
                ),
                const _SettingsTile(
                  icon: Icons.info_outline,
                  title: 'About',
                  subtitle: 'Version and diagnostics',
                  slug: 'about',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.slug,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String slug;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/settings/$slug'),
    );
  }
}
