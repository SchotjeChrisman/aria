import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/profiles_providers.dart';

/// Stats for the active profile (legacy: "stats are private per profile —
/// always the active one, no combined view"). Waits for the profile to
/// resolve so an early fetch never returns all-profile stats.
final statsProvider = FutureProvider<Stats>((ref) async {
  final profileId = ref.watch(activeProfileIdProvider);
  if (profileId == null) {
    // Profiles still loading — surface that instead of unscoped stats.
    await ref.watch(profilesProvider.future);
  }
  final pid = profileId ?? ref.read(activeProfileIdProvider);
  return ref.watch(apiClientProvider).stats(profileId: pid);
});
