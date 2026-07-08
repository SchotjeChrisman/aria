import 'dart:convert';
import 'dart:io';

import 'package:aria/core/connection.dart';
import 'package:aria/core/data_usage.dart';
import 'package:aria/core/downloads.dart';
import 'package:aria/core/library_providers.dart';
import 'package:aria/features/settings/downloads_screen.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aria_dl_screen');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  /// Seed a completed download on disk so the notifier's build() loads it.
  void seedDownload(String id, int bytes) {
    final root = Directory('${dir.path}/downloads')
      ..createSync(recursive: true);
    final path = '${root.path}/$id.flac';
    File(path).writeAsBytesSync(List.filled(bytes, 0));
    final indexFile = File('${root.path}/index.json');
    Map<String, dynamic> index = {};
    if (indexFile.existsSync()) {
      index = jsonDecode(indexFile.readAsStringSync()) as Map<String, dynamic>;
    }
    index[id] = {'path': path, 'bytes': bytes};
    indexFile.writeAsStringSync(jsonEncode(index));
  }

  Future<ProviderContainer> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          appSupportDirProvider.overrideWithValue(dir),
          networkKindProvider.overrideWith(
            (ref) => Stream.value(NetKind.wifi),
          ),
          libraryTracksProvider.overrideWith(
            (ref) async => const [
              Track(id: 't1', albumId: 'al', title: 'One', artist: 'X',
                  album: 'A'),
              Track(id: 't2', albumId: 'al', title: 'Two', artist: 'X',
                  album: 'A'),
            ],
          ),
        ],
        child: const MaterialApp(home: DownloadsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(DownloadsScreen)),
    );
  }

  testWidgets('empty state shows a hint and no Remove all', (tester) async {
    await pump(tester);
    expect(find.textContaining('Nothing downloaded yet'), findsOneWidget);
    expect(find.text('Remove all'), findsNothing);
  });

  testWidgets('lists downloads with metadata and total size', (tester) async {
    seedDownload('t1', 1500);
    seedDownload('t2', 500);
    await pump(tester);

    expect(find.text('2 tracks · 2.0 kB'), findsOneWidget);
    expect(find.text('One'), findsOneWidget);
    expect(find.text('X · A · 1.5 kB'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
  });

  testWidgets('per-item remove deletes the entry', (tester) async {
    seedDownload('t1', 1500);
    seedDownload('t2', 500);
    final container = await pump(tester);

    // Rows sort by album/title: One before Two.
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();
    expect(container.read(downloadsProvider).index.keys, ['t2']);
    expect(find.text('One'), findsNothing);
    expect(find.text('Two'), findsOneWidget);
  });

  testWidgets('Remove all clears everything', (tester) async {
    seedDownload('t1', 1500);
    final container = await pump(tester);

    await tester.tap(find.text('Remove all'));
    await tester.pump();
    expect(container.read(downloadsProvider).index, isEmpty);
    expect(find.textContaining('Nothing downloaded yet'), findsOneWidget);
  });
}
