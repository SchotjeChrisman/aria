import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'genre_screen.dart';
import 'library_screen.dart';

/// Library feature entry — wire into core featureEntries.
final featureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/library',
    label: 'Library',
    icon: Icons.library_music_outlined,
    selectedIcon: Icons.library_music,
  ),
  routes: [
    GoRoute(
      path: '/library',
      builder: (_, _) => const LibraryScreen(),
      routes: [
        GoRoute(
          path: 'genre/:name',
          builder: (_, state) =>
              GenreScreen(genre: state.pathParameters['name']!),
        ),
      ],
    ),
  ],
);
