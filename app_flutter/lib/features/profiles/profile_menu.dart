import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/phosphor_icons.dart';

import '../../core/formats.dart';
import '../../core/theme.dart';
import 'profile_providers.dart';

Color _hex(String c) =>
    Color(int.parse(c.replaceFirst('#', ''), radix: 16) | 0xFF000000);

/// Colored-disc avatar with initials (legacy .avatar).
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.profile, this.size = 28});

  final Profile profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _hex(profile.color),
        shape: BoxShape.circle,
      ),
      child: Text(
        initials(profile.name),
        style: TextStyle(
          fontSize: size * 0.38,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Active-profile switcher (legacy #profile-btn + buildProfileMenu):
/// avatar + name button opening a menu of profiles with edit/delete per row
/// and a "New profile" entry. Drop into the shell's rail leading/trailing or
/// any app bar.
class ProfileMenuButton extends ConsumerWidget {
  const ProfileMenuButton({super.key, this.compact = false});

  /// Avatar only, no name label (narrow layouts).
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeProfileProvider);
    if (active == null) return const SizedBox.shrink();
    final c = AriaColors.of(context);

    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [_ProfileMenuBody(anchorContext: context)],
      builder: (context, controller, _) => InkWell(
        borderRadius: BorderRadius.circular(AriaRadius.pill),
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: Padding(
          padding: const EdgeInsets.all(AriaSpace.s1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ProfileAvatar(profile: active),
              if (!compact) ...[
                const SizedBox(width: AriaSpace.s2),
                Text(active.name, style: TextStyle(color: c.fg)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileMenuBody extends ConsumerWidget {
  const _ProfileMenuBody({required this.anchorContext});

  final BuildContext anchorContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];
    final active = ref.watch(activeProfileProvider);
    final actions = ref.read(profileActionsProvider);
    final c = AriaColors.of(context);

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final p in profiles)
            _ProfileRow(
              profile: p,
              isActive: p.id == active?.id,
              onTap: () => actions.switchTo(p.id),
              onEdit: () => showProfileEditor(anchorContext, ref, profile: p),
              onDelete: () => confirmDeleteProfile(anchorContext, ref, p),
            ),
          InkWell(
            onTap: () => showProfileEditor(anchorContext, ref),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AriaSpace.s3,
                vertical: AriaSpace.s2,
              ),
              child: Text('＋ New profile', style: TextStyle(color: c.fgDim)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.profile,
    required this.isActive,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final Profile profile;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        color: isActive ? c.bgHover : null,
        padding: const EdgeInsets.symmetric(
          horizontal: AriaSpace.s3,
          vertical: AriaSpace.s2,
        ),
        child: Row(
          children: [
            ProfileAvatar(profile: profile),
            const SizedBox(width: AriaSpace.s2),
            Expanded(
              child: Text(
                profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 16),
              visualDensity: VisualDensity.compact,
              tooltip: 'Edit profile',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(PhosphorIconsRegular.x, size: 16),
              visualDensity: VisualDensity.compact,
              tooltip: 'Delete profile',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// Create (profile == null) or edit dialog: name + the 8-color palette
/// (legacy profileForm).
Future<void> showProfileEditor(
  BuildContext context,
  WidgetRef ref, {
  Profile? profile,
}) async {
  final actions = ref.read(profileActionsProvider);
  final result = await showDialog<({String name, String color})>(
    context: context,
    builder: (_) => _ProfileEditorDialog(profile: profile),
  );
  if (result == null) return;
  try {
    if (profile == null) {
      await actions.create(name: result.name, color: result.color);
    } else {
      await actions.rename(profile.id, name: result.name, color: result.color);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save profile. ($e)')));
    }
  }
}

/// Legacy delete confirm: warns that playlists and play history cascade.
Future<void> confirmDeleteProfile(
  BuildContext context,
  WidgetRef ref,
  Profile profile,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete profile "${profile.name}"?'),
      content: const Text('Its playlists and play history go with it.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await ref.read(profileActionsProvider).delete(profile.id);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Cannot delete profile.')));
    }
  }
}

class _ProfileEditorDialog extends StatefulWidget {
  const _ProfileEditorDialog({this.profile});

  final Profile? profile;

  @override
  State<_ProfileEditorDialog> createState() => _ProfileEditorDialogState();
}

class _ProfileEditorDialogState extends State<_ProfileEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.profile?.name ?? '',
  );
  late String _color =
      widget.profile?.color ??
      profilePalette[DateTime.now().microsecond % profilePalette.length];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (name: name, color: _color));
  }

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return AlertDialog(
      title: Text(widget.profile == null ? 'New profile' : 'Edit profile'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 60,
            decoration: const InputDecoration(hintText: 'Profile name'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: AriaSpace.s3),
          Wrap(
            spacing: AriaSpace.s2,
            children: [
              for (final hex in profilePalette)
                InkWell(
                  borderRadius: BorderRadius.circular(AriaRadius.pill),
                  onTap: () => setState(() => _color = hex),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _hex(hex),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: hex == _color ? c.fg : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
