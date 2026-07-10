import 'dart:convert';

import 'package:aria/core/connection.dart';
import 'package:aria/core/downloads.dart';
import 'package:aria/features/album/edit_metadata_dialog.dart';
import 'package:aria/widgets/art_image.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Album editor cover-art source picker (File/API/Custom).
void main() {
  final album = Album(id: 'a1', title: 'X', albumArtist: 'Y', tracks: const []);

  /// MockClient: empty edits, File slot present per [fileExists], PATCH echoes
  /// the body and (when given) reports it via [onPatch].
  AriaClient mock({
    required bool fileExists,
    void Function(http.Request req)? onPatch,
  }) {
    const jsonHeaders = {'content-type': 'application/json'};
    return AriaClient(
      baseUrl: 'http://box:3000',
      httpClient: MockClient((req) async {
        if (req.url.path.startsWith('/api/edits/')) {
          return http.Response(
              jsonEncode({'original': {}, 'overrides': {}}), 200,
              headers: jsonHeaders);
        }
        if (req.url.path.startsWith('/api/art/')) {
          return http.Response('', fileExists ? 200 : 404);
        }
        if (req.method == 'PATCH') {
          onPatch?.call(req);
          return http.Response(jsonEncode(jsonDecode(req.body)), 200,
              headers: jsonHeaders);
        }
        return http.Response('{}', 200, headers: jsonHeaders);
      }),
    );
  }

  Future<void> openEditor(WidgetTester tester, AriaClient client) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(client),
          // Offline fallback must not touch the downloads store in tests.
          localArtResolverProvider.overrideWithValue((_) => null),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showAlbumEditor(context, ref, album),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('renders exactly 3 art thumbnails', (tester) async {
    await openEditor(tester, mock(fileExists: true));
    expect(find.byType(ArtImage), findsNWidgets(3));
  });

  testWidgets('File thumbnail greyed when embedded art absent', (tester) async {
    await openEditor(tester, mock(fileExists: false));
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('art-file')),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(opacity.opacity, 0.4);
  });

  testWidgets('selecting API then saving PATCHes artSource=api', (tester) async {
    http.Request? patch;
    await openEditor(
        tester, mock(fileExists: true, onPatch: (r) => patch = r));
    await tester.tap(find.byKey(const ValueKey('art-api')));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(patch, isNotNull);
    expect(jsonDecode(patch!.body)['artSource'], 'api');
  });
}
