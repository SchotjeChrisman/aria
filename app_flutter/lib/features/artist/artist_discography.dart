import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../widgets/album_card.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/track_actions.dart' as actions;
import 'artist_util.dart';
import 'providers.dart';

/// Discography tab (legacy renderArtistDisco, R1): one combined discography —
/// library albums + remote (Deezer) releases, year desc, deduped by
/// edition-tolerant title (library copy wins); non-owned items get a
/// "Not in library" badge. One grid per release type, fixed order.
class ArtistDiscography extends ConsumerWidget {
  const ArtistDiscography({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    return ref
        .watch(artistInfoProvider(name))
        .when(
          loading: () => Text('Researching…', style: TextStyle(color: c.fgDim)),
          error: (_, _) => Text(
            'Discography unavailable.',
            style: TextStyle(color: c.fgDim),
          ),
          data: (d) => _body(context, ref, d),
        );
  }

  Widget _body(BuildContext context, WidgetRef ref, ArtistInfo? d) {
    final albums = ref.watch(artistAlbumsProvider).value ?? const <Album>[];
    final api = ref.watch(artistApiProvider);

    final lib = [
      for (final a in albums)
        if (a.albumArtist == name) a,
    ];
    // owned titles block remote ghosts
    final seen = <String>{for (final a in lib) normTitle(a.title)};

    final items = <_DiscoItem>[
      for (final a in lib)
        _DiscoItem(
          album: a,
          year: a.year,
          type: (a.releaseType ?? 'Album').toLowerCase(),
        ),
    ];
    for (final x in d?.discography ?? const <DiscographyItem>[]) {
      final k = normTitle(x.title);
      if (seen.contains(k)) continue; // library copy wins
      seen.add(k);
      items.add(
        _DiscoItem(
          remote: x,
          year: x.date != null && x.date!.length >= 4
              ? int.tryParse(x.date!.substring(0, 4))
              : null,
          type: (x.type ?? 'album').toLowerCase(),
        ),
      );
    }
    if (items.isEmpty) {
      return const EmptyState(
        message: 'No releases found.',
        icon: Icons.album_outlined,
      );
    }
    items.sort((p, q) => (q.year ?? 0) - (p.year ?? 0));

    final groups = <String, List<_DiscoItem>>{};
    for (final it in items) {
      // unknown remote types land with albums (legacy)
      final ty = knownDiscTypes.contains(it.type) ? it.type : 'album';
      (groups[ty] ??= []).add(it);
    }

    final cn = AriaColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (ty, heading) in discTypes)
          if (groups.containsKey(ty)) ...[
            Padding(
              padding: const EdgeInsets.only(
                top: AriaSpace.s2,
                bottom: AriaSpace.s3,
              ),
              child: Text.rich(
                TextSpan(
                  text: heading,
                  style: Theme.of(context).textTheme.titleMedium,
                  children: [
                    TextSpan(
                      text: '  ${groups[ty]!.length}',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w400,
                        color: cn.fgDim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: AriaBreakpoint.of(context).gridColumns,
                mainAxisSpacing: AriaSpace.s5,
                crossAxisSpacing: AriaSpace.s5,
                // Tablet-floor tiles (~103px at a 600px window) need a
                // taller cell: the ~49px text block under the square art
                // doesn't shrink with the tile.
                childAspectRatio:
                    AriaBreakpoint.of(context) == AriaBreakpoint.tablet
                    ? 0.67
                    : 0.72,
              ),
              itemCount: groups[ty]!.length,
              itemBuilder: (context, i) {
                final it = groups[ty]![i];
                final a = it.album;
                if (a != null) {
                  return Consumer(
                    builder: (context, ref, _) => AlbumCard(
                      title: a.title,
                      subtitle: a.year?.toString() ?? '',
                      artUrl: api.artUrl(a.id, version: a.artVersion),
                      onTap: () => context.push(albumPath(a.id)),
                      onSecondary: (pos) => showAriaContextMenu(
                        context,
                        pos,
                        actions.albumMenuItems(
                          context,
                          ref,
                          albumId: a.id,
                          tracks: a.tracks,
                          artistName: a.albumArtist,
                        ),
                      ),
                    ),
                  );
                }
                final x = it.remote!;
                // ghost card: not in the library, dimmed, not clickable
                return Opacity(
                  opacity: 0.7,
                  child: AlbumCard(
                    title: x.title,
                    subtitle: [
                      if (it.year != null) '${it.year}',
                      'Not in library',
                    ].join(' · '),
                    artUrl: x.cover,
                  ),
                );
              },
            ),
            const SizedBox(height: AriaSpace.s4),
          ],
      ],
    );
  }
}

class _DiscoItem {
  const _DiscoItem({this.album, this.remote, this.year, required this.type});

  final Album? album;
  final DiscographyItem? remote;
  final int? year;
  final String type;
}
