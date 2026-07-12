import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/phosphor_icons.dart';
import '../core/toast.dart';

import '../core/downloads.dart';
import '../core/player_providers.dart';
import '../core/playlists_providers.dart';
import '../core/selection.dart';
import '../core/theme.dart';
import 'context_menu.dart';
import 'name_dialog.dart';
import 'tag_picker.dart';

// The standard context-menu vocabulary, shared by every view (legacy
// trackCtx/albumCtx/artistCtx/openAddMenu/bulkPlaylistMenu): features build
// their menus from these so whole albums/artists can be queued, tracks can
// be added to playlists/tags anywhere, and any row can start a selection.

/// Route contracts (features never import each other's routes).
String albumPath(String albumId) => '/album/$albumId';
String artistPath(String name) => '/artist/${Uri.encodeComponent(name)}';

// ------------------------------------------------------------ playlists

/// Legacy openAddMenu/bulkPlaylistMenu: pick a manual playlist (or create
/// one) and append [tracks] in order.
Future<void> showAddToPlaylistMenu(
  BuildContext context, {
  required List<Track> tracks,
}) {
  if (tracks.isEmpty) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => Consumer(
      builder: (context, ref, _) {
        final c = AriaColors.of(context);
        final pls = (ref.watch(playlistsProvider).value ?? const <Playlist>[])
            .where((p) => !p.isSmart)
            .toList();

        Future<void> addAll(String playlistId, String name) async {
          Navigator.of(context).pop();
          final toast = Toaster.of(context);
          await ref.read(playlistsProvider.notifier).addTracks(playlistId, [
            for (final t in tracks) t.id,
          ]);
          toast.show(
            'Added ${tracks.length} '
            'track${tracks.length == 1 ? '' : 's'} to "$name"',
          );
        }

        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final p in pls)
                ListTile(
                  title: Text(p.name),
                  trailing: Text(
                    '${p.trackIds?.length ?? 0}',
                    style: TextStyle(color: c.fgDim),
                  ),
                  onTap: () => addAll(p.id, p.name),
                ),
              ListTile(
                leading: const Icon(PhosphorIconsRegular.plus, size: 18),
                title: Text(pls.isEmpty ? 'New playlist…' : '＋ New playlist…'),
                onTap: () async {
                  final name = await promptName(
                    context,
                    title: 'New playlist',
                    placeholder: 'Playlist name',
                  );
                  if (name == null || !context.mounted) return;
                  try {
                    final pl = await ref
                        .read(playlistsProvider.notifier)
                        .createManual(name);
                    if (context.mounted) await addAll(pl.id, pl.name);
                  } catch (e) {
                    if (context.mounted) {
                      showToast(
                        context,
                        e is AriaApiException
                            ? e.message
                            : 'Could not create playlist.',
                        error: true,
                      );
                    }
                  }
                },
              ),
            ],
          ),
        );
      },
    ),
  );
}

// ------------------------------------------------------------ selection

/// While multi-select is active, a tap toggles membership instead of its
/// normal action (legacy wireSelect capture handler). Returns true when the
/// tap was consumed.
bool selectionTapHandled(WidgetRef ref, SelectionItem item) {
  if (!ref.read(selectionProvider).active) return false;
  ref.read(selectionProvider.notifier).toggle(item);
  return true;
}

SelectionItem trackSelectionItem(Track t) =>
    SelectionItem(kind: 'track', key: t.id, tracks: [t]);

SelectionItem albumSelectionItem(String albumId, List<Track> tracks) =>
    SelectionItem(kind: 'album', key: albumId, tracks: tracks);

SelectionItem artistSelectionItem(String name, List<Track> tracks) =>
    SelectionItem(kind: 'artist', key: name, tracks: tracks);

// ------------------------------------------------------------ downloads

/// "Download" until every track in [tracks] is downloaded, then
/// "Remove download". Queueing dedupes, so partial album downloads resume.
AriaMenuItem downloadMenuItem(WidgetRef ref, List<Track> tracks) {
  final index = ref.read(downloadsProvider).index;
  final all =
      tracks.isNotEmpty && tracks.every((t) => index.containsKey(t.id));
  final downloads = ref.read(downloadsProvider.notifier);
  return all
      ? AriaMenuItem('Remove download', () {
          for (final t in tracks) {
            downloads.remove(t.id);
          }
        }, icon: PhosphorIconsRegular.cloudSlash)
      : AriaMenuItem(
          'Download',
          () => downloads.downloadTracks(tracks),
          icon: PhosphorIconsRegular.downloadSimple,
        );
}

// ---------------------------------------------------------------- menus

/// Legacy trackCtx: Play / Play next / Add to queue / Add to playlist… /
/// Tags… / Go to album / Go to artist / [extra] / Select…
List<AriaMenuItem> trackMenuItems(
  BuildContext context,
  WidgetRef ref,
  Track t, {
  bool goToAlbum = true,
  bool goToArtist = true,
  List<AriaMenuItem> extra = const [],
}) {
  final queue = ref.read(queueProvider.notifier);
  return [
    AriaMenuItem(
      'Play',
      () => queue.playQueue([t], 0),
      icon: PhosphorIconsRegular.play,
    ),
    AriaMenuItem(
      'Play next',
      () => queue.queueNext([t]),
      icon: PhosphorIconsRegular.rowsPlusTop,
    ),
    AriaMenuItem(
      'Add to queue',
      () => queue.queueAdd([t]),
      icon: PhosphorIconsRegular.listPlus,
    ),
    AriaMenuItem(
      'Add to playlist…',
      () => showAddToPlaylistMenu(context, tracks: [t]),
      icon: PhosphorIconsRegular.listChecks,
    ),
    AriaMenuItem(
      'Tags…',
      () => showTagPicker(context, kind: 'track', key: t.id),
      icon: PhosphorIconsRegular.tag,
    ),
    downloadMenuItem(ref, [t]),
    if (goToAlbum)
      AriaMenuItem(
        'Go to album',
        () => context.push(albumPath(t.albumId)),
        icon: PhosphorIconsRegular.vinylRecord,
      ),
    if (goToArtist && (t.artist ?? '').isNotEmpty)
      AriaMenuItem(
        'Go to artist',
        () => context.push(artistPath(t.artist!)),
        icon: PhosphorIconsRegular.user,
      ),
    ...extra,
    AriaMenuItem(
      'Select…',
      () => ref.read(selectionProvider.notifier).enter(trackSelectionItem(t)),
      icon: PhosphorIconsRegular.checkSquare,
    ),
  ];
}

/// Legacy albumCtx: Play / Play next / Add to queue / Add to playlist… /
/// Tags… / Go to artist / [extra] / Select…
List<AriaMenuItem> albumMenuItems(
  BuildContext context,
  WidgetRef ref, {
  required String albumId,
  required List<Track> tracks,
  String? artistName,
  List<AriaMenuItem> extra = const [],
}) {
  final queue = ref.read(queueProvider.notifier);
  return [
    AriaMenuItem(
      'Play',
      () => queue.playQueue(tracks, 0),
      icon: PhosphorIconsRegular.play,
    ),
    AriaMenuItem(
      'Play next',
      () => queue.queueNext(tracks),
      icon: PhosphorIconsRegular.rowsPlusTop,
    ),
    AriaMenuItem(
      'Add to queue',
      () => queue.queueAdd(tracks),
      icon: PhosphorIconsRegular.listPlus,
    ),
    AriaMenuItem(
      'Add to playlist…',
      () => showAddToPlaylistMenu(context, tracks: tracks),
      icon: PhosphorIconsRegular.listChecks,
    ),
    AriaMenuItem(
      'Tags…',
      () => showTagPicker(context, kind: 'album', key: albumId),
      icon: PhosphorIconsRegular.tag,
    ),
    downloadMenuItem(ref, tracks),
    if (artistName != null && artistName.isNotEmpty)
      AriaMenuItem(
        'Go to artist',
        () => context.push(artistPath(artistName)),
        icon: PhosphorIconsRegular.user,
      ),
    ...extra,
    AriaMenuItem(
      'Select…',
      () => ref
          .read(selectionProvider.notifier)
          .enter(albumSelectionItem(albumId, tracks)),
      icon: PhosphorIconsRegular.checkSquare,
    ),
  ];
}

/// Legacy artistCtx: Play all / Add to queue / Tags… / [extra] / Select…
List<AriaMenuItem> artistMenuItems(
  BuildContext context,
  WidgetRef ref, {
  required String name,
  required List<Track> tracks,
  List<AriaMenuItem> extra = const [],
}) {
  final queue = ref.read(queueProvider.notifier);
  return [
    if (tracks.isNotEmpty) ...[
      AriaMenuItem(
        'Play all',
        () => queue.playQueue(tracks, 0),
        icon: PhosphorIconsRegular.play,
      ),
      AriaMenuItem(
        'Add to queue',
        () => queue.queueAdd(tracks),
        icon: PhosphorIconsRegular.listPlus,
      ),
      AriaMenuItem(
        'Add to playlist…',
        () => showAddToPlaylistMenu(context, tracks: tracks),
        icon: PhosphorIconsRegular.listChecks,
      ),
    ],
    AriaMenuItem(
      'Tags…',
      () => showTagPicker(context, kind: 'artist', key: name),
      icon: PhosphorIconsRegular.tag,
    ),
    ...extra,
    AriaMenuItem(
      'Select…',
      () => ref
          .read(selectionProvider.notifier)
          .enter(artistSelectionItem(name, tracks)),
      icon: PhosphorIconsRegular.checkSquare,
    ),
  ];
}
