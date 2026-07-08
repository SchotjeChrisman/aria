import 'dart:convert';

import 'package:aria/core/pending_plays.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late List<(String, String, String?)> sent;

  /// Per-call status codes; null = success. Consumed front-to-back, then
  /// every remaining call succeeds.
  late List<int?> responses;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    sent = [];
    responses = [];
  });

  PendingPlays queue() => PendingPlays(
    prefs: prefs,
    send: (trackId, profileId, at) async {
      final code = responses.isEmpty ? null : responses.removeAt(0);
      if (code != null) throw AriaApiException(code, 'nope');
      sent.add((trackId, profileId, at));
    },
  );

  test('flush replays oldest-first, clears the queue, returns true', () async {
    final q = queue()
      ..add(trackId: 't1', profileId: 'p1', at: 'a1')
      ..add(trackId: 't2', profileId: 'p1', at: 'a2');

    expect(await q.flush(), isTrue);
    expect(sent, [('t1', 'p1', 'a1'), ('t2', 'p1', 'a2')]);
    expect(q.entries, isEmpty);
  });

  test('empty queue flush returns false', () async {
    expect(await queue().flush(), isFalse);
  });

  test('statusCode 0 stops the pass and keeps the entry', () async {
    final q = queue()..add(trackId: 't1', profileId: 'p1', at: 'a1');

    responses = [0];
    expect(await q.flush(), isFalse);
    expect(q.entries, hasLength(1));

    expect(await q.flush(), isTrue); // reachable again — retried
    expect(sent.single, ('t1', 'p1', 'a1'));
    expect(q.entries, isEmpty);
  });

  test('transient 500 stops the pass and keeps the entry', () async {
    final q = queue()
      ..add(trackId: 't1', profileId: 'p1', at: 'a1')
      ..add(trackId: 't2', profileId: 'p1', at: 'a2');

    responses = [500];
    expect(await q.flush(), isFalse);
    expect(q.entries, hasLength(2)); // nothing dropped, nothing sent

    expect(await q.flush(), isTrue); // server recovered — both replayed
    expect(sent, [('t1', 'p1', 'a1'), ('t2', 'p1', 'a2')]);
    expect(q.entries, isEmpty);
  });

  test('4xx drops the entry and continues the pass', () async {
    final q = queue()
      ..add(trackId: 't1', profileId: 'gone', at: 'a1')
      ..add(trackId: 't2', profileId: 'p1', at: 'a2');

    responses = [400];
    expect(await q.flush(), isTrue);
    expect(sent.single, ('t2', 'p1', 'a2'));
    expect(q.entries, isEmpty);
  });

  test('cap keeps the newest entries', () {
    final q = queue();
    for (var i = 0; i < PendingPlays.cap + 2; i++) {
      q.add(trackId: 't$i', profileId: 'p1', at: 'a$i');
    }
    final list = q.entries;
    expect(list, hasLength(PendingPlays.cap));
    expect(list.first['trackId'], 't2'); // oldest two evicted
  });

  test('corrupt persisted queue starts clean', () async {
    prefs.setString('aria.pendingPlays', 'not json');
    final q = queue();
    expect(q.entries, isEmpty);
    expect(await q.flush(), isFalse);
  });

  test('persists across instances', () {
    queue().add(trackId: 't1', profileId: 'p1', at: 'a1');
    expect(
      (jsonDecode(prefs.getString('aria.pendingPlays')!) as List).single,
      {'trackId': 't1', 'profileId': 'p1', 'at': 'a1'},
    );
    expect(queue().entries, hasLength(1));
  });
}
