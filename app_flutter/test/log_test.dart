import 'dart:convert';
import 'dart:io';

import 'package:aria/core/log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    Log.reset();
    tmp = await Directory.systemTemp.createTemp('aria_log_test');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await Log.flush();
    Log.reset();
    await tmp.delete(recursive: true);
  });

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  test('entries reach the ring buffer before init, file after', () async {
    Log.i('pre', 'before init');
    expect(Log.entries.single.msg, 'before init');
    expect(Log.filePath, isNull);

    await Log.init(tmp, prefs: await prefs());
    Log.w('post', 'after init', {'k': 'v'});
    await Log.flush();

    final lines = await File(Log.filePath!).readAsLines();
    // Pre-init entries stay memory-only.
    expect(lines, hasLength(1));
    final j = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(j['level'], 'warn');
    expect(j['tag'], 'post');
    expect(j['msg'], 'after init');
    expect(j['extra'], '{k: v}');
    expect(j['ts'], isNotEmpty);
  });

  test('ring buffer caps at 500 entries', () {
    for (var i = 0; i < 520; i++) {
      Log.d('t', 'msg $i');
    }
    expect(Log.entries, hasLength(500));
    expect(Log.entries.first.msg, 'msg 20');
    expect(Log.entries.last.msg, 'msg 519');
  });

  test('rotation renames to aria.1.ndjson and starts fresh', () async {
    // ~120-byte lines, 800-byte cap: exactly one rotation over 10 lines.
    await Log.init(tmp, prefs: await prefs(), maxBytes: 800);
    for (var i = 0; i < 10; i++) {
      Log.i('rot', 'a fairly long message to push past the cap, number $i');
    }
    await Log.flush();

    final live = File('${tmp.path}/aria.ndjson');
    final rotated = File('${tmp.path}/aria.1.ndjson');
    expect(await rotated.exists(), isTrue);
    expect(await live.exists(), isTrue);
    expect(await live.length(), lessThanOrEqualTo(800));

    // No line was lost across the single rotation, and each one still parses.
    final all = [
      ...await rotated.readAsLines(),
      ...await live.readAsLines(),
    ];
    expect(all, hasLength(10));
    for (final l in all) {
      expect(jsonDecode(l), isA<Map<String, dynamic>>());
    }
  });

  test('a second rotation replaces the previous aria.1.ndjson', () async {
    await Log.init(tmp, prefs: await prefs(), maxBytes: 150);
    for (var i = 0; i < 12; i++) {
      Log.i('rot', 'message long enough to trigger several rotations $i');
      await Log.flush();
    }
    final rotated = File('${tmp.path}/aria.1.ndjson');
    expect(await rotated.exists(), isTrue);
    // The oldest lines are gone: only one rotated generation is kept.
    final kept = [
      ...await rotated.readAsLines(),
      ...await File('${tmp.path}/aria.ndjson').readAsLines(),
    ];
    expect(kept.length, lessThan(12));
  });

  test('device id persists across inits and is platform-labelled', () async {
    final p = await prefs();
    await Log.init(tmp, prefs: p);
    final first = Log.device;
    expect(first, startsWith('${Platform.operatingSystem}-'));

    Log.reset();
    await Log.init(tmp, prefs: p);
    expect(Log.device, first);
  });
}
