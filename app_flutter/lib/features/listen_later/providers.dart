import 'package:aria_api/aria_api.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/profiles_providers.dart';
import '../../core/toast.dart';
import '../../widgets/context_menu.dart';
import '../../core/phosphor_icons.dart';

/// Albums saved to hear later. The server drops entries whose albums have
/// arrived in the library, so this list only ever holds things not owned.
final listenLaterProvider = FutureProvider<List<ListenLaterAlbum>>((ref) {
  final profileId = ref.watch(activeProfileIdProvider);
  return ref.watch(apiClientProvider).listenLater(profileId: profileId);
});

/// Saves an album and refreshes the list. Resolving the universal id costs a
/// round trip to Deezer and MusicBrainz the first time (~1-3s), so callers
/// should not block their UI on it beyond a toast.
Future<void> addToListenLater(
  BuildContext context,
  WidgetRef ref, {
  required String artist,
  required String title,
  int? deezerId,
}) async {
  final toaster = Toaster.of(context);
  try {
    await ref.read(apiClientProvider).addListenLater(
          artist: artist,
          title: title,
          profileId: ref.read(activeProfileIdProvider),
          deezerId: deezerId,
        );
    ref.invalidate(listenLaterProvider);
    toaster.show('Saved "$title" to Listen Later.');
  } catch (e) {
    toaster.show(
      e is AriaApiException ? e.message : 'Could not save "$title".',
      error: true,
    );
  }
}

Future<void> removeFromListenLater(
  BuildContext context,
  WidgetRef ref, {
  required String id,
  required String title,
}) async {
  final toaster = Toaster.of(context);
  try {
    await ref.read(apiClientProvider).removeListenLater(
          id,
          profileId: ref.read(activeProfileIdProvider),
        );
    ref.invalidate(listenLaterProvider);
    toaster.show('Removed "$title" from Listen Later.');
  } catch (e) {
    toaster.show(
      e is AriaApiException ? e.message : 'Could not remove "$title".',
      error: true,
    );
  }
}

/// The "Listen later" context-menu entry, shared by every surface that shows
/// an album nobody owns yet — the New Releases shelf and artist discographies.
AriaMenuItem listenLaterMenuItem(
  BuildContext context,
  WidgetRef ref, {
  required String artist,
  required String title,
  int? deezerId,
}) =>
    AriaMenuItem(
      'Listen later',
      () => addToListenLater(
        context,
        ref,
        artist: artist,
        title: title,
        deezerId: deezerId,
      ),
      icon: PhosphorIconsRegular.listPlus,
    );
