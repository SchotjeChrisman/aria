import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/phosphor_icons.dart';

import '../core/tag_tree.dart';
import '../core/tags_providers.dart';
import '../core/theme.dart';
import 'name_dialog.dart';

/// Legacy tagPicker(): toggle tags on one item (track / album / artist) with
/// a "New tag…" row. Tags are invisible metadata — assign here, use in
/// filters. Reached from every track/album/artist context menu and the
/// album/artist edit menus.
Future<void> showTagPicker(
  BuildContext context, {
  required String kind, // track | album | artist
  required String key,
}) => showModalBottomSheet<void>(
  context: context,
  builder: (_) => Consumer(
    builder: (context, ref, _) {
      final all = ref.watch(tagsProvider).value ?? const <Tag>[];
      final c = AriaColors.of(context);
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final tag in tagsByPath(all))
              if (!tag.folder)
                ListTile(
                  title: Text(tagPath(all, tag)),
                  trailing: tagHas(tag, kind, key)
                      ? Icon(PhosphorIconsRegular.check, color: c.accent)
                      : null,
                  onTap: () => ref
                      .read(tagsProvider.notifier)
                      .toggleItem(tag, kind, key),
                ),
            ListTile(
              leading: const Icon(PhosphorIconsRegular.plus, size: 18),
              title: Text(all.isEmpty ? 'New tag…' : '＋ New tag…'),
              onTap: () async {
                final name = await promptName(
                  context,
                  title: 'New tag',
                  placeholder: 'Tag name',
                );
                if (name == null) return;
                try {
                  final tag = await ref
                      .read(tagsProvider.notifier)
                      .create(name);
                  await ref.read(tagsProvider.notifier).applyToItems(tag, [
                    TagItem(kind: kind, key: key),
                  ]);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          e is AriaApiException
                              ? e.message
                              : 'Could not create tag.',
                        ),
                      ),
                    );
                  }
                }
              },
            ),
          ],
        ),
      );
    },
  ),
);

/// Legacy bulkTagMenu(): apply one tag to every selected item (each with its
/// own kind/key), with a "New tag…" row. Callers pass the selection as
/// TagItems.
Future<void> showBulkTagMenu(
  BuildContext context, {
  required List<TagItem> items,
}) => showModalBottomSheet<void>(
  context: context,
  builder: (_) => Consumer(
    builder: (context, ref, _) {
      final all = ref.watch(tagsProvider).value ?? const <Tag>[];
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final tag in tagsByPath(all))
              if (!tag.folder)
                ListTile(
                  title: Text(tagPath(all, tag)),
                  onTap: () {
                    Navigator.of(context).pop();
                    ref.read(tagsProvider.notifier).applyToItems(tag, items);
                  },
                ),
            ListTile(
              leading: const Icon(PhosphorIconsRegular.plus, size: 18),
              title: Text(all.isEmpty ? 'New tag…' : '＋ New tag…'),
              onTap: () async {
                final name = await promptName(
                  context,
                  title: 'New tag',
                  placeholder: 'Tag name',
                );
                if (name == null) return;
                try {
                  final notifier = ref.read(tagsProvider.notifier);
                  final tag = await notifier.create(name);
                  await notifier.applyToItems(tag, items);
                  if (context.mounted) Navigator.of(context).pop();
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          e is AriaApiException
                              ? e.message
                              : 'Could not create tag.',
                        ),
                      ),
                    );
                  }
                }
              },
            ),
          ],
        ),
      );
    },
  ),
);
