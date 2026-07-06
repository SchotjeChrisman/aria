import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'album_page.dart';

/// Detail page pushed above the shell (no nav tab). The integrator may nest
/// this under the library branch instead if per-tab back-stacks are wanted.
final featureEntry = FeatureEntry(
  routes: [
    GoRoute(
      path: '/album/:id',
      builder: (context, state) => AlbumPage(
        albumId: decodeAlbumRouteParam(state.pathParameters['id'] ?? ''),
      ),
    ),
  ],
);

String albumPath(String albumId) => '/album/${Uri.encodeComponent(albumId)}';

/// go_router hands back the raw (still-encoded) segment; decode defensively —
/// a literal '%' in an already-decoded value must not throw.
String decodeAlbumRouteParam(String v) {
  try {
    return Uri.decodeComponent(v);
  } catch (_) {
    return v;
  }
}
