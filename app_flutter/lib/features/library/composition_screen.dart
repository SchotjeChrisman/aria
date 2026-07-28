import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/phosphor_icons.dart';

import '../../core/formats.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/track_actions.dart';
import '../../widgets/track_row.dart';
import 'library_providers.dart';
import 'person_card.dart';

/// One composition across the whole library: every recording of a song/work
/// regardless of artist ("Let the Good Times Roll" by Ray Charles, B.B.
/// King, …), grouped by artist. Tracks match on the explicit work tag or the
/// edition-normalized title.
// ponytail: two different songs sharing a title land on one page; splitting
// them needs composer/MB-work matching most files aren't tagged for.
class CompositionScreen extends ConsumerWidget {
  const CompositionScreen({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tracksProvider);
    return Scaffold(
      body: SafeArea(
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => const EmptyState(
            message: 'Cannot reach the server.',
            icon: PhosphorIconsRegular.cloudSlash,
          ),
          data: (tracks) => _Body(name: name, tracks: tracks),
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.name, required this.tracks});

  final String name;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final albumById = ref.watch(albumByIdProvider);
    final currentId = ref.watch(currentTrackProvider.select((t) => t?.id));
    final queue = ref.read(queueProvider.notifier);

    final key = normTitle(name);
    final matched = [
      for (final t in tracks)
        if (t.work == name || normTitle(t.work) == key || normTitle(t.title) == key)
          t,
    ]..sort((x, y) {
        final a = displayArtist(x).compareTo(displayArtist(y));
        if (a != 0) return a;
        final yr = (x.year ?? 0) - (y.year ?? 0);
        if (yr != 0) return yr;
        return (x.trackNo ?? 0) - (y.trackNo ?? 0);
      });

    final backRow = Align(
      alignment: Alignment.centerLeft,
      child: IconButton(
        icon: const Icon(PhosphorIconsRegular.arrowLeft),
        tooltip: 'Back',
        onPressed: () => context.canPop()
            ? context.pop()
            : context.go('/library/tracks'),
      ),
    );

    if (matched.isEmpty) {
      return Column(
        children: [
          Padding(
            padding: ariaPagePadding(context, top: AriaSpace.s4, bottom: 0),
            child: backRow,
          ),
          const Expanded(
            child: EmptyState(
              message: 'No recordings of this composition.',
              icon: PhosphorIconsRegular.musicNotes,
            ),
          ),
        ],
      );
    }

    // Display title: the most common raw name among the matches, so arriving
    // from "… (Live)" still heads the page with the plain title.
    final counts = <String, int>{};
    for (final t in matched) {
      final n = t.work ?? t.title ?? name;
      counts[n] = (counts[n] ?? 0) + 1;
    }
    final title = counts.entries
        .reduce((a, b) => b.value > a.value ? b : a)
        .key;
    final composers = {
      for (final t in matched)
        if ((t.composer ?? '').isNotEmpty) t.composer!,
    };
    final artists = <String, List<Track>>{};
    for (final t in matched) {
      (artists[displayArtist(t)] ??= []).add(t);
    }

    return ListView(
      padding: ariaPagePadding(context, top: AriaSpace.s4),
      children: [
        backRow,
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AriaSpace.s1),
        Text(
          [
            if (composers.isNotEmpty) composers.join(', '),
            countLabel(matched.length, 'recording'),
            countLabel(artists.length, 'artist'),
          ].join(' · '),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: AriaSpace.s4),
        for (final e in artists.entries) ...[
          Padding(
            padding: const EdgeInsets.only(
              top: AriaSpace.s3,
              bottom: AriaSpace.s1,
            ),
            child: Text(
              e.key,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(color: c.fgDim),
            ),
          ),
          for (final t in e.value)
            TrackRow(
              title: t.title ?? '',
              subtitle: [
                if ((t.album ?? '').isNotEmpty) t.album!,
                if ((albumById[t.albumId]?.year ?? t.year) != null)
                  '${albumById[t.albumId]?.year ?? t.year}',
              ].join(' · '),
              duration: t.duration,
              format: t.format,
              bitsPerSample: t.bitsPerSample,
              sampleRate: t.sampleRate,
              lossless: t.lossless,
              isCurrent: t.id == currentId,
              onTap: () => queue.playQueue(matched, matched.indexOf(t)),
              onSecondary: (pos) => showAriaContextMenu(
                context,
                pos,
                trackMenuItems(context, ref, t, goToComposition: false),
              ),
            ),
        ],
      ],
    );
  }
}
