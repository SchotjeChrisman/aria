import 'dart:convert';

import 'package:aria_api/aria_api.dart';
import 'package:test/test.dart';

Stream<List<int>> chunks(List<String> parts) =>
    Stream.fromIterable(parts.map(utf8.encode));

void main() {
  group('parseSse', () {
    test('parses named events with JSON data', () async {
      final events = await parseSse(chunks([
        'event: scan\n',
        'data: {"done":10,"total":100}\n',
        '\n',
        'event: enrich\ndata: {"phase":"albums","done":1,"total":5}\n\n',
      ])).toList();
      expect(events.length, 2);
      expect(events[0].event, 'scan');
      expect((events[0].json as Map)['done'], 10);
      expect(events[1].event, 'enrich');
      expect((events[1].json as Map)['phase'], 'albums');
    });

    test('defaults to message event and handles no space after colon',
        () async {
      final events = await parseSse(chunks(['data:hello\n', '\n'])).toList();
      expect(events.single.event, 'message');
      expect(events.single.data, 'hello');
      expect(events.single.json, isNull); // not JSON
    });

    test('joins multi-line data with newline', () async {
      final events = await parseSse(chunks([
        'data: line1\n',
        'data: line2\n',
        '\n',
      ])).toList();
      expect(events.single.data, 'line1\nline2');
    });

    test('ignores comments/keep-alives and blank blocks', () async {
      final events = await parseSse(chunks([
        ': keep-alive\n',
        '\n',
        'event: scan\n', // event but no data -> nothing dispatched
        '\n',
        'data: real\n\n',
      ])).toList();
      expect(events.length, 1);
      expect(events.single.data, 'real');
    });

    test('survives arbitrary chunk boundaries', () async {
      final events = await parseSse(chunks([
        'eve',
        'nt: sc',
        'an\nda',
        'ta: {"done"',
        ':3}\n',
        '\n',
      ])).toList();
      expect(events.single.event, 'scan');
      expect((events.single.json as Map)['done'], 3);
    });

    test('carries id field', () async {
      final events = await parseSse(chunks(['id: 42\ndata: x\n\n'])).toList();
      expect(events.single.id, '42');
    });
  });
}
