import 'package:aria/core/connection.dart';
import 'package:aria/core/log.dart';
import 'package:aria/core/log_sync.dart';
import 'package:aria/features/settings/logs_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  var uploads = 0;

  Future<void> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final sharedPrefs = await SharedPreferences.getInstance();
    uploads = 0;
    // File-less LogSync: syncNow flushes and no-ops, counting attempts.
    final logSync = LogSync(
      prefs: sharedPrefs,
      file: () => null,
      beforeRead: () async => uploads++,
      upload: (_) async {},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(sharedPrefs),
          logSyncProvider.overrideWithValue(logSync),
        ],
        child: const MaterialApp(home: LogsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(Log.reset);
  tearDown(Log.reset);

  testWidgets('shows ring-buffer entries newest first', (tester) async {
    Log.i('app', 'started');
    Log.e('playback', 'boom');
    await pump(tester);

    expect(find.text('app: started'), findsOneWidget);
    expect(find.text('playback: boom'), findsOneWidget);
    // Newest first: the error is above the info line.
    final errY = tester.getTopLeft(find.text('playback: boom')).dy;
    final infoY = tester.getTopLeft(find.text('app: started')).dy;
    expect(errY, lessThan(infoY));
  });

  testWidgets('level chips filter the list', (tester) async {
    Log.i('app', 'started');
    Log.e('playback', 'boom');
    await pump(tester);

    await tester.tap(find.text('error'));
    await tester.pump();
    expect(find.text('playback: boom'), findsOneWidget);
    expect(find.text('app: started'), findsNothing);

    await tester.tap(find.text('all'));
    await tester.pump();
    expect(find.text('app: started'), findsOneWidget);
  });

  testWidgets('empty ring shows a placeholder', (tester) async {
    await pump(tester);
    expect(find.text('No log entries.'), findsOneWidget);
  });

  testWidgets('Sync now triggers the sync service', (tester) async {
    Log.i('app', 'started');
    await pump(tester);

    await tester.tap(find.text('Sync now'));
    await tester.pump();
    expect(uploads, 1);
    expect(find.text('Log sync attempted.'), findsOneWidget);

    // Drain the snackbar timer so nothing is pending at teardown.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('new entries appear live via the revision notifier', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('No log entries.'), findsOneWidget);

    Log.w('conn', 'late entry');
    await tester.pump();
    expect(find.text('conn: late entry'), findsOneWidget);
  });
}
