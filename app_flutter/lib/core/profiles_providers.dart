import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection.dart';

// The single source of truth for the active profile. Legacy switchProfile()
// re-scoped plays, playlists and stats immediately — everything watching
// [activeProfileIdProvider] re-derives on switch.

// Legacy profileForm PALETTE — the 8 fixed avatar colors.
const profilePalette = [
  '#6d3fd2',
  '#d23f6d',
  '#d2803f',
  '#3fd26d',
  '#3f8ad2',
  '#d2c43f',
  '#8a3fd2',
  '#3fd2c4',
];

/// Legacy stored it in electron config as cfg.profileId.
const prefsKeyProfileId = 'aria.profileId';

/// All profiles. Server guarantees at least one ("Listener" on first boot).
final profilesProvider = FutureProvider<List<Profile>>(
  (ref) => ref.watch(apiClientProvider).profiles(),
);

/// Persisted active-profile id, unvalidated. Prefer [activeProfileProvider]
/// which falls back to the first profile when the saved id is gone (legacy
/// loadProfiles semantics).
final savedProfileIdProvider =
    NotifierProvider<SavedProfileIdNotifier, String?>(
      SavedProfileIdNotifier.new,
    );

class SavedProfileIdNotifier extends Notifier<String?> {
  @override
  String? build() => ref.read(sharedPrefsProvider).getString(prefsKeyProfileId);

  Future<void> set(String id) async {
    state = id;
    await ref.read(sharedPrefsProvider).setString(prefsKeyProfileId, id);
  }
}

/// The active profile, validated against the loaded list. Null only while
/// profiles are loading or the server is unreachable.
final activeProfileProvider = Provider<Profile?>((ref) {
  final profiles = ref.watch(profilesProvider).value;
  if (profiles == null || profiles.isEmpty) return null;
  final saved = ref.watch(savedProfileIdProvider);
  return profiles.where((p) => p.id == saved).firstOrNull ?? profiles.first;
});

/// Active profile id for API calls (stats, plays, playlists). Null until
/// profiles load; reacts to profile switches immediately.
final activeProfileIdProvider = Provider<String?>(
  (ref) => ref.watch(activeProfileProvider)?.id,
);

/// CRUD verbs. Every mutation refreshes [profilesProvider]; watchers of
/// [activeProfileProvider] re-derive (legacy switchProfile re-rendered all).
final profileActionsProvider = Provider<ProfileActions>(ProfileActions.new);

class ProfileActions {
  ProfileActions(this._ref);

  final Ref _ref;

  AriaClient get _client => _ref.read(apiClientProvider);

  void switchTo(String id) {
    _ref.read(savedProfileIdProvider.notifier).set(id);
  }

  /// Creates and immediately switches to the new profile (legacy behavior).
  Future<Profile> create({required String name, required String color}) async {
    final p = await _client.createProfile(name: name, color: color);
    _ref.invalidate(profilesProvider);
    switchTo(p.id);
    return p;
  }

  Future<void> rename(String id, {String? name, String? color}) async {
    await _client.updateProfile(id, name: name, color: color);
    _ref.invalidate(profilesProvider);
  }

  /// Throws AriaApiException on the last remaining profile (server 400).
  Future<void> delete(String id) async {
    await _client.deleteProfile(id);
    _ref.invalidate(profilesProvider);
  }
}
