import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'home_screen.dart';
import 'mix_screen.dart';

/// Home is the default landing view (legacy renderHome).
final homeFeatureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/home',
    label: 'Home',
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
  ),
  routes: [
    GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
    GoRoute(
      path: '/mix/:id',
      builder: (_, s) => MixScreen(id: s.pathParameters['id']!),
    ),
  ],
);
