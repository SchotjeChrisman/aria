import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/library_cards.dart';
import 'album_filters.dart';
import 'library_providers.dart';
import 'library_sort.dart';

/// Latest addedAt across an album's tracks, in epoch ms (legacy addedAt()).
int _addedMs(Album a) {
  var mx = 0;
  for (final t in a.tracks) {
    final at = t.addedAt;
    if (at == null) continue;
    final ms = DateTime.tryParse(at)?.millisecondsSinceEpoch ?? 0;
    if (ms > mx) mx = ms;
  }
  return mx;
}

/// Filtered + sorted album list (legacy renderAlbums SORTS table).
final visibleAlbumsProvider = Provider<List<Album>>((ref) {
  final f = ref.watch(albumFiltersProvider);
  final parents = ref.watch(genreParentsProvider);
  final tagIndex = ref.watch(tagNameIndexProvider);
  final key = ref.watch(albumSortProvider);

  final list = [
    for (final a in ref.watch(albumsProvider))
      if (albumPassesFilters(a, f, parents: parents, tagIndex: tagIndex)) a,
  ];

  // Lowercased sort keys, computed once per album instead of per comparison.
  final artistKey = {for (final a in list) a.id: a.albumArtist.toLowerCase()};
  int byArtist(Album x, Album y) {
    final d = artistKey[x.id]!.compareTo(artistKey[y.id]!);
    return d != 0 ? d : (x.year ?? 0) - (y.year ?? 0);
  }

  switch (key) {
    case 'title':
      final titleKey = {for (final a in list) a.id: a.title.toLowerCase()};
      list.sort((x, y) => titleKey[x.id]!.compareTo(titleKey[y.id]!));
    case 'yearNew':
      list.sort((x, y) => (y.year ?? 0) - (x.year ?? 0));
    case 'yearOld':
      list.sort((x, y) => (x.year ?? 9999) - (y.year ?? 9999));
    case 'added':
      final added = {for (final a in list) a.id: _addedMs(a)};
      list.sort((x, y) => added[y.id]!.compareTo(added[x.id]!));
    case 'plays':
      // Lazy: counts are only fetched when this sort is active.
      final counts =
          ref.watch(playCountsProvider).value ?? const <String, int>{};
      final plays = {
        for (final a in list)
          a.id: a.tracks.fold(0, (s, t) => s + (counts[t.id] ?? 0)),
      };
      list.sort((x, y) {
        final d = plays[y.id]! - plays[x.id]!;
        return d != 0 ? d : artistKey[x.id]!.compareTo(artistKey[y.id]!);
      });
    default:
      list.sort(byArtist);
  }
  return list;
});

class AlbumsSection extends ConsumerWidget {
  const AlbumsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(albumFiltersProvider);
    final sortKey = ref.watch(albumSortProvider);
    final list = ref.watch(visibleAlbumsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: ariaPagePadding(
            context,
            top: AriaSpace.s4,
            bottom: AriaSpace.s4,
          ),
          child: Row(
            children: [
              Expanded(
                child: FilterBar(
                  children: [
                    FilterPill(
                      label: 'Genre',
                      selected: filters.genres.isNotEmpty,
                      count: filters.genres.length,
                      onTap: () => _showMultiPicker(
                        context,
                        title: 'Genre',
                        options: genreOptionsProvider,
                        selectedOf: (f) => f.genres,
                        onToggle: (ref, v) => ref
                            .read(albumFiltersProvider.notifier)
                            .toggleGenre(v),
                      ),
                    ),
                    FilterPill(
                      label: filters.decade == null
                          ? 'Decade'
                          : '${filters.decade}s',
                      selected: filters.decade != null,
                      onTap: () => _showDecadePicker(context),
                    ),
                    FilterPill(
                      label: 'Format',
                      selected: filters.formats.isNotEmpty,
                      count: filters.formats.length,
                      onTap: () => _showMultiPicker(
                        context,
                        title: 'Format',
                        options: formatOptionsProvider,
                        selectedOf: (f) => f.formats,
                        onToggle: (ref, v) => ref
                            .read(albumFiltersProvider.notifier)
                            .toggleFormat(v),
                      ),
                    ),
                    FilterPill(
                      label: 'Tag',
                      selected: filters.tags.isNotEmpty,
                      count: filters.tags.length,
                      onTap: () => _showMultiPicker(
                        context,
                        title: 'Tag',
                        options: tagOptionsProvider,
                        selectedOf: (f) => f.tags,
                        onToggle: (ref, v) => ref
                            .read(albumFiltersProvider.notifier)
                            .toggleTag(v),
                      ),
                    ),
                    FilterPill(
                      label: filters.combine == 'any'
                          ? 'Match: Any'
                          : 'Match: All',
                      selected: filters.combine == 'any',
                      onTap: () => ref
                          .read(albumFiltersProvider.notifier)
                          .toggleCombine(),
                    ),
                    if (!filters.isEmpty)
                      FilterPill(
                        label: 'Clear',
                        onTap: () =>
                            ref.read(albumFiltersProvider.notifier).clear(),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AriaSpace.s3),
              SortDropdown(
                options: albumSortOptions,
                value: sortKey,
                onChanged: (k) => ref.read(albumSortProvider.notifier).set(k),
              ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const EmptyState(
                  message: 'No albums.',
                  icon: Icons.album_outlined,
                )
              : GridView.builder(
                  padding: ariaPagePadding(context, top: 0),
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
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final a = list[i];
                    final type = a.releaseType;
                    final sub = [
                      a.albumArtist,
                      if (a.year != null) '${a.year}',
                      if (type != null && type != 'Album') type,
                    ].join(' · ');
                    return AlbumGridCard(
                      albumId: a.id,
                      title: a.title,
                      artistName: a.albumArtist,
                      tracks: a.tracks,
                      hasArt: a.hasArt,
                      subtitle: sub,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

void _showMultiPicker(
  BuildContext context, {
  required String title,
  required Provider<List<String>> options,
  required Set<String> Function(AlbumFilters) selectedOf,
  required void Function(WidgetRef, String) onToggle,
}) {
  final c = AriaColors.of(context);
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.bgRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AriaRadius.lg)),
    ),
    builder: (_) => SafeArea(
      child: SizedBox(
        height: 420,
        child: Consumer(
          builder: (context, ref, _) {
            final opts = ref.watch(options);
            final sel = selectedOf(ref.watch(albumFiltersProvider));
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AriaSpace.s5,
                    AriaSpace.s4,
                    AriaSpace.s5,
                    AriaSpace.s2,
                  ),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: opts.isEmpty
                      ? const EmptyState(message: 'Nothing to filter on.')
                      : ListView.builder(
                          itemCount: opts.length,
                          itemBuilder: (_, i) => CheckboxListTile(
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(opts[i]),
                            value: sel.contains(opts[i]),
                            onChanged: (_) => onToggle(ref, opts[i]),
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

void _showDecadePicker(BuildContext context) {
  final c = AriaColors.of(context);
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.bgRaised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AriaRadius.lg)),
    ),
    builder: (_) => SafeArea(
      child: SizedBox(
        height: 420,
        child: Consumer(
          builder: (context, ref, _) {
            final decades = ref.watch(decadeOptionsProvider);
            final current = ref.watch(
              albumFiltersProvider.select((f) => f.decade),
            );
            void pick(int? d) {
              ref.read(albumFiltersProvider.notifier).setDecade(d);
              Navigator.of(context).pop();
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AriaSpace.s5,
                    AriaSpace.s4,
                    AriaSpace.s5,
                    AriaSpace.s2,
                  ),
                  child: Text(
                    'Decade',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      ListTile(
                        dense: true,
                        title: const Text('Any'),
                        trailing: current == null
                            ? Icon(Icons.check, size: 18, color: c.accent)
                            : null,
                        onTap: () => pick(null),
                      ),
                      for (final d in decades)
                        ListTile(
                          dense: true,
                          title: Text('${d}s'),
                          trailing: current == d
                              ? Icon(Icons.check, size: 18, color: c.accent)
                              : null,
                          onTap: () => pick(current == d ? null : d),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
