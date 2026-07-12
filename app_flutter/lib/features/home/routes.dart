import 'package:go_router/go_router.dart';
import '../../core/phosphor_icons.dart';

import '../../core/router.dart';
import 'home_screen.dart';
import 'mix_screen.dart';

/// Home is the default landing view (legacy renderHome).
final homeFeatureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/home',
    label: 'Home',
    icon: PhosphorIconsThin.house,
    selectedIcon: PhosphorIconsFill.house,
  ),
  routes: [
    GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
    GoRoute(
      path: '/mix/:id',
      builder: (_, s) => MixScreen(id: s.pathParameters['id']!),
    ),
  ],
);
