import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/library_providers.dart';
import '../../core/tags_providers.dart';

// Playlists and the active profile live in core (the add-to-playlist menu
// in lib/widgets and the queue's save-as-playlist need them, and profile
// switches must re-scope everything immediately).
export '../../core/library_providers.dart' show libraryTracksProvider;
export '../../core/playlists_providers.dart'
    show PlaylistsNotifier, playlistTracksProvider, playlistsProvider;
export '../../core/profiles_providers.dart' show activeProfileIdProvider;

final _tagNamesProvider = FutureProvider<List<String>>((ref) async {
  final tags = await ref.watch(tagsProvider.future);
  return [for (final t in tags) t.name];
});

/// Distinct library values per string filter field (legacy fieldValues()):
/// credited = everyone credited (artist, conductor, orchestra, performers),
/// genre = canonical genres, tag = tag names, the rest plain track fields.
final smartFieldValuesProvider = FutureProvider.family<List<String>, String>((
  ref,
  field,
) async {
  Iterable<String?> vals;
  if (field == 'tag') {
    vals = await ref.watch(_tagNamesProvider.future);
  } else {
    final tracks = await ref.watch(libraryTracksProvider.future);
    vals = switch (field) {
      'credited' => tracks.expand(
        (t) => [
          t.artist,
          t.conductor,
          t.orchestra,
          ...t.performers.map((p) => p.name),
        ],
      ),
      'genre' => tracks.expand((t) => t.genres),
      'artist' => tracks.map((t) => t.artist),
      'albumArtist' => tracks.map((t) => t.albumArtist),
      'composer' => tracks.map((t) => t.composer),
      'format' => tracks.map((t) => t.format),
      _ => const Iterable<String?>.empty(),
    };
  }
  final out = {
    for (final v in vals)
      if (v != null && v.isNotEmpty) v,
  }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return out;
});
