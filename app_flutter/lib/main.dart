import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/connection.dart';
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
  runApp(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: const AriaApp(),
    ),
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
