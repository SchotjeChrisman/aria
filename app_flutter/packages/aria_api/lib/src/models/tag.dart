import '../json.dart';

/// What a tag item points at.
const tagKinds = ['track', 'album', 'artist'];

class TagItem {
  const TagItem({required this.kind, required this.key});

  final String kind; // track | album | artist
  final String key; // trackId | albumId | free-form artist name

  factory TagItem.fromJson(Map<String, dynamic> j) =>
      TagItem(kind: j['kind'] as String, key: j['key'] as String);

  Map<String, dynamic> toJson() => {'kind': kind, 'key': key};
}

/// User label. Tags live in one-level folders: `parent` is the folder id (null
/// = no folder). A folder is a tag with `folder == true` that holds tags, not
/// items — folders never nest.
class Tag {
  const Tag({
    required this.id,
    required this.name,
    this.parent,
    this.folder = false,
    this.items = const [],
    this.createdAt,
  });

  final String id;
  final String name;
  final String? parent; // folder id (one level), null = no folder
  final bool folder; // a folder holds tags, never items
  final List<TagItem> items;
  final String? createdAt;

  factory Tag.fromJson(Map<String, dynamic> j) => Tag(
        id: j['id'] as String,
        name: j['name'] as String,
        parent: asString(j['parent']),
        folder: j['folder'] == true,
        items: j['items'] is List
            ? (j['items'] as List)
                .whereType<Map<String, dynamic>>()
                .map(TagItem.fromJson)
                .toList()
            : const [],
        createdAt: asString(j['createdAt']),
      );
}
