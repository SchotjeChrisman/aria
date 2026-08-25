import 'package:aria/core/connection.dart';
import 'package:aria/core/native/native.dart';
import 'package:aria/core/log.dart';
import 'package:aria/core/theme.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:widgetbook/widgetbook.dart';

import 'api.dart';
import 'stub_backend_io.dart'
    if (dart.library.js_interop) 'stub_backend_web.dart';
import 'stories/all.dart';
import 'stories/catalogue.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hermetic: the catalogue must not inherit — or corrupt — a real install's
  // server URL, EQ favourites or download index.
  // Marked @visibleForTesting, and used on purpose: an in-memory store is
  // precisely what a catalogue wants. The alternative is the real on-disk
  // store, which would let a stale run leak settings into the next one.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final support = await Directory.systemTemp.createTemp('aria_widgetbook_');
  await Log.init(Directory('${support.path}/logs'), prefs: prefs);

  // Native boots a loopback stub; web talks to tool/serve.dart on its own
  // origin. Either way the catalogue only ever sees a base URL.
  storybookClient = AriaClient(baseUrl: await startStubBackend());

  runApp(
    ProviderScope(
      overrides: [
        // Three overrides, and no per-widget mocking below them.
        //
        // sharedPrefs and appSupportDir are the two providers main() is
        // required to fill in — they throw by construction otherwise.
        //
        // apiClient is overridden rather than serverUrl so the catalogue never
        // goes near the /setup redirect: every provider downstream (library,
        // tags, playlists, profiles, downloads) then resolves against the stub
        // with no further help.
        //
        // The audio engine needs nothing. AriaPlayer only loads libmpv in
        // initialize(), which the catalogue never calls, and every command is
        // guarded by `if (!isAvailable) return`. So the real QueueNotifier
        // runs, queue state really mutates, and the current-track states are
        // genuine — while the engine stays silent.
        sharedPrefsProvider.overrideWithValue(prefs),
        appSupportDirProvider.overrideWithValue(support),
        apiClientProvider.overrideWithValue(storybookClient),
      ],
      child: const AriaWidgetbook(),
    ),
  );
}

class AriaWidgetbook extends StatelessWidget {
  const AriaWidgetbook({super.key});

  @override
  Widget build(BuildContext context) {
    return Widgetbook.material(
      appBuilder: (context, child) => _RoutedUseCase(child: child),
      addons: [
        ViewportAddon(Viewports.all),
        TextScaleAddon(),
      ],
      // Hand-written rather than generated: the annotation flow costs
      // widgetbook_annotation, widgetbook_generator and build_runner, plus a
      // codegen step before the catalogue will run, and it would put
      // @UseCase annotations inside the shipped app's lib/. A list is cheaper.
      //
      // The list itself lives in stories/all.dart, beside the stories, and is
      // the same list the render test walks — see stories/catalogue.dart.
      directories: [
        for (final MapEntry(key: name, value: entries) in catalogue.entries)
          WidgetbookCategory(name: name, children: nodesOf(entries)),
      ],
    );
  }
}

/// Widgetbook has no notion of routes, but the wired widgets call
/// `context.push` on tap. Mounting each use case as the home route of a real
/// (if tiny) GoRouter is the only arrangement where those taps neither throw
/// for want of an InheritedGoRouter nor vanish into a detached one: the push
/// lands on the panel below, and Back returns to the component.
class _RoutedUseCase extends StatefulWidget {
  const _RoutedUseCase({required this.child});

  final Widget child;

  @override
  State<_RoutedUseCase> createState() => _RoutedUseCaseState();
}

class _RoutedUseCaseState extends State<_RoutedUseCase> {
  // The use case rebuilds on every knob change; the router must not, or the
  // knob panel would reset the navigation stack on each keystroke. The home
  // route reads the current child through this instead of closing over one.
  late final ValueNotifier<Widget> _child = ValueNotifier(widget.child);

  late final GoRouter _router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        // Material, because Widgetbook's own materialAppBuilder supplies one
        // and replacing appBuilder drops it. Without it there is no
        // DefaultTextStyle from the theme, and every use case renders its
        // text at fallback metrics — tall enough to overflow the cards.
        builder: (_, _) => Material(
          child: ValueListenableBuilder<Widget>(
            valueListenable: _child,
            builder: (_, child, _) => child,
          ),
        ),
      ),
    ],
    // Every app path — /album/:id, /artist/:name, /library/genres/:genre —
    // is unmatched here, so they all land in the error builder. That is the
    // whole routing table: one home route plus a destination readout.
    errorBuilder: (context, state) => _Destination(uri: state.uri.toString()),
  );

  @override
  void didUpdateWidget(_RoutedUseCase old) {
    super.didUpdateWidget(old);
    _child.value = widget.child;
  }

  @override
  void dispose() {
    _child.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: AriaTheme.light(),
        routerConfig: _router,
      );
}

/// Where a tap would have gone in the real app.
class _Destination extends StatelessWidget {
  const _Destination({required this.uri});

  final String uri;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AriaSpace.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'would navigate to',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: AriaSpace.s2),
              Text(uri, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AriaSpace.s6),
              FilledButton(
                onPressed: () => GoRouter.of(context).go('/'),
                child: const Text('Back to the component'),
              ),
              const SizedBox(height: AriaSpace.s3),
              Text(
                'Every destination is catalogued too — find it under its\n'
                'feature\'s Pages folder.',
                style: TextStyle(color: c.fgDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
