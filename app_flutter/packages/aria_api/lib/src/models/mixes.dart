import '../json.dart';

/// `/api/mixes` response: four ranked trackId lists per profile.
class Mixes {
  const Mixes({
    this.daily = const [],
    this.weekly = const [],
    this.monthly = const [],
    this.yearly = const [],
  });

  final List<String> daily;
  final List<String> weekly;
  final List<String> monthly;
  final List<String> yearly;

  factory Mixes.fromJson(Map<String, dynamic> j) => Mixes(
        daily: asStringList(j['daily']),
        weekly: asStringList(j['weekly']),
        monthly: asStringList(j['monthly']),
        yearly: asStringList(j['yearly']),
      );
}
