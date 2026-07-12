import 'package:go_router/go_router.dart';
import '../../core/phosphor_icons.dart';

import '../../core/router.dart';
import 'radio_page.dart';

final radioFeatureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/radio',
    label: 'Radio',
    icon: PhosphorIconsThin.radio,
    selectedIcon: PhosphorIconsFill.radio,
  ),
  routes: [GoRoute(path: '/radio', builder: (_, _) => const RadioPage())],
);
