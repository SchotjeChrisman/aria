import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'profile_menu.dart';
import 'profile_providers.dart';

/// Inline profile list with CRUD — embedded in the Settings page so profiles
/// stay reachable even before the shell hosts [ProfileMenuButton].
class ProfilesSection extends ConsumerWidget {
  const ProfilesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    final active = ref.watch(activeProfileProvider);
    final actions = ref.read(profileActionsProvider);
    final c = AriaColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        switch (profiles) {
          AsyncData(:final value) => Column(
            children: [
              for (final p in value)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AriaSpace.s2,
                  ),
                  leading: ProfileAvatar(profile: p),
                  title: Text(p.name),
                  subtitle: p.id == active?.id
                      ? Text('Active', style: TextStyle(color: c.accent))
                      : null,
                  onTap: () => actions.switchTo(p.id),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: 'Edit profile',
                        onPressed: () =>
                            showProfileEditor(context, ref, profile: p),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Delete profile',
                        onPressed: () => confirmDeleteProfile(context, ref, p),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          AsyncError() => Text(
            'Profiles unavailable.',
            style: TextStyle(color: c.fgDim),
          ),
          _ => const Padding(
            padding: EdgeInsets.all(AriaSpace.s3),
            child: Center(child: CircularProgressIndicator()),
          ),
        },
        TextButton(
          onPressed: () => showProfileEditor(context, ref),
          child: const Text('＋ New profile'),
        ),
      ],
    );
  }
}
