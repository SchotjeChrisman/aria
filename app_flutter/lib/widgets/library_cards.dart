import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/connection.dart';
import 'album_card.dart';
import 'context_menu.dart';
import 'selection_highlight.dart';
import 'track_actions.dart';

// The standard grid/shelf card wiring (legacy albumCtx/artistCtx), shared by
// home, library and search: selection highlight, tap = extend an active
// multi-select or navigate, secondary/long-press = context menu.

/// [AlbumCard] with the standard wiring.
class AlbumGridCard extends ConsumerWidget {
  const AlbumGridCard({
    super.key,
    required this.albumId,
    required this.title,
    required this.artistName,
    required this.tracks,
    required this.hasArt,
    this.subtitle,
  });

  final String albumId;
  final String title;

  /// Album artist — the context menu's "Go to artist" target.
  final String artistName;

  /// The album's tracks in play order (queue/selection payload).
  final List<Track> tracks;
  final bool hasArt;

  /// Card sub-line; defaults to [artistName].
  final String? subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiClientProvider);
    return SelectionHighlight(
      kind: 'album',
      itemKey: albumId,
      child: AlbumCard(
        title: title,
        subtitle: subtitle ?? artistName,
        artUrl: hasArt
            ? api.artUrl(albumId,
                version: tracks.isEmpty ? null : tracks.first.artVersion)
            : null,
        onTap: () {
          if (selectionTapHandled(ref, albumSelectionItem(albumId, tracks))) {
            return;
          }
          context.push(albumPath(albumId));
        },
        onSecondary: (pos) => showAriaContextMenu(
          context,
          pos,
          albumMenuItems(
            context,
            ref,
            albumId: albumId,
            tracks: tracks,
            artistName: artistName,
          ),
        ),
      ),
    );
  }
}

/// The same wiring for an artist tile, wrapped around any visual (PersonCard,
/// avatar column). [tracksOf] gathers everything credited to the name and is
/// only called when a tap/menu actually needs it.
class ArtistTile extends ConsumerWidget {
  const ArtistTile({
    super.key,
    required this.name,
    required this.tracksOf,
    required this.child,
  });

  final String name;
  final List<Track> Function() tracksOf;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void menu(Offset pos) => showAriaContextMenu(
      context,
      pos,
      artistMenuItems(context, ref, name: name, tracks: tracksOf()),
    );
    return SelectionHighlight(
      kind: 'artist',
      itemKey: name,
      child: GestureDetector(
        onTap: () {
          if (selectionTapHandled(ref, artistSelectionItem(name, tracksOf()))) {
            return;
          }
          context.push(artistPath(name));
        },
        onSecondaryTapUp: (d) => menu(d.globalPosition),
        onLongPressStart: (d) => menu(d.globalPosition),
        child: child,
      ),
    );
  }
}
