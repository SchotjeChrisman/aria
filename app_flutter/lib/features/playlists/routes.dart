import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'playlist_screen.dart';
import 'playlists_screen.dart';

/// Playlists tab: /playlists (list) and /playlists/:id (detail).
final featureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/playlists',
    label: 'Playlists',
    icon: Icons.queue_music_outlined,
    selectedIcon: Icons.queue_music,
  ),
  routes: [
    GoRoute(
      path: '/playlists',
      builder: (_, _) => const PlaylistsScreen(),
      routes: [
        GoRoute(
          path: ':id',
          builder: (_, state) =>
              PlaylistScreen(id: state.pathParameters['id']!),
        ),
      ],
    ),
  ],
);
