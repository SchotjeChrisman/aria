import 'package:aria_api/aria_api.dart';
import 'package:test/test.dart';

void main() {
  group('SmartRule validity (mirrors server RULE_FIELDS)', () {
    test('string ops on string fields', () {
      for (final field in [
        'title',
        'artist',
        'albumArtist',
        'album',
        'genre',
        'composer',
        'format',
        'credited',
      ]) {
        for (final op in ['is', 'isNot', 'contains']) {
          expect(SmartRule(field: field, op: op, value: 'x').isValid, isTrue,
              reason: '$field $op');
        }
        expect(SmartRule(field: field, op: 'anyOf', value: ['a', 'b']).isValid,
            isTrue);
        expect(
            SmartRule(field: field, op: 'allOf', value: ['a']).isValid, isTrue);
        expect(SmartRule(field: field, op: 'gt', value: 1).isValid, isFalse);
      }
    });

    test('numeric fields', () {
      for (final op in ['is', 'gt', 'lt']) {
        expect(SmartRule(field: 'year', op: op, value: 1990).isValid, isTrue);
        expect(SmartRule(field: 'playCount', op: op, value: 5).isValid, isTrue);
      }
      expect(SmartRule(field: 'year', op: 'contains', value: 1990).isValid,
          isFalse);
    });

    test('lossless only supports is', () {
      expect(
          SmartRule(field: 'lossless', op: 'is', value: true).isValid, isTrue);
      expect(SmartRule(field: 'lossless', op: 'isNot', value: true).isValid,
          isFalse);
    });

    test('releaseType is/isNot', () {
      expect(SmartRule(field: 'releaseType', op: 'is', value: 'Live').isValid,
          isTrue);
      expect(SmartRule(field: 'releaseType', op: 'isNot', value: 'EP').isValid,
          isTrue);
      expect(
          SmartRule(field: 'releaseType', op: 'contains', value: 'E').isValid,
          isFalse);
    });

    test('addedDays within', () {
      expect(SmartRule(field: 'addedDays', op: 'within', value: 30).isValid,
          isTrue);
      expect(
          SmartRule(field: 'addedDays', op: 'is', value: 30).isValid, isFalse);
    });

    test('tag ops', () {
      expect(SmartRule(field: 'tag', op: 'is', value: 'Chill').isValid, isTrue);
      expect(SmartRule(field: 'tag', op: 'anyOf', value: ['A', 'B']).isValid,
          isTrue);
      expect(
          SmartRule(field: 'tag', op: 'contains', value: 'C').isValid, isFalse);
    });

    test('anyOf/allOf constraints: non-empty string array, max 30', () {
      expect(SmartRule(field: 'tag', op: 'anyOf', value: <String>[]).isValid,
          isFalse);
      expect(SmartRule(field: 'tag', op: 'anyOf', value: 'notalist').isValid,
          isFalse);
      expect(SmartRule(field: 'tag', op: 'anyOf', value: ['ok', '']).isValid,
          isFalse);
      expect(
          SmartRule(
              field: 'tag',
              op: 'anyOf',
              value: List.generate(31, (i) => 'v$i')).isValid,
          isFalse);
      expect(
          SmartRule(
              field: 'tag',
              op: 'anyOf',
              value: List.generate(30, (i) => 'v$i')).isValid,
          isTrue);
    });

    test('unknown field or missing value invalid', () {
      expect(SmartRule(field: 'bpm', op: 'is', value: 1).isValid, isFalse);
      expect(SmartRule(field: 'title', op: 'is', value: null).isValid, isFalse);
    });
  });

  group('SmartRules', () {
    test('match must be all/any and max 16 rules', () {
      const ok = SmartRules(match: 'any', rules: [
        SmartRule(field: 'genre', op: 'is', value: 'Jazz'),
      ]);
      expect(ok.isValid, isTrue);
      expect(const SmartRules(match: 'none', rules: []).isValid, isFalse);
      expect(
          SmartRules(
            match: 'all',
            rules: List.generate(
                17, (_) => const SmartRule(field: 'year', op: 'gt', value: 0)),
          ).isValid,
          isFalse);
    });

    test('toJson emits the exact server wire shape', () {
      const rules = SmartRules(match: 'all', rules: [
        SmartRule(field: 'genre', op: 'anyOf', value: ['Jazz', 'Blues']),
        SmartRule(field: 'lossless', op: 'is', value: true),
        SmartRule(field: 'year', op: 'gt', value: 1960),
      ]);
      expect(rules.toJson(), {
        'match': 'all',
        'rules': [
          {
            'field': 'genre',
            'op': 'anyOf',
            'value': ['Jazz', 'Blues']
          },
          {'field': 'lossless', 'op': 'is', 'value': true},
          {'field': 'year', 'op': 'gt', 'value': 1960},
        ],
      });
    });

    test('fromJson(toJson) round-trip', () {
      const orig = SmartRules(match: 'any', rules: [
        SmartRule(field: 'credited', op: 'contains', value: 'karajan'),
        SmartRule(field: 'addedDays', op: 'within', value: 7),
      ]);
      final rt = SmartRules.fromJson(orig.toJson());
      expect(rt.match, 'any');
      expect(rt.rules.length, 2);
      expect(rt.rules[0].field, 'credited');
      expect(rt.rules[1].value, 7);
      expect(rt.isValid, isTrue);
    });
  });
}
