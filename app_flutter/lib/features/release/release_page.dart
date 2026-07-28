import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/formats.dart';
import '../../core/phosphor_icons.dart';
import '../../core/theme.dart';
import '../../widgets/empty_state.dart';
import '../album/album_page.dart';
import '../album/external_link.dart';
import '../album/providers.dart';
import '../artist/artist_util.dart';
import '../listen_later/providers.dart';

/// Identifies an album the library does not have. Deliberately artist+title
/// rather than the universal id: it is what a shelf card already holds, it
/// keeps the route readable like `/artist/:name`, and the server owns the
/// translation to a release-group MBID.
class ReleaseRef {
  const ReleaseRef(this.artist, this.title, {this.deezerId});

  final String artist;
  final String title;
  final int? deezerId;

  @override
  bool operator ==(Object other) =>
      other is ReleaseRef &&
      other.artist == artist &&
      other.title == title &&
      other.deezerId == deezerId;

  @override
  int get hashCode => Object.hash(artist, title, deezerId);
}

/// Infused detail for an album nobody here owns. Cached 30 days server-side,
/// so repeat visits are local.
final extAlbumProvider = FutureProvider.family<ExtAlbum?, ReleaseRef>(
  (ref, r) => ref
      .watch(apiClientProvider)
      .extAlbum(r.artist, r.title, deezerId: r.deezerId),
);

/// The library album matching [r], or null when it genuinely isn't owned.
/// Matching mirrors the server's fallback rule (artist + edition-tolerant
/// title) so the app and the server agree on what "owned" means.
final ownedAlbumProvider = FutureProvider.family<Album?, ReleaseRef>((
  ref,
  r,
) async {
  final albums = await ref.watch(albumsByIdProvider.future);
  final key = normTitle(r.title);
  for (final a in albums.values) {
    if (a.albumArtist.toLowerCase() == r.artist.toLowerCase() &&
        normTitle(a.title) == key) {
      return a;
    }
  }
  return null;
});

/// Album page for a record that isn't in the library — the discovery
/// counterpart of the artist page, which has always rendered for people the
/// library doesn't hold. Hands off to the real [AlbumPage] the moment the
/// album is actually owned, so the route stays valid after you buy it.
class ReleasePage extends ConsumerWidget {
  const ReleasePage({super.key, required this.ref_});

  final ReleaseRef ref_;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owned = ref.watch(ownedAlbumProvider(ref_)).value;
    if (owned != null) return AlbumPage(albumId: owned.id);

    final async = ref.watch(extAlbumProvider(ref_));
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: switch (async) {
          AsyncLoading() => const Center(child: CircularProgressIndicator()),
          AsyncError() => EmptyState(
            message: 'Could not look up "${ref_.title}".',
            icon: PhosphorIconsRegular.cloudSlash,
            action: OutlinedButton(
              onPressed: () => ref.invalidate(extAlbumProvider(ref_)),
              child: const Text('Retry'),
            ),
          ),
          AsyncData(value: null) => EmptyState(
            message: 'Nothing found for "${ref_.title}".',
            icon: PhosphorIconsRegular.vinylRecord,
          ),
          AsyncData(:final value) => _Body(album: value!, ref_: ref_),
        },
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.album, required this.ref_});

  final ExtAlbum album;
  final ReleaseRef ref_;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final saved = ref.watch(listenLaterProvider).value ?? const [];
    final isSaved = saved.any((e) => e.id == album.id);

    final meta = [
      if (album.date.length >= 4) album.date.substring(0, 4),
      if (album.type != 'album') album.type,
      if (album.tracks.isNotEmpty)
        '${album.tracks.length} track${album.tracks.length == 1 ? '' : 's'}',
      if (album.label != null && album.label!.isNotEmpty) album.label!,
    ].join(' · ');

    return ListView(
      padding: ariaPagePadding(context),
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 520;
            final art = _Cover(album: album, ref_: ref_, size: wide ? 220 : 160);
            final text = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(album.title,
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: AriaSpace.s2),
                InkWell(
                  onTap: () =>
                      context.push(artistPath(album.artist)),
                  child: Text(
                    album.artist,
                    style: TextStyle(color: c.accent, fontSize: 15),
                  ),
                ),
                const SizedBox(height: AriaSpace.s2),
                Text(meta, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: AriaSpace.s2),
                Text('Not in library', style: TextStyle(color: c.fgDim)),
                const SizedBox(height: AriaSpace.s4),
                Wrap(
                  spacing: AriaSpace.s3,
                  runSpacing: AriaSpace.s2,
                  children: [
                    if (isSaved)
                      OutlinedButton.icon(
                        icon: const Icon(PhosphorIconsRegular.check, size: 16),
                        label: const Text('In Listen Later'),
                        onPressed: () => removeFromListenLater(
                          context,
                          ref,
                          id: album.id,
                          title: album.title,
                        ),
                      )
                    else
                      FilledButton.icon(
                        icon: const Icon(PhosphorIconsRegular.listPlus, size: 16),
                        label: const Text('Listen later'),
                        onPressed: () => addToListenLater(
                          context,
                          ref,
                          artist: album.artist,
                          title: album.title,
                          deezerId: album.deezerId,
                        ),
                      ),
                    if (album.link != null && album.link!.isNotEmpty)
                      OutlinedButton.icon(
                        icon: const Icon(PhosphorIconsRegular.globe, size: 16),
                        label: const Text('Deezer'),
                        onPressed: () => openExternal(album.link!),
                      ),
                  ],
                ),
              ],
            );
            return wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      art,
                      const SizedBox(width: AriaSpace.s5),
                      Expanded(child: text),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [art, const SizedBox(height: AriaSpace.s4), text],
                  );
          },
        ),
        const SizedBox(height: AriaSpace.s6),
        if (album.tracks.isEmpty)
          Text('No track listing available.', style: TextStyle(color: c.fgDim))
        else ...[
          Text('Tracks', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AriaSpace.s3),
          for (final t in album.tracks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AriaSpace.s2),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      t.number == 0 ? '' : '${t.number}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: c.fgDim),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (t.duration > 0)
                    Text(
                      formatDuration(t.duration),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: c.fgDim),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// Cover via the server's caching proxy, falling back to the raw Deezer CDN
/// URL — the same chain avatars use, so an evicted or expired cache entry
/// degrades to a slower load instead of a blank square.
class _Cover extends ConsumerWidget {
  const _Cover({required this.album, required this.ref_, required this.size});

  final ExtAlbum album;
  final ReleaseRef ref_;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.bgRaised,
        borderRadius: BorderRadius.circular(AriaRadius.md),
        border: Border.all(color: c.lineStrong),
      ),
      child: Icon(PhosphorIconsRegular.vinylRecord, color: c.fgDim, size: 40),
    );
    if (album.cover == null || album.cover!.isEmpty) return placeholder;
    final proxy = ref.watch(apiClientProvider).extAlbumImgUrl(album.cover!);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AriaRadius.md),
      child: Image.network(
        proxy,
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => Image.network(
          album.cover!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => placeholder,
        ),
      ),
    );
  }
}
