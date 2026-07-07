import 'package:go_router/go_router.dart';

import 'artist_page.dart';
import 'artist_util.dart';
import 'composer_page.dart';

/// Detail routes mounted inside the matching library shell branches so they
/// render in the content area, not above the shell.
final artistDetailRoutes = <RouteBase>[
  GoRoute(
    path: '/artist/:name',
    builder: (context, state) => ArtistPage(
      name: decodeArtistRouteParam(state.pathParameters['name'] ?? ''),
    ),
  ),
];

final composerDetailRoutes = <RouteBase>[
  GoRoute(
    path: '/composer/:name',
    builder: (context, state) => ComposerPage(
      name: decodeArtistRouteParam(state.pathParameters['name'] ?? ''),
    ),
  ),
];
