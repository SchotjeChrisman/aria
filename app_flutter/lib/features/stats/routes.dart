import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'stats_page.dart';

final statsFeatureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/stats',
    label: 'Stats',
    icon: Icons.bar_chart_outlined,
    selectedIcon: Icons.bar_chart,
  ),
  routes: [GoRoute(path: '/stats', builder: (_, _) => const StatsPage())],
);
