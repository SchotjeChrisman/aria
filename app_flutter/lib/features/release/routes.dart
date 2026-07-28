import 'package:go_router/go_router.dart';

import 'release_page.dart';

/// Detail route for an album that is not in the library. Mounted in the
/// Listen Later branch, like /album/:id lives in the albums branch.
final releaseDetailRoutes = <RouteBase>[
  GoRoute(
    path: '/release/:artist/:title',
    builder: (_, state) => ReleasePage(
      ref_: ReleaseRef(
        _decode(state.pathParameters['artist'] ?? ''),
        _decode(state.pathParameters['title'] ?? ''),
        deezerId: int.tryParse(state.uri.queryParameters['deezerId'] ?? ''),
      ),
    ),
  ),
];

String releasePath(String artist, String title, {int? deezerId}) {
  final p = '/release/${Uri.encodeComponent(artist)}/${Uri.encodeComponent(title)}';
  return deezerId == null ? p : '$p?deezerId=$deezerId';
}

/// go_router hands back the raw segment; decode defensively so a literal '%'
/// in an already-decoded value can't throw (same guard as album routes).
String _decode(String v) {
  try {
    return Uri.decodeComponent(v);
  } catch (_) {
    return v;
  }
}
