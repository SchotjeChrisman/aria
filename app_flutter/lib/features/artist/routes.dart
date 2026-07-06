import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'artist_page.dart';
import 'artist_util.dart';
import 'composer_page.dart';

/// Detail pages pushed above the shell (no nav tab). The integrator may nest
/// these under the library branch instead if per-tab back-stacks are wanted.
final featureEntry = FeatureEntry(
  routes: [
    GoRoute(
      path: '/artist/:name',
      builder: (context, state) => ArtistPage(
        name: decodeArtistRouteParam(state.pathParameters['name'] ?? ''),
      ),
    ),
    GoRoute(
      path: '/composer/:name',
      builder: (context, state) => ComposerPage(
        name: decodeArtistRouteParam(state.pathParameters['name'] ?? ''),
      ),
    ),
  ],
);
