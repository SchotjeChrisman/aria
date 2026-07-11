import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/downloads.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/album_card.dart';
import '../../widgets/artist_avatar.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/selection_highlight.dart';
import '../../widgets/shelf.dart';
import '../../widgets/track_actions.dart';
import '../../widgets/track_row.dart';
import 'providers.dart';
import 'tag_grid.dart';
import 'tag_tree.dart';

/// Legacy renderTag(): a parent tag page shows everything under it,
/// descendants included — artist shelf, album shelf, track rows.
class TagScreen extends ConsumerWidget {
  const TagScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags = ref.watch(tagsProvider);
    final index = ref.watch(libraryIndexProvider);

    final body = switch ((tags, index)) {
      (AsyncData(value: final all), AsyncData(value: final idx)) => _build(
        context,
        ref,
        all,
        idx,
      ),
      (AsyncError(), _) ||
      (_, AsyncError()) => const EmptyState(message: 'Tag unavailable.'),
      _ => const Center(child: CircularProgressIndicator()),
    };
    return Scaffold(appBar: AppBar(), body: body);
  }

  Widget _build(
    BuildContext context,
    WidgetRef ref,
    List<Tag> all,
    LibraryIndex idx,
  ) {
    final tag = tagById(all, id);
    if (tag == null) return const EmptyState(message: 'Tag not found.');

    // Folder page: just its tags as a grid — folders hold tags, not items.
    if (tag.folder) {
      final inFolder = tagsInFolder(all, tag.id);
      return ListView(
        padding: ariaPagePadding(context, top: 0),
        children: [
          Text(tag.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AriaSpace.s5),
          if (inFolder.isEmpty)
            const EmptyState(
              message: 'This folder is empty — right-click / long-press a tag '
                  'and pick "Move to folder…".',
            )
          else
            TagGrid(all: all, tags: inFolder),
        ],
      );
    }

    final c = AriaColors.of(context);
    final client = ref.watch(apiClientProvider);
    final currentId = ref.watch(currentTrackProvider)?.id;

    final kids = tagKids(all, tag.id)..sort((a, b) => a.name.compareTo(b.name));

    // Items over the tag + descendants, deduped by kind+key.
    final seen = <String>{};
    final items = <TagItem>[
      for (final t in tagWithDescendants(all, tag))
        for (final i in t.items)
          if (seen.add('${i.kind}\n${i.key}')) i,
    ];
    final artistNames = [
      for (final i in items)
        if (i.kind == 'artist') i.key,
    ];
    final albumGroups = [
      for (final i in items)
        if (i.kind == 'album' && idx.albums[i.key] != null) idx.albums[i.key]!,
    ];
    final trackList = [
      for (final i in items)
        if (i.kind == 'track' && idx.byId[i.key] != null) idx.byId[i.key]!,
    ];

    return ListView(
      padding: ariaPagePadding(context, top: 0),
      children: [
        Text(tag.name, style: Theme.of(context).textTheme.titleLarge),
        if (tag.parent != null) ...[
          const SizedBox(height: AriaSpace.s1),
          Text(
            tagPath(all, tag),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (kids.isNotEmpty) ...[
          const SizedBox(height: AriaSpace.s3),
          Wrap(
            spacing: AriaSpace.s2,
            runSpacing: AriaSpace.s2,
            children: [
              for (final k in kids)
                ActionChip(
                  label: Text(k.name),
                  onPressed: () => context.push('/tags/${k.id}'),
                ),
            ],
          ),
        ],
        const SizedBox(height: AriaSpace.s5),
        if (artistNames.isNotEmpty) ...[
          Shelf(
            title: 'Artists',
            height: 168,
            itemCount: artistNames.length,
            itemWidth: 120,
            itemBuilder: (context, i) {
              final name = artistNames[i];
              List<Track> artistTracks() => [
                for (final t in idx.byId.values)
                  if (t.artist == name || t.albumArtist == name) t,
              ];
              return SelectionHighlight(
                kind: 'artist',
                itemKey: name,
                child: GestureDetector(
                  onTap: () {
                    if (selectionTapHandled(
                      ref,
                      artistSelectionItem(name, artistTracks()),
                    )) {
                      return;
                    }
                    context.push(artistPath(name));
                  },
                  onSecondaryTapUp: (d) => showAriaContextMenu(
                    context,
                    d.globalPosition,
                    artistMenuItems(
                      context,
                      ref,
                      name: name,
                      tracks: artistTracks(),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ArtistAvatar(name: name, size: 120),
                      const SizedBox(height: AriaSpace.s2),
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (idx.artistNames.contains(name))
                        Text(
                          'In library',
                          style: TextStyle(color: c.fgDim, fontSize: 12),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: AriaSpace.s6),
        ],
        if (albumGroups.isNotEmpty) ...[
          Shelf(
            title: 'Albums',
            height: 236,
            itemCount: albumGroups.length,
            itemBuilder: (context, i) {
              final a = albumGroups[i];
              return SelectionHighlight(
                kind: 'album',
                itemKey: a.id,
                child: AlbumCard(
                  title: a.album,
                  subtitle: a.albumArtist,
                  artUrl: client.artUrl(a.id,
                      version: a.tracks.isEmpty ? null : a.tracks.first.artVersion),
                  onTap: () {
                    if (selectionTapHandled(
                      ref,
                      albumSelectionItem(a.id, a.tracks),
                    )) {
                      return;
                    }
                    context.push(albumPath(a.id));
                  },
                  onSecondary: (pos) => showAriaContextMenu(
                    context,
                    pos,
                    albumMenuItems(
                      context,
                      ref,
                      albumId: a.id,
                      tracks: a.tracks,
                      artistName: a.albumArtist,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: AriaSpace.s6),
        ],
        if (trackList.isNotEmpty) ...[
          Text('Tracks', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AriaSpace.s3),
          for (final (i, t) in trackList.indexed)
            SelectionHighlight(
              kind: 'track',
              itemKey: t.id,
              child: TrackRow(
                number: i + 1,
                title: t.title ?? 'Unknown',
                subtitle: [
                  t.artist,
                  t.album,
                ].where((s) => s != null && s.isNotEmpty).join(' · '),
                duration: t.duration,
                format: t.format,
                bitsPerSample: t.bitsPerSample,
                sampleRate: t.sampleRate,
                lossless: t.lossless,
                downloaded: ref.watch(
                  downloadsProvider.select((s) => s.index.containsKey(t.id)),
                ),
                isCurrent: t.id == currentId,
                onTap: () {
                  if (selectionTapHandled(ref, trackSelectionItem(t))) return;
                  ref.read(queueProvider.notifier).playQueue(trackList, i);
                },
                onSecondary: (pos) => showAriaContextMenu(
                  context,
                  pos,
                  trackMenuItems(context, ref, t),
                ),
              ),
            ),
        ],
        if (artistNames.isEmpty && albumGroups.isEmpty && trackList.isEmpty)
          const EmptyState(
            message:
                'Nothing tagged yet — right-click / long-press any track, '
                'album or artist and pick "Tags…".',
          ),
      ],
    );
  }
}
