import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/library_providers.dart';

/// Core client/caches under this feature's historical names — one HTTP
/// client and one /api/tracks fetch shared app-wide; invalidating
/// [albumTracksProvider] (metadata edits) refreshes every feature.
final albumApiProvider = apiClientProvider;
final albumTracksProvider = libraryTracksProvider;

final albumsByIdProvider = FutureProvider<Map<String, Album>>((ref) async {
  final tracks = await ref.watch(albumTracksProvider.future);
  return {for (final a in Album.group(tracks)) a.id: a};
});

/// Label/date/country (MusicBrainz) + blurb (Wikipedia), cached server-side.
/// null = nothing known about this album yet.
final albumInfoProvider = FutureProvider.family<AlbumInfo?, String>(
  (ref, albumId) => ref.watch(albumApiProvider).albumInfo(albumId),
);

/// name -> portrait URL, for the performer credit cards.
final albumPeopleProvider = peopleProvider;
