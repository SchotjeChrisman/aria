import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../widgets/empty_state.dart';
import 'name_dialog.dart';
import 'providers.dart';
import 'tag_tree.dart';

/// Legacy renderTags(): tree list with rename / nest / delete row tools.
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
                onPressed: () => _create(context, ref),
              ),
            ],
          ),
          const SizedBox(height: AriaSpace.s4),
          switch (tags) {
            AsyncData(:final value) when value.isEmpty => const EmptyState(
              message:
                  'No tags yet — tag any album, artist or track '
                  '(＋ Tag on their pages).',
            ),
            AsyncData(:final value) => Column(
              children: [
                for (final (tag, depth) in _walk(value))
                  _TagRow(all: value, tag: tag, depth: depth),
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

  /// Depth-first walk, siblings by name (legacy walk()).
  static List<(Tag, int)> _walk(List<Tag> all) {
    final out = <(Tag, int)>[];
    void go(String? pid, int depth) {
      final kids = tagKids(all, pid)..sort((a, b) => a.name.compareTo(b.name));
      for (final t in kids) {
        out.add((t, depth));
        go(t.id, depth + 1);
      }
    }

    go(null, 0);
    return out;
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await promptName(
      context,
      title: 'New tag',
      placeholder: 'Tag name',
    );
    if (name == null) return;
    try {
      await ref.read(tagsProvider.notifier).create(name);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              e is AriaApiException ? e.message : 'Could not create tag.',
            ),
          ),
        );
      }
    }
  }
}

class _TagRow extends ConsumerWidget {
  const _TagRow({required this.all, required this.tag, required this.depth});

  final List<Tag> all;
  final Tag tag;
  final int depth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final sub = tagWithDescendants(
      all,
      tag,
    ).fold<int>(0, (s, t) => s + t.items.length);

    return InkWell(
      onTap: () => context.push('/tags/${tag.id}'),
      borderRadius: BorderRadius.circular(AriaRadius.md),
      hoverColor: c.bgHover,
      child: Padding(
        padding: EdgeInsets.only(
          left: AriaSpace.s3 + depth * 26.0,
          right: AriaSpace.s2,
          top: AriaSpace.s1,
          bottom: AriaSpace.s1,
        ),
        child: Row(
          children: [
            if (depth > 0) Text('↳ ', style: TextStyle(color: c.fgDim)),
            Expanded(
              child: Text(
                tag.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '$sub item${sub == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(width: AriaSpace.s2),
            _mini(
              context,
              Icons.edit_outlined,
              'Rename tag',
              () => _rename(context, ref),
            ),
            _mini(
              context,
              Icons.subdirectory_arrow_right,
              'Nest under…',
              () => _nest(context, ref),
            ),
            _mini(
              context,
              Icons.close,
              'Delete tag',
              () => _delete(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mini(
    BuildContext context,
    IconData icon,
    String tooltip,
    VoidCallback onTap,
  ) => IconButton(
    icon: Icon(icon, size: 15, color: AriaColors.of(context).fgDim),
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    onPressed: onTap,
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

  /// Legacy nest menu: (Top level) + every tag except self and descendants
  /// (nesting there would be a cycle); ✓ marks the current parent.
  Future<void> _nest(BuildContext context, WidgetRef ref) async {
    final banned = {for (final t in tagWithDescendants(all, tag)) t.id};
    final options = [
      for (final t in tagsByPath(all))
        if (!banned.contains(t.id)) t,
    ];

    Future<void> setParent(String? parent) async {
      try {
        await ref.read(tagsProvider.notifier).setParent(tag.id, parent);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                e is AriaApiException ? e.message : 'Cannot nest there.',
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
              title: const Text('(Top level)'),
              trailing: tag.parent == null ? const Icon(Icons.check) : null,
              onTap: () {
                Navigator.of(sheet).pop();
                setParent(null);
              },
            ),
            for (final p in options)
              ListTile(
                title: Text(tagPath(all, p)),
                trailing: tag.parent == p.id ? const Icon(Icons.check) : null,
                onTap: () {
                  Navigator.of(sheet).pop();
                  setParent(p.id);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final n = tagKids(all, tag.id).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete tag "${tag.name}"?'),
        content: Text(
          'It comes off everything it was on'
          '${n > 0 ? '; its $n sub-tag${n == 1 ? '' : 's'} move up a level' : ''}.',
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
      await ref.read(tagsProvider.notifier).remove(tag.id);
    } catch (_) {}
  }
}
