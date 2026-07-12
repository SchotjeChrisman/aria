import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/phosphor_icons.dart';

import '../core/connection.dart';
import '../core/theme.dart';
import 'shelf.dart';

/// Cache-only on the server: cold cache yields [] (shelf renders nothing).
final newReleasesProvider = FutureProvider<List<NewRelease>>(
  (ref) => ref.watch(apiClientProvider).newReleases(),
);

// Legacy RT_LABEL.
const _typeLabel = {
  'album': 'Album',
  'ep': 'EP',
  'single': 'Single',
  'compilation': 'Compilation',
  'live': 'Live',
};

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Legacy Home "New Releases" shelf: recent drops by library artists that
/// are NOT in the library (max 20 shown). Renders nothing when the server
/// has no data — the legacy shelf removed itself.
class NewReleasesShelf extends ConsumerWidget {
  const NewReleasesShelf({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(newReleasesProvider).value ?? const [];
    if (items.isEmpty) return const SizedBox.shrink();

    return Shelf(
      title: 'New Releases',
      height: 236,
      itemCount: items.length > 20 ? 20 : items.length,
      itemBuilder: (context, i) => _NewReleaseCard(item: items[i]),
    );
  }
}

class _NewReleaseCard extends StatelessWidget {
  const _NewReleaseCard({required this.item});

  final NewRelease item;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);

    // Legacy nrCard: "Mon yyyy" from the release date.
    String mon = '';
    final d = DateTime.tryParse(item.date);
    if (d != null) mon = '${_months[d.month - 1]} ${d.year}';
    final ty = item.type.toLowerCase();

    final sub = [
      item.artist,
      if (mon.isNotEmpty) mon,
      if (ty != 'album') _typeLabel[ty] ?? ty,
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: Container(
            decoration: BoxDecoration(
              color: c.bgRaised,
              borderRadius: BorderRadius.circular(AriaRadius.md),
              border: Border.all(color: c.lineStrong),
            ),
            clipBehavior: Clip.antiAlias,
            child: item.cover == null
                ? Center(child: Icon(PhosphorIconsRegular.vinylRecord, color: c.fgDim))
                : LayoutBuilder(
                    // Band-sized cards have no fixed extent (wide windows go
                    // well past 190 logical px) — decode at the laid-out
                    // size instead of the full remote cover.
                    builder: (context, box) => Image.network(
                      item.cover!,
                      fit: BoxFit.cover,
                      cacheWidth: (box.maxWidth *
                              MediaQuery.devicePixelRatioOf(context))
                          .round(),
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => Center(
                        child: Icon(PhosphorIconsRegular.vinylRecord, color: c.fgDim),
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        Text(
          sub,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Text('Not in library', style: TextStyle(fontSize: 11, color: c.fgDim)),
      ],
    );
  }
}
