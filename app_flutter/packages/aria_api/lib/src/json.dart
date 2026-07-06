/// Tolerant JSON coercers: the server emits numbers that may arrive as int or
/// double, and most fields are nullable.
library;

int? asInt(Object? v) => switch (v) {
      int i => i,
      double d => d.toInt(),
      String s => int.tryParse(s),
      _ => null,
    };

double? asDouble(Object? v) => switch (v) {
      int i => i.toDouble(),
      double d => d,
      String s => double.tryParse(s),
      _ => null,
    };

String? asString(Object? v) => v == null ? null : v as String;

bool asBool(Object? v) => v == true;

List<String> asStringList(Object? v) =>
    v is List ? v.whereType<String>().toList() : const [];

Map<String, dynamic> asMap(Object? v) =>
    v is Map<String, dynamic> ? v : const {};
