import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'settings_page.dart';

final settingsFeatureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/settings',
    label: 'Settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
  ),
  routes: [GoRoute(path: '/settings', builder: (_, _) => const SettingsPage())],
);
