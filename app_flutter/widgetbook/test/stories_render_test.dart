import 'dart:io';

import 'package:aria/core/connection.dart';
import 'package:aria/core/log.dart';
import 'package:aria/core/theme.dart';
import 'package:aria_api/aria_api.dart';
import 'package:aria_widgetbook/api.dart';
import 'package:aria_widgetbook/fake_server.dart';
import 'package:aria_widgetbook/stories/all.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:widgetbook/widgetbook.dart';

/// Renders every use case in the catalogue headlessly.
///
/// This is the check that matters on a machine with no display: `flutter run`
/// needs a GTK toolchain and an X server, but the widget tester renders the
/// same tree through the same pipeline. If a use case throws, is unbounded, or
/// overflows, it fails here.
///
/// Run with `--update-goldens` to write test/goldens/*.png.
void main() {
  late FakeAriaServer server;
  late SharedPreferences prefs;
  late Directory support;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // The tester installs an HttpOverrides that answers every request with
    // 400, so cover art would never load. Clearing it lets Image.network
    // reach the stub server on loopback.
    HttpOverrides.global = null;

    // Without this the tester renders every glyph as a box, and the goldens
    // would say nothing about type.
    for (final family in const {
      'Nunito': 'assets/fonts/Nunito.ttf',
      'PhosphorThin': 'assets/fonts/Phosphor-Thin.ttf',
      'PhosphorRegular': 'assets/fonts/Phosphor.ttf',
      'PhosphorFill': 'assets/fonts/Phosphor-Fill.ttf',
    }.entries) {
      final bytes = await File(family.value).readAsBytes();
      await (FontLoader(family.key)
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
    }

    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    support = await Directory.systemTemp.createTemp('aria_wb_test_');
    await Log.init(Directory('${support.path}/logs'), prefs: prefs);

    // The booklet page renders its PDF with pdfrx, which asks path_provider
    // for a cache directory over a MethodChannel — and flutter_test registers
    // no plugin implementations. One handler is cheaper than leaving a
    // destination out of the catalogue.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => support.path,
    );

    server = await FakeAriaServer.start();
    storybookClient = AriaClient(baseUrl: server.baseUrl);
  });

  tearDownAll(() async {
    await server.close();
    await support.delete(recursive: true);
  });

  Widget host(Widget Function(BuildContext) story) => ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          appSupportDirProvider.overrideWithValue(support),
          apiClientProvider.overrideWithValue(storybookClient),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AriaTheme.light(),
          // Nine of the use cases read context.knobs, which asserts on a
          // Widgetbook ancestor. An empty scope is enough: reading a knob
          // registers it and hands back its initial value, which is exactly
          // the state a screenshot should capture.
          home: Material(
            child: WidgetbookScope(
              state: WidgetbookState(root: WidgetbookRoot(children: const [])),
              child: Builder(builder: story),
            ),
          ),
        ),
      );

  for (final entry in allEntries) {
    testWidgets('${entry.key} renders', (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Real socket I/O — provider fetches and cover decodes — needs real
      // async time, which the tester's fake clock does not provide.
      //
      // Fixed pump count, generous real delay, and the two do different jobs.
      // The count is what must not vary: it drives the fake clock, and the
      // text cursor blinks on that clock, so a page with a field screenshots
      // a different cursor phase the moment the loop length changes. The
      // delay is what the sockets actually run in — a page whose providers
      // chain two fetches needs more than one round of it, and coming up
      // short does not fail, it screenshots the loading state.
      //
      // Settling on "quiet" instead was tried and is wrong: a blinking cursor
      // never goes quiet, so every page with a field ran the full cap and
      // landed on a different phase each run.
      await tester.runAsync(() async {
        await tester.pumpWidget(host(entry.builder));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      });
      await tester.pump();

      expect(tester.takeException(), isNull);

      // Use cases whose fixtures move with the wall clock are rendered but
      // not compared — see Entry.golden.
      if (entry.golden) {
        await expectLater(
          // `.first` is the host below, not the use case's own: the shell
          // story stands up a second MaterialApp so it can give AdaptiveShell
          // the router it needs, and a bare byType would match both.
          find.byType(MaterialApp).first,
          matchesGoldenFile('goldens/${entry.key}.png'),
        );
      }
    });
  }
}
