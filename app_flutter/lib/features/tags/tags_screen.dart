import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/library_providers.dart';
import '../../core/theme.dart';
import '../../widgets/art_image.dart';
import '../../widgets/empty_state.dart';
import 'name_dialog.dart';
import 'providers.dart';
import 'tag_tree.dart';

/// Tags screen: folders shown as list sections, tags as a playlists-style grid.
class TagsScreen extends ConsumerWidget {
  const TagsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(tagsProvider);
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(AriaSpace.s6),
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
                  _FolderHeader(all: value, folder: f),
                  const SizedBox(height: AriaSpace.s3),
                  _TagGrid(all: value, tags: tagsInFolder(value, f.id)),
                  const SizedBox(height: AriaSpace.s6),
                ],
                _TagGrid(all: value, tags: looseTags(value)),
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

/// Folder as a list row: name, tag count, delete.
class _FolderHeader extends ConsumerWidget {
  const _FolderHeader({required this.all, required this.folder});

  final List<Tag> all;
  final Tag folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final n = tagsInFolder(all, folder.id).length;
    return Row(
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
      ],
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

/// Playlists-style grid of tag tiles.
class _TagGrid extends StatelessWidget {
  const _TagGrid({required this.all, required this.tags});

  final List<Tag> all;
  final List<Tag> tags;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: AriaBreakpoint.of(context).gridColumns,
        mainAxisSpacing: AriaSpace.s5,
        crossAxisSpacing: AriaSpace.s5,
        childAspectRatio: AriaBreakpoint.of(context) == AriaBreakpoint.tablet
            ? 0.67
            : 0.72,
      ),
      itemCount: tags.length,
      itemBuilder: (context, i) => _TagTile(all: all, tag: tags[i]),
    );
  }
}

/// Grid tile modeled on playlists' _PlaylistTile: album-art collage from the
/// tag's items (album/track), else a tag icon; name + item count underneath.
class _TagTile extends ConsumerWidget {
  const _TagTile({required this.all, required this.tag});

  final List<Tag> all;
  final Tag tag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final n = tag.items.length;

    // Up to four distinct album arts derived from the tag's items.
    final byId = ref.watch(trackByIdProvider);
    final api = ref.read(apiClientProvider);
    final albumIds = <String>{};
    for (final it in tag.items) {
      if (it.kind == 'album') {
        albumIds.add(it.key);
      } else if (it.kind == 'track') {
        final t = byId[it.key];
        if (t != null) albumIds.add(t.albumId);
      }
      if (albumIds.length == 4) break;
    }
    final urls = [for (final a in albumIds) api.artUrl(a)];

    final Widget art;
    if (urls.length >= 4) {
      art = Column(
        children: [
          for (var row = 0; row < 2; row++)
            Expanded(
              child: Row(
                children: [
                  for (var col = 0; col < 2; col++)
                    Expanded(
                      child: ArtImage(
                        url: urls[row * 2 + col],
                        decodeSize: 95,
                        borderRadius: 0,
                      ),
                    ),
                ],
              ),
            ),
        ],
      );
    } else if (urls.isNotEmpty) {
      art = ArtImage(url: urls.first, decodeSize: 190, borderRadius: 0);
    } else {
      art = Container(
        color: c.bgRaised,
        child: Icon(Icons.sell_outlined, size: 36, color: c.fgDim),
      );
    }

    return InkWell(
      onTap: () => context.push('/tags/${tag.id}'),
      onLongPress: () => _actions(context, ref),
      onSecondaryTap: () => _actions(context, ref),
      borderRadius: BorderRadius.circular(AriaRadius.md),
      hoverColor: c.bgHover,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AriaRadius.md),
              child: art,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            tag.name,
            style: const TextStyle(fontWeight: FontWeight.w500),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            '$n item${n == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// Long-press / right-click sheet: rename, move to folder, delete.
  Future<void> _actions(BuildContext context, WidgetRef ref) =>
      showModalBottomSheet<void>(
        context: context,
        builder: (sheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _rename(context, ref);
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_outlined),
                title: const Text('Move to folder…'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _move(context, ref);
                },
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('Delete'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _delete(context, ref);
                },
              ),
            ],
          ),
        ),
      );

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await promptName(
      context,
      title: 'Rename tag',
      initial: tag.name,
      placeholder: 'Tag name',
    );
    if (name == null) return;
    try {
      await ref.read(tagsProvider.notifier).rename(tag.id, name);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e is AriaApiException ? e.message : 'Rename failed.'),
          ),
        );
      }
    }
  }

  /// Move to folder: (No folder) + every folder; ✓ marks the current one.
  Future<void> _move(BuildContext context, WidgetRef ref) async {
    Future<void> setFolder(String? folderId) async {
      try {
        await ref.read(tagsProvider.notifier).setFolder(tag.id, folderId);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                e is AriaApiException ? e.message : 'Could not move tag.',
              ),
            ),
          );
        }
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('(No folder)'),
              trailing: tag.parent == null ? const Icon(Icons.check) : null,
              onTap: () {
                Navigator.of(sheet).pop();
                setFolder(null);
              },
            ),
            for (final f in folders(all))
              ListTile(
                title: Text(f.name),
                trailing: tag.parent == f.id ? const Icon(Icons.check) : null,
                onTap: () {
                  Navigator.of(sheet).pop();
                  setFolder(f.id);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete tag "${tag.name}"?'),
        content: const Text('It comes off everything it was on.'),
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
      await ref.read(tagsProvider.notifier).remove(tag.id);
    } catch (_) {}
  }
}
