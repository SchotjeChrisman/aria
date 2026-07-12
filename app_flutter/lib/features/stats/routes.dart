import 'package:go_router/go_router.dart';
import '../../core/phosphor_icons.dart';

import '../../core/router.dart';
import 'stats_page.dart';

final statsFeatureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/stats',
    label: 'Stats',
    icon: PhosphorIconsThin.chartBar,
    selectedIcon: PhosphorIconsFill.chartBar,
  ),
  routes: [GoRoute(path: '/stats', builder: (_, _) => const StatsPage())],
);
