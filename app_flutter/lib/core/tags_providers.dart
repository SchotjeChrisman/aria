import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection.dart';
import 'tag_tree.dart';

/// Server-side Roon-style tags (legacy allTags + loadTags()). Lives in core
/// so the tag picker in lib/widgets and every feature share one cache.
final tagsProvider = AsyncNotifierProvider<TagsNotifier, List<Tag>>(
  TagsNotifier.new,
);

class TagsNotifier extends AsyncNotifier<List<Tag>> {
  @override
  Future<List<Tag>> build() => ref.watch(apiClientProvider).tags();

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }

  /// `parent` is a folder id; pass `folder: true` to create a folder.
  Future<Tag> create(String name, {String? parent, bool folder = false}) async {
    final tag = await ref
        .read(apiClientProvider)
        .createTag(name, parent: parent, folder: folder);
    await refresh();
    return tag;
  }

  Future<void> rename(String id, String name) async {
    await ref.read(apiClientProvider).updateTag(id, name: name);
    await refresh();
  }

  /// Assign a tag to a folder; null = no folder (top level).
  Future<void> setFolder(String id, String? folderId) async {
    await ref.read(apiClientProvider).updateTag(id, parent: folderId);
    await refresh();
  }

  /// Comes off everything it was on; children move up a level (server rule).
  Future<void> remove(String id) async {
    await ref.read(apiClientProvider).deleteTag(id);
    await refresh();
  }

  /// Legacy toggleTag(): add when missing, remove when present.
  Future<void> toggleItem(Tag tag, String kind, String key) async {
    final client = ref.read(apiClientProvider);
    if (tagHas(tag, kind, key)) {
      await client.removeTagItem(tag.id, kind: kind, key: key);
    } else {
      await client.addTagItem(tag.id, kind: kind, key: key);
    }
    await refresh();
  }

  /// Legacy bulkTagMenu apply: add the tag to every item that lacks it.
  /// Per-item failures are swallowed, matching legacy.
  Future<void> applyToItems(Tag tag, Iterable<TagItem> items) async {
    final client = ref.read(apiClientProvider);
    for (final it in items) {
      if (!tagHas(tag, it.kind, it.key)) {
        try {
          await client.addTagItem(tag.id, kind: it.kind, key: it.key);
        } catch (_) {}
      }
    }
    await refresh();
  }
}
