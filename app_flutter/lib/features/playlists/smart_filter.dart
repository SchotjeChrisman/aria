import 'package:aria_api/aria_api.dart';

import '../../widgets/multi_select_field.dart';

// The smart-playlist form model, ported from legacy app.js (newFilterState /
// smartForm / collectSmartRules). String multi-selects + field list live in
// widgets/multi_select_field.dart (shared with the library Tracks filter); this
// file owns turning the picks into server [SmartRules] and back.

class SmartFilterState {
  SmartFilterState()
    : strings = {
        for (final (f, _) in filterStringFields) f: MultiSelectState(),
      };

  final Map<String, MultiSelectState> strings;
  int? yearFrom;
  int? yearTo;
  String? lossless; // 'true' | 'false' | null (Any)
  String? releaseType;
  String? played; // 'played' | 'never' | null (Any)
  int? addedDays;

  // Measured off the decoded audio by /api/analyze. A track that has not been
  // analysed matches none of these — not even `quieter than`, since the server
  // fails every comparison against a null rather than reading it as 0.
  int? minSampleRate; // Hz
  int? minBits;
  double? loudnessFrom; // LUFS: louder than this
  double? loudnessTo; // LUFS: quieter than this
  double? minDynamicRange; // LU
  String? suspect; // 'false' (exclude) | 'true' (only) | null (Any)
}

int? _asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v');

double? _asDouble(Object? v) => v is num ? v.toDouble() : double.tryParse('$v');

/// Legacy smartForm(): saved rules -> editable filter state. Rules with no
/// form row anymore (title/album from the old editor) are dropped on edit.
SmartFilterState rulesToState(SmartRules? rules) {
  final st = SmartFilterState();
  for (final r in rules?.rules ?? const <SmartRule>[]) {
    final ms = st.strings[r.field];
    if (ms != null) {
      final vals = r.value is List
          ? [for (final v in r.value as List) '$v']
          : ['${r.value}'];
      for (final v in vals) {
        if (!ms.vals.contains(v)) ms.vals.add(v);
      }
      if (r.op == 'allOf') ms.mode = 'all';
      continue;
    }
    switch (r.field) {
      case 'year':
        final v = _asInt(r.value);
        if (v == null) break;
        if (r.op == 'gt') {
          st.yearFrom = v + 1;
        } else if (r.op == 'lt') {
          st.yearTo = v - 1;
        } else {
          st.yearFrom = st.yearTo = v;
        }
      case 'lossless':
        st.lossless = '${r.value}';
      case 'releaseType':
        st.releaseType = '${r.value}';
      case 'playCount':
        st.played = (r.op == 'is' && _asInt(r.value) == 0) ? 'never' : 'played';
      case 'addedDays':
        st.addedDays = _asInt(r.value);
      // The quality rows. Each reverses exactly what stateToRules emits, so
      // editing a playlist round-trips instead of quietly dropping the rule.
      case 'sampleRate':
        final v = _asInt(r.value);
        if (v != null) st.minSampleRate = r.op == 'gt' ? v + 1 : v;
      case 'bitsPerSample':
        final v = _asInt(r.value);
        if (v != null) st.minBits = r.op == 'gt' ? v + 1 : v;
      case 'loudness':
        if (r.op == 'gt') {
          st.loudnessFrom = _asDouble(r.value);
        } else if (r.op == 'lt') {
          st.loudnessTo = _asDouble(r.value);
        }
      case 'dynamicRange':
        if (r.op == 'gt') st.minDynamicRange = _asDouble(r.value);
      case 'suspect':
        st.suspect = '${r.value}';
    }
  }
  return st;
}

/// Legacy collectSmartRules(): state -> rules, or an error when nothing set.
({SmartRules? rules, String? error}) stateToRules(
  SmartFilterState st,
  String match,
) {
  final rules = <SmartRule>[];
  for (final (f, _) in filterStringFields) {
    final ms = st.strings[f]!;
    if (ms.vals.isNotEmpty) {
      rules.add(
        SmartRule(
          field: f,
          op: ms.mode == 'all' ? 'allOf' : 'anyOf',
          value: List.of(ms.vals),
        ),
      );
    }
  }
  if (st.yearFrom != null) {
    rules.add(SmartRule(field: 'year', op: 'gt', value: st.yearFrom! - 1));
  }
  if (st.yearTo != null) {
    rules.add(SmartRule(field: 'year', op: 'lt', value: st.yearTo! + 1));
  }
  if (st.lossless != null) {
    rules.add(
      SmartRule(field: 'lossless', op: 'is', value: st.lossless == 'true'),
    );
  }
  if (st.releaseType != null) {
    rules.add(SmartRule(field: 'releaseType', op: 'is', value: st.releaseType));
  }
  if (st.played == 'played') {
    rules.add(SmartRule(field: 'playCount', op: 'gt', value: 0));
  }
  if (st.played == 'never') {
    rules.add(SmartRule(field: 'playCount', op: 'is', value: 0));
  }
  if (st.addedDays != null && st.addedDays! > 0) {
    rules.add(SmartRule(field: 'addedDays', op: 'within', value: st.addedDays));
  }
  // `gt v - 1` rather than `>=`, because the server's numeric ops are only
  // is/gt/lt — the same shape the year rows have always used. Safe on integers.
  if (st.minSampleRate != null) {
    rules.add(
      SmartRule(field: 'sampleRate', op: 'gt', value: st.minSampleRate! - 1),
    );
  }
  if (st.minBits != null) {
    rules.add(SmartRule(field: 'bitsPerSample', op: 'gt', value: st.minBits! - 1));
  }
  // Loudness and range are continuous, so they take the entered bound as-is:
  // "louder than -14 LUFS", "quieter than -20 LUFS", "more than 8 LU of range".
  if (st.loudnessFrom != null) {
    rules.add(SmartRule(field: 'loudness', op: 'gt', value: st.loudnessFrom));
  }
  if (st.loudnessTo != null) {
    rules.add(SmartRule(field: 'loudness', op: 'lt', value: st.loudnessTo));
  }
  if (st.minDynamicRange != null) {
    rules.add(
      SmartRule(field: 'dynamicRange', op: 'gt', value: st.minDynamicRange),
    );
  }
  if (st.suspect != null) {
    rules.add(SmartRule(field: 'suspect', op: 'is', value: st.suspect == 'true'));
  }
  if (rules.isEmpty) return (rules: null, error: 'Set at least one filter.');
  return (rules: SmartRules(match: match, rules: rules), error: null);
}
