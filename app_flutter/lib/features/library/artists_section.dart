import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/theme.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/library_cards.dart';
import 'library_providers.dart';
import 'library_sort.dart';
import 'person_card.dart';

/// Artists browse (legacy renderArtists): name / most albums / most played.
class ArtistsSection extends ConsumerStatefulWidget {
  const ArtistsSection({super.key});

  @override
  ConsumerState<ArtistsSection> createState() => _ArtistsSectionState();
}

class _ArtistsSectionState extends ConsumerState<ArtistsSection> {
  bool _warmed = false;

  // One bounded warm per screen life instead of the legacy per-scroll
  // warmVisible(); photos land via peopleProvider invalidation.
  void _warmMissingFaces(List<String> names, Map<String, String> people) {
    if (_warmed) return;
    _warmed = true;
    final missing = [
      for (final n in names)
        if (!people.containsKey(n)) n,
    ];
    if (missing.isEmpty) return;
    final api = ref.read(apiClientProvider);
    Future(() async {
      try {
        final added = await api.warmPeople(missing.take(60).toList());
        if (added > 0 && mounted) ref.invalidate(peopleProvider);
      } catch (_) {
        // server away — initials fallback stands
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final key = ref.watch(artistSortProvider);
    final peopleAsync = ref.watch(peopleProvider);
    final people = peopleAsync.value ?? const <String, String>{};

    final list = [...ref.watch(artistsProvider)];
    int cmpStr(String a, String b) =>
        a.toLowerCase().compareTo(b.toLowerCase());
    switch (key) {
      case 'albums':
        list.sort((x, y) {
          final d = y.albumIds.length - x.albumIds.length;
          return d != 0 ? d : cmpStr(x.name, y.name);
        });
      case 'plays':
        final counts =
            ref.watch(playCountsProvider).value ?? const <String, int>{};
        final byName = <String, int>{};
        for (final t in ref.watch(loadedTracksProvider)) {
          final n = displayArtist(t);
          byName[n] = (byName[n] ?? 0) + (counts[t.id] ?? 0);
        }
        list.sort((x, y) {
          final d = (byName[y.name] ?? 0) - (byName[x.name] ?? 0);
          return d != 0 ? d : cmpStr(x.name, y.name);
        });
      default:
        list.sort((x, y) => cmpStr(x.name, y.name));
    }

    if (peopleAsync.hasValue) {
      _warmMissingFaces([for (final a in list) a.name], people);
    }

    if (list.isEmpty) {
      return const EmptyState(
        message: 'No artists.',
        icon: Icons.person_outline,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AriaSpace.s6,
            AriaSpace.s4,
            AriaSpace.s6,
            AriaSpace.s4,
          ),
          child: Row(
            children: [
              const Spacer(),
              SortDropdown(
                options: artistSortOptions,
                value: key,
                onChanged: (k) => ref.read(artistSortProvider.notifier).set(k),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(
              AriaSpace.s6,
              0,
              AriaSpace.s6,
              AriaSpace.s6,
            ),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 170,
              mainAxisSpacing: AriaSpace.s5,
              crossAxisSpacing: AriaSpace.s5,
              childAspectRatio: 0.72,
            ),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final a = list[i];
              // Legacy artistCtx gather: everything credited to the name.
              List<Track> artistTracks() => [
                for (final t in ref.read(loadedTracksProvider))
                  if (t.artist == a.name || t.albumArtist == a.name) t,
              ];
              return ArtistTile(
                name: a.name,
                tracksOf: artistTracks,
                child: PersonCard(
                  name: a.name,
                  subtitle: countLabel(a.albumIds.length, 'album'),
                  imageUrl: people[a.name],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
