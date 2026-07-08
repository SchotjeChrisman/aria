import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/background_audio.dart';
import 'core/connection.dart';
import 'core/log.dart';
import 'core/router.dart';
import 'core/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 100k-track headroom: a 10k-cover grid thrashes the default image cache
  // (100MB / 1000 images), so give it room to keep decoded covers around.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 400 << 20 // ~400MB
    ..maximumSize = 4000;
  final prefs = await SharedPreferences.getInstance();
  final support = await getApplicationSupportDirectory();
  await Log.init(Directory('${support.path}/logs'), prefs: prefs);
  // Uncaught errors land in the log. PlatformDispatcher.onError (not
  // runZonedGuarded) — no zone mismatch with the async work above.
  FlutterError.onError = (details) {
    Log.e('flutter', details.exceptionAsString(), details.stack);
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    Log.e('platform', '$error', stack);
    return true;
  };
  Log.i('app', 'start', {
    'version': appVersion,
    'platform': Platform.operatingSystem,
  });
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      appSupportDirProvider.overrideWithValue(support),
    ],
  );
  // Android: media session + foreground service so playback survives
  // backgrounding, and losing the output device pauses. Desktop needs
  // neither — the mpv engine already handles ao errors there.
  if (Platform.isAndroid) await initBackgroundAudio(container);
  runApp(
    UncontrolledProviderScope(container: container, child: const AriaApp()),
  );
}

class AriaApp extends ConsumerWidget {
  const AriaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Aria',
      debugShowCheckedModeBanner: false,
      theme: AriaTheme.light(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
