import '../json.dart';

class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.color,
    this.createdAt,
  });

  final String id;
  final String name;
  final String color; // #rrggbb
  final String? createdAt;

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String,
        name: j['name'] as String,
        color: j['color'] as String,
        createdAt: asString(j['createdAt']),
      );
}
