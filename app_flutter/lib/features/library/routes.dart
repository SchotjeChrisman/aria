import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'genre_screen.dart';
import 'library_screen.dart';

/// Library feature entries — one branch per section (rail items on wide
/// layouts) plus a hub branch that fronts them on narrow layouts.
final featureEntries = <FeatureEntry>[
  FeatureEntry(
    destination: const AppDestination(
      path: '/library',
      label: 'Library',
      icon: Icons.library_music_outlined,
      selectedIcon: Icons.library_music,
      inRail: false,
    ),
    routes: [
      GoRoute(path: '/library', builder: (_, _) => const LibraryHubScreen()),
    ],
  ),
  for (final s in LibrarySection.values)
    FeatureEntry(
      destination: AppDestination(
        path: s.path,
        label: s.label,
        icon: s.icon,
        selectedIcon: s.selectedIcon,
        inBar: false,
      ),
      routes: [
        GoRoute(
          path: s.path,
          builder: (_, _) => LibraryScreen(section: s),
          routes: [
            if (s == LibrarySection.genres)
              GoRoute(
                path: ':name',
                builder: (_, state) =>
                    GenreScreen(genre: state.pathParameters['name']!),
              ),
          ],
        ),
      ],
    ),
];
