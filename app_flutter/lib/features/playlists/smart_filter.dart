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
}

int? _asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v');

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
  if (rules.isEmpty) return (rules: null, error: 'Set at least one filter.');
  return (rules: SmartRules(match: match, rules: rules), error: null);
}
