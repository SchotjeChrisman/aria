// The whole-library cache and its derived lookups live in core (one fetch
// for every feature); these are search's historical names for them.
export '../../core/library_providers.dart'
    show libraryTracksProvider, peopleProvider, trackByIdProvider;

// Albums grouped from the flat track list (canonical aria_api Album.group
// derivation, computed once by the library feature and shared here).
export '../library/library_providers.dart' show albumsProvider;
