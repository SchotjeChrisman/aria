import 'package:go_router/go_router.dart';

import 'album_page.dart';

/// Detail routes mounted inside the library/albums shell branch so they
/// render in the content area, not above the shell.
final detailRoutes = <RouteBase>[
  GoRoute(
    path: '/album/:id',
    builder: (context, state) => AlbumPage(
      albumId: decodeAlbumRouteParam(state.pathParameters['id'] ?? ''),
    ),
  ),
];

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
