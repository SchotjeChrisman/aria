import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../widgets/empty_state.dart';
import 'name_dialog.dart';
import 'providers.dart';
import 'tag_grid.dart';
import 'tag_tree.dart';

/// Tags screen: folders shown as list sections, tags as a playlists-style grid.
class TagsScreen extends ConsumerWidget {
  const TagsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(tagsProvider);
    return Scaffold(
      body: ListView(
        padding: ariaPagePadding(context),
        children: [
          Text('Tags', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AriaSpace.s4),
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Tag'),
                onPressed: () => _create(context, ref, folder: false),
              ),
              const SizedBox(width: AriaSpace.s3),
              OutlinedButton.icon(
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('Folder'),
                onPressed: () => _create(context, ref, folder: true),
              ),
            ],
          ),
          const SizedBox(height: AriaSpace.s5),
          switch (tags) {
            AsyncData(:final value) when value.isEmpty => const EmptyState(
              message:
                  'No tags yet — tag any album, artist or track '
                  '(＋ Tag on their pages).',
            ),
            AsyncData(:final value) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final f in folders(value)) ...[
                  _FolderRow(all: value, folder: f),
                  const SizedBox(height: AriaSpace.s3),
                ],
                if (folders(value).isNotEmpty)
                  const SizedBox(height: AriaSpace.s3),
                TagGrid(all: value, tags: looseTags(value)),
              ],
            ),
            AsyncError() => const EmptyState(message: 'Tags unavailable.'),
            _ => const Padding(
              padding: EdgeInsets.all(AriaSpace.s10),
              child: Center(child: CircularProgressIndicator()),
            ),
          },
        ],
      ),
    );
  }

  Future<void> _create(
    BuildContext context,
    WidgetRef ref, {
    required bool folder,
  }) async {
    final name = await promptName(
      context,
      title: folder ? 'New folder' : 'New tag',
      placeholder: folder ? 'Folder name' : 'Tag name',
    );
    if (name == null) return;
    try {
      await ref.read(tagsProvider.notifier).create(name, folder: folder);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is AriaApiException
                  ? e.message
                  : 'Could not create ${folder ? 'folder' : 'tag'}.',
            ),
          ),
        );
      }
    }
  }
}

/// Folder as a navigable list row: name, tag count, delete. Tapping enters
/// the folder (its tags aren't shown inline).
class _FolderRow extends ConsumerWidget {
  const _FolderRow({required this.all, required this.folder});

  final List<Tag> all;
  final Tag folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final n = tagsInFolder(all, folder.id).length;
    return InkWell(
      onTap: () => context.push('/tags/${folder.id}'),
      borderRadius: BorderRadius.circular(AriaRadius.md),
      hoverColor: c.bgHover,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AriaSpace.s1),
        child: Row(
          children: [
            Icon(Icons.folder_outlined, size: 18, color: c.fgDim),
            const SizedBox(width: AriaSpace.s2),
            Expanded(
              child: Text(
                folder.name,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '$n tag${n == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            IconButton(
              icon: Icon(Icons.close, size: 15, color: c.fgDim),
              tooltip: 'Delete folder',
              visualDensity: VisualDensity.compact,
              onPressed: () => _deleteFolder(context, ref),
            ),
            Icon(Icons.chevron_right, size: 18, color: c.fgDim),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteFolder(BuildContext context, WidgetRef ref) async {
    final n = tagsInFolder(all, folder.id).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete folder "${folder.name}"?'),
        content: Text(
          n > 0
              ? 'Its $n tag${n == 1 ? '' : 's'} move out to the top level.'
              : 'The empty folder is removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(tagsProvider.notifier).remove(folder.id);
    } catch (_) {}
  }
}
