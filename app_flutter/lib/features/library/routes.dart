import 'package:go_router/go_router.dart';
import '../../core/phosphor_icons.dart';

import '../../core/router.dart';
import '../album/routes.dart' as album;
import '../artist/routes.dart' as artist;
import 'genre_screen.dart';
import 'library_screen.dart';

/// Library feature entries — one branch per section (rail items on wide
/// layouts) plus a hub branch that fronts them on narrow layouts.
final featureEntries = <FeatureEntry>[
  FeatureEntry(
    destination: const AppDestination(
      path: '/library',
      label: 'Library',
      icon: PhosphorIconsThin.musicNotes,
      selectedIcon: PhosphorIconsFill.musicNotes,
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
        // Detail pages live in their section's branch so the rail keeps the
        // section highlighted and the page renders in the content area.
        ...switch (s) {
          LibrarySection.albums => album.detailRoutes,
          LibrarySection.artists => artist.artistDetailRoutes,
          LibrarySection.composers => artist.composerDetailRoutes,
          _ => const <RouteBase>[],
        },
      ],
    ),
];
