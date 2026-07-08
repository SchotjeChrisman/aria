import 'dart:convert';
import 'dart:io';

import 'package:aria/core/log_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late File file;
  late SharedPreferences prefs;
  late List<List<Map<String, dynamic>>> batches;
  Object? uploadError;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aria_log_sync_test');
    file = File('${tmp.path}/aria.ndjson');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    batches = [];
    uploadError = null;
  });

  tearDown(() => tmp.delete(recursive: true));

  LogSync sync() => LogSync(
    prefs: prefs,
    file: () => file,
    upload: (entries) async {
      if (uploadError != null) throw uploadError!;
      batches.add(entries);
    },
  );

  String line(int i) =>
      '${jsonEncode({'ts': 't$i', 'level': 'info', 'tag': 'x', 'msg': 'm$i'})}\n';

  test('uploads new lines once and advances the cursor', () async {
    await file.writeAsString(line(0) + line(1));
    final s = sync();

    await s.syncNow();
    expect(batches, hasLength(1));
    expect(batches.single, hasLength(2));
    expect(batches.single[1]['msg'], 'm1');

    // Nothing new: no second upload.
    await s.syncNow();
    expect(batches, hasLength(1));

    // Appended lines only.
    await file.writeAsString(line(2), mode: FileMode.append);
    await s.syncNow();
    expect(batches, hasLength(2));
    expect(batches.last.single['msg'], 'm2');
  });

  test('failed upload does not advance the cursor', () async {
    await file.writeAsString(line(0));
    final s = sync();

    uploadError = Exception('offline');
    await s.syncNow(); // swallowed
    expect(batches, isEmpty);

    uploadError = null;
    await s.syncNow();
    expect(batches.single.single['msg'], 'm0');
  });

  test('rotation (file shrank) resets the cursor to 0', () async {
    await file.writeAsString(line(0) + line(1) + line(2));
    final s = sync();
    await s.syncNow();
    expect(batches, hasLength(1));

    // Rotated: a fresh, shorter file.
    await file.writeAsString(line(3));
    await s.syncNow();
    expect(batches, hasLength(2));
    expect(batches.last.single['msg'], 'm3');
  });

  test('rotation past the old length is caught by the head fingerprint', () async {
    await file.writeAsString(line(0));
    final s = sync();
    await s.syncNow();
    expect(batches, hasLength(1));

    // Rotated: a fresh file that already grew past the old length, so the
    // len/offset checks alone would silently skip its head.
    await file.writeAsString(line(1) + line(2) + line(3));
    await s.syncNow();
    expect(batches, hasLength(2));
    expect(batches.last.map((e) => e['msg']), ['m1', 'm2', 'm3']);
  });

  test('legacy cursor without head resets once without crashing', () async {
    await file.writeAsString(line(0));
    final len = await file.length();
    prefs.setString(
      'aria.logCursor',
      jsonEncode({'offset': len, 'len': len}), // pre-head cursor shape
    );
    final s = sync();

    await s.syncNow(); // match-unknown — one re-upload from the top
    expect(batches.single.single['msg'], 'm0');

    await s.syncNow(); // head persisted now — no second reset
    expect(batches, hasLength(1));
  });

  test('partial trailing line is left for the next tick', () async {
    await file.writeAsString('${line(0)}{"ts":"t1","le');
    final s = sync();

    await s.syncNow();
    expect(batches.single.single['msg'], 'm0');

    await file.writeAsString(
      'vel":"info","tag":"x","msg":"m1"}\n',
      mode: FileMode.append,
    );
    await s.syncNow();
    expect(batches, hasLength(2));
    expect(batches.last.single['msg'], 'm1');
  });

  test('corrupt lines are skipped without wedging the cursor', () async {
    await file.writeAsString('${line(0)}not json\n${line(1)}');
    await sync().syncNow();
    expect(batches.single.map((e) => e['msg']), ['m0', 'm1']);
  });

  test('drains more than one batch per sync', () async {
    final sb = StringBuffer();
    for (var i = 0; i < LogSync.maxBatchEntries + 10; i++) {
      sb.write(line(i));
    }
    await file.writeAsString(sb.toString());

    await sync().syncNow();
    expect(batches, hasLength(2));
    expect(batches[0], hasLength(LogSync.maxBatchEntries));
    expect(batches[1], hasLength(10));
  });

  test('missing file is a quiet no-op', () async {
    await sync().syncNow();
    expect(batches, isEmpty);
  });
}
