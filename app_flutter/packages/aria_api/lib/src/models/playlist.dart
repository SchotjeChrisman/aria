import '../json.dart';

/// Valid smart-rule fields -> allowed ops (mirrors server RULE_FIELDS).
const smartRuleFields = <String, List<String>>{
  'title': ['is', 'isNot', 'contains', 'anyOf', 'allOf'],
  'artist': ['is', 'isNot', 'contains', 'anyOf', 'allOf'],
  'albumArtist': ['is', 'isNot', 'contains', 'anyOf', 'allOf'],
  'album': ['is', 'isNot', 'contains', 'anyOf', 'allOf'],
  'genre': ['is', 'isNot', 'contains', 'anyOf', 'allOf'],
  'composer': ['is', 'isNot', 'contains', 'anyOf', 'allOf'],
  'format': ['is', 'isNot', 'contains', 'anyOf', 'allOf'],
  'credited': ['is', 'isNot', 'contains', 'anyOf', 'allOf'],
  'year': ['is', 'gt', 'lt'],
  'lossless': ['is'],
  'releaseType': ['is', 'isNot'],
  'playCount': ['is', 'gt', 'lt'],
  'addedDays': ['within'],
  'tag': ['is', 'isNot', 'anyOf', 'allOf'],
};

/// One rule: `value` is a String for string ops, num for year/playCount/
/// addedDays, bool for lossless, and List&lt;String&gt; for anyOf/allOf.
class SmartRule {
  const SmartRule({required this.field, required this.op, this.value});

  final String field;
  final String op;
  final Object? value;

  bool get isValid {
    final ops = smartRuleFields[field];
    if (ops == null || !ops.contains(op)) return false;
    if (op == 'anyOf' || op == 'allOf') {
      final v = value;
      return v is List &&
          v.isNotEmpty &&
          v.length <= 30 &&
          v.every((e) => e is String && e.isNotEmpty);
    }
    return value != null;
  }

  factory SmartRule.fromJson(Map<String, dynamic> j) => SmartRule(
        field: j['field'] as String,
        op: j['op'] as String,
        value: j['value'],
      );

  Map<String, dynamic> toJson() => {'field': field, 'op': op, 'value': value};
}

/// Rule set: `match` is 'all' or 'any'.
class SmartRules {
  const SmartRules({required this.match, required this.rules});

  final String match;
  final List<SmartRule> rules;

  bool get isValid =>
      (match == 'all' || match == 'any') &&
      rules.length <= 16 &&
      rules.every((r) => r.isValid);

  factory SmartRules.fromJson(Map<String, dynamic> j) => SmartRules(
        match: j['match'] as String,
        rules: (j['rules'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SmartRule.fromJson)
            .toList(),
      );

  Map<String, dynamic> toJson() =>
      {'match': match, 'rules': rules.map((r) => r.toJson()).toList()};
}

class Playlist {
  const Playlist({
    required this.id,
    required this.profileId,
    required this.name,
    required this.type,
    this.trackIds,
    this.rules,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String profileId;
  final String name;
  final String type; // manual | smart
  final List<String>? trackIds; // manual only; duplicates allowed
  final SmartRules? rules; // smart only
  final String? createdAt;
  final String? updatedAt;

  bool get isSmart => type == 'smart';

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: j['id'] as String,
        profileId: j['profileId'] as String,
        name: j['name'] as String,
        type: j['type'] as String,
        trackIds: j['trackIds'] is List ? asStringList(j['trackIds']) : null,
        rules: j['rules'] is Map<String, dynamic>
            ? SmartRules.fromJson(j['rules'] as Map<String, dynamic>)
            : null,
        createdAt: asString(j['createdAt']),
        updatedAt: asString(j['updatedAt']),
      );
}
