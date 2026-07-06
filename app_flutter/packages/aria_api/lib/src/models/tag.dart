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

/// Roon-style nestable user label. Parent tags match all descendants' items.
class Tag {
  const Tag({
    required this.id,
    required this.name,
    this.parent,
    this.items = const [],
    this.createdAt,
  });

  final String id;
  final String name;
  final String? parent; // parent tag id
  final List<TagItem> items;
  final String? createdAt;

  factory Tag.fromJson(Map<String, dynamic> j) => Tag(
        id: j['id'] as String,
        name: j['name'] as String,
        parent: asString(j['parent']),
        items: j['items'] is List
            ? (j['items'] as List)
                .whereType<Map<String, dynamic>>()
                .map(TagItem.fromJson)
                .toList()
            : const [],
        createdAt: asString(j['createdAt']),
      );
}
