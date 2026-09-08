// Playlists and the active profile live in core (the add-to-playlist menu
// in lib/widgets and the queue's save-as-playlist need them, and profile
// switches must re-scope everything immediately). The smart editor's filter
// option lists come from the library's trackFilterOptionsProvider — the same
// lists the Tracks filter offers, so the two forms cannot offer different
// values for the same field.
export '../../core/library_providers.dart' show libraryTracksProvider;
export '../../core/playlists_providers.dart'
    show PlaylistsNotifier, playlistTracksProvider, playlistsProvider;
export '../../core/profiles_providers.dart' show activeProfileIdProvider;
