import '../../core/library_providers.dart';

/// The whole-library cache and its derived lookups live in core (one fetch
/// for every feature); these are search's historical names for them.
export '../../core/library_providers.dart'
    show AlbumEntry, libraryTracksProvider, peopleProvider, trackByIdProvider;

/// albumId -> AlbumEntry (legacy albums map).
final albumsProvider = libraryAlbumsProvider;
