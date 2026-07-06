import 'package:aria_api/aria_api.dart';

/// Pure ports of the legacy tag-hierarchy helpers (app.js tagById /
/// tagChainNames / tagPath / tagKids / tagWithDescendants / tagHas).
/// Tags nest via .parent (tag id); parents match all descendants' items.

Tag? tagById(List<Tag> all, String? id) {
  if (id == null) return null;
  for (final t in all) {
    if (t.id == id) return t;
  }
  return null;
}

/// Name + ancestors, leaf first.
List<String> tagChainNames(List<Tag> all, Tag tag) {
  final names = <String>[];
  Tag? t = tag;
  while (t != null) {
    names.add(t.name);
    t = tagById(all, t.parent);
  }
  return names;
}

/// Root-first breadcrumb, e.g. "Moods / Calm".
String tagPath(List<Tag> all, Tag tag) =>
    tagChainNames(all, tag).reversed.join(' / ');

/// Direct children; pass null for the top level.
List<Tag> tagKids(List<Tag> all, String? id) => [
  for (final t in all)
    if (t.parent == id) t,
];

/// The tag plus every descendant, depth-first.
List<Tag> tagWithDescendants(List<Tag> all, Tag tag) {
  final out = [tag];
  for (final k in tagKids(all, tag.id)) {
    out.addAll(tagWithDescendants(all, k));
  }
  return out;
}

bool tagHas(Tag tag, String kind, String key) =>
    tag.items.any((i) => i.kind == kind && i.key == key);

/// Tags sorted by full path, the pick-list order used everywhere in legacy.
List<Tag> tagsByPath(List<Tag> all) =>
    [...all]..sort((a, b) => tagPath(all, a).compareTo(tagPath(all, b)));
