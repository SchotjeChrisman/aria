import 'package:go_router/go_router.dart';
import '../../core/phosphor_icons.dart';

import '../../core/router.dart';
import 'search_page.dart';

final searchFeatureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/search',
    label: 'Search',
    icon: PhosphorIconsThin.magnifyingGlass,
  ),
  routes: [GoRoute(path: '/search', builder: (_, _) => const SearchPage())],
);
