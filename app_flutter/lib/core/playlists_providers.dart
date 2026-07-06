import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection.dart';
import 'profiles_providers.dart';

/// All playlists for the active profile (legacy fetchPlaylists()). Lives in
/// core so the add-to-playlist menu in lib/widgets and the playlists feature
/// share one cache; re-derives immediately on profile switch.
final playlistsProvider =
    AsyncNotifierProvider<PlaylistsNotifier, List<Playlist>>(
      PlaylistsNotifier.new,
    );

class PlaylistsNotifier extends AsyncNotifier<List<Playlist>> {
  @override
  Future<List<Playlist>> build() async {
    final client = ref.watch(apiClientProvider);
    // Wait for profiles once, then track the reactive id — switching
    // profiles in Settings re-scopes the list immediately (legacy
    // switchProfile()).
    await ref.watch(profilesProvider.future);
    final pid = ref.watch(activeProfileIdProvider);
    return client.playlists(profileId: pid);
  }

  Future<String> _requireProfile() async {
    await ref.read(profilesProvider.future);
    final pid = ref.read(activeProfileIdProvider);
    if (pid == null) throw StateError('No profile yet — create one first.');
    return pid;
  }

  Future<Playlist> createManual(String name) async {
    final pid = await _requireProfile();
    final pl = await ref
        .read(apiClientProvider)
        .createPlaylist(profileId: pid, name: name);
    ref.invalidateSelf();
    return pl;
  }

  Future<Playlist> createSmart(String name, SmartRules rules) async {
    final pid = await _requireProfile();
    final pl = await ref
        .read(apiClientProvider)
        .createPlaylist(profileId: pid, name: name, rules: rules);
    ref.invalidateSelf();
    return pl;
  }

  Future<void> rename(String id, String name) async {
    await ref.read(apiClientProvider).updatePlaylist(id, name: name);
    ref.invalidateSelf();
  }

  Future<void> updateSmart(
    String id, {
    required String name,
    required SmartRules rules,
  }) async {
    await ref
        .read(apiClientProvider)
        .updatePlaylist(id, name: name, rules: rules);
    ref.invalidateSelf();
    ref.invalidate(playlistTracksProvider(id));
  }

  Future<void> deletePlaylist(String id) async {
    await ref.read(apiClientProvider).deletePlaylist(id);
    ref.invalidateSelf();
  }

  Future<void> addTrack(String playlistId, String trackId) async {
    await ref.read(apiClientProvider).addPlaylistTrack(playlistId, trackId);
    ref.invalidateSelf();
    ref.invalidate(playlistTracksProvider(playlistId));
  }

  /// Legacy bulk add: sequential to keep order; per-track failures skipped.
  Future<void> addTracks(String playlistId, Iterable<String> trackIds) async {
    final client = ref.read(apiClientProvider);
    for (final id in trackIds) {
      try {
        await client.addPlaylistTrack(playlistId, id);
      } catch (_) {}
    }
    ref.invalidateSelf();
    ref.invalidate(playlistTracksProvider(playlistId));
  }

  /// Removes ALL occurrences of the track (server semantics).
  Future<void> removeTrack(String playlistId, String trackId) async {
    await ref.read(apiClientProvider).removePlaylistTrack(playlistId, trackId);
    ref.invalidateSelf();
    ref.invalidate(playlistTracksProvider(playlistId));
  }
}

/// Resolved tracks of one playlist. autoDispose so re-entering a smart
/// playlist re-evaluates its rules server-side.
final playlistTracksProvider = FutureProvider.autoDispose
    .family<List<Track>, String>(
      (ref, id) => ref.watch(apiClientProvider).playlistTracks(id),
    );
