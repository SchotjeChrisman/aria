import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'tag_screen.dart';
import 'tags_screen.dart';

/// Tags tab: /tags (tree) and /tags/:id (detail).
final featureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/tags',
    label: 'Tags',
    icon: Icons.sell_outlined,
    selectedIcon: Icons.sell,
  ),
  routes: [
    GoRoute(
      path: '/tags',
      builder: (_, _) => const TagsScreen(),
      routes: [
        GoRoute(
          path: ':id',
          builder: (_, state) => TagScreen(id: state.pathParameters['id']!),
        ),
      ],
    ),
  ],
);
