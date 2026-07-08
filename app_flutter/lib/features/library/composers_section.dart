import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/theme.dart';
import '../../widgets/empty_state.dart';
import 'library_providers.dart';
import 'library_sort.dart';
import 'person_card.dart';

/// Composers browse (legacy renderComposers): classical-shaped tracks only,
/// sorted by name / most works / most albums / most played.
class ComposersSection extends ConsumerStatefulWidget {
  const ComposersSection({super.key});

  @override
  ConsumerState<ComposersSection> createState() => _ComposersSectionState();
}

class _ComposersSectionState extends ConsumerState<ComposersSection> {
  bool _warmed = false;

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
    final key = ref.watch(composerSortProvider);
    final peopleAsync = ref.watch(peopleProvider);
    final people = peopleAsync.value ?? const <String, String>{};

    final list = [...ref.watch(composersProvider)];
    int cmpStr(String a, String b) =>
        a.toLowerCase().compareTo(b.toLowerCase());
    switch (key) {
      case 'works':
        list.sort((x, y) {
          final d = y.works.length - x.works.length;
          return d != 0 ? d : cmpStr(x.name, y.name);
        });
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
          final n = t.composer;
          if (n == null || n.isEmpty) continue;
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
      _warmMissingFaces([for (final c in list) c.name], people);
    }

    if (list.isEmpty) {
      return const EmptyState(
        message: 'No composer tags in this library.',
        icon: Icons.piano_outlined,
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
                options: composerSortOptions,
                value: key,
                onChanged: (k) =>
                    ref.read(composerSortProvider.notifier).set(k),
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
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: AriaBreakpoint.of(context).gridColumns,
              mainAxisSpacing: AriaSpace.s5,
              crossAxisSpacing: AriaSpace.s5,
              // Tablet-floor tiles (~103px at a 600px window) need a taller
              // cell: the ~49px text block under the square art doesn't
              // shrink with the tile.
              childAspectRatio:
                  AriaBreakpoint.of(context) == AriaBreakpoint.tablet
                  ? 0.67
                  : 0.72,
            ),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final co = list[i];
              final works = co.works.length;
              final sub = works > 0
                  ? '${countLabel(works, 'work')} · ${countLabel(co.albumIds.length, 'album')}'
                  : countLabel(co.albumIds.length, 'album');
              return PersonCard(
                name: co.name,
                subtitle: sub,
                imageUrl: people[co.name],
                onTap: () =>
                    context.push('/composer/${Uri.encodeComponent(co.name)}'),
              );
            },
          ),
        ),
      ],
    );
  }
}
