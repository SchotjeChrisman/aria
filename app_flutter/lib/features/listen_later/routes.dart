import 'package:go_router/go_router.dart';

import '../../core/phosphor_icons.dart';
import '../../core/router.dart';
import '../release/routes.dart' as release;
import 'listen_later_screen.dart';

final featureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/listen-later',
    label: 'Listen Later',
    icon: PhosphorIconsThin.clock,
    selectedIcon: PhosphorIconsFill.clock,
  ),
  routes: [
    GoRoute(path: '/listen-later', builder: (_, _) => const ListenLaterScreen()),
    // Unowned-album pages live in this branch, the way /album/:id lives in the
    // albums branch: pushed from anywhere, rendered in the content area.
    ...release.releaseDetailRoutes,
  ],
);
