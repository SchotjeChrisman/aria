import 'package:aria_api/aria_api.dart';
import 'package:aria/features/playlists/smart_filter.dart';
import 'package:flutter_test/flutter_test.dart';

SmartRule? ruleFor(List<SmartRule> rules, String field, String op) {
  for (final r in rules) {
    if (r.field == field && r.op == op) return r;
  }
  return null;
}

void main() {
  test('quality rows become rules and survive a round trip', () {
    final st = SmartFilterState()
      ..minSampleRate = 96000
      ..minBits = 24
      ..loudnessFrom = -14
      ..loudnessTo = -6.5
      ..minDynamicRange = 8
      ..suspect = 'false';

    final rules = stateToRules(st, 'all').rules!.rules;
    // integers use the year rows' `gt v - 1` shape; the continuous ones take
    // the entered bound as-is
    expect(ruleFor(rules, 'sampleRate', 'gt')?.value, 95999);
    expect(ruleFor(rules, 'bitsPerSample', 'gt')?.value, 23);
    expect(ruleFor(rules, 'loudness', 'gt')?.value, -14);
    expect(ruleFor(rules, 'loudness', 'lt')?.value, -6.5);
    expect(ruleFor(rules, 'dynamicRange', 'gt')?.value, 8);
    expect(ruleFor(rules, 'suspect', 'is')?.value, false);

    // reopening the editor must show what was saved, not an empty form
    final back = rulesToState(SmartRules(match: 'all', rules: rules));
    expect(back.minSampleRate, 96000);
    expect(back.minBits, 24);
    expect(back.loudnessFrom, -14);
    expect(back.loudnessTo, -6.5);
    expect(back.minDynamicRange, 8);
    expect(back.suspect, 'false');
  });

  test('an untouched form emits none of the quality rules', () {
    final st = SmartFilterState()..lossless = 'true';
    final rules = stateToRules(st, 'all').rules!.rules;
    expect(rules.length, 1);
    expect(rules.single.field, 'lossless');
  });

  test('editing a pre-existing playlist keeps its rules unchanged', () {
    // exactly what the form emitted before the quality rows existed
    final saved = SmartRules(
      match: 'all',
      rules: [
        SmartRule(field: 'albumArtist', op: 'anyOf', value: ['The Beatles']),
        SmartRule(field: 'year', op: 'gt', value: 1968),
        SmartRule(field: 'year', op: 'lt', value: 1971),
        SmartRule(field: 'lossless', op: 'is', value: true),
        SmartRule(field: 'releaseType', op: 'is', value: 'Album'),
        SmartRule(field: 'playCount', op: 'gt', value: 0),
        SmartRule(field: 'addedDays', op: 'within', value: 30),
      ],
    );
    final again = stateToRules(rulesToState(saved), 'all').rules!.rules;
    String key(SmartRule r) => '${r.field}/${r.op}/${r.value}';
    expect(
      again.map(key).toSet(),
      saved.rules.map(key).toSet(),
    );
  });
}
