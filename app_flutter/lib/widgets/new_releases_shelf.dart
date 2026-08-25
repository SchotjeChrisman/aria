import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/connection.dart';
import '../features/listen_later/providers.dart';
import 'shelf.dart';
import 'unowned_album_card.dart';

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
      itemBuilder: (context, i) => NewReleaseCard(item: items[i]),
    );
  }
}

class NewReleaseCard extends ConsumerWidget {
  const NewReleaseCard({super.key, required this.item});

  final NewRelease item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Legacy nrCard: "Mon yyyy" from the release date.
    String mon = '';
    final d = DateTime.tryParse(item.date);
    if (d != null) mon = '${_months[d.month - 1]} ${d.year}';
    final ty = item.type.toLowerCase();

    final sub = [
      item.artist,
      if (mon.isNotEmpty) mon,
      if (ty != 'album') _typeLabel[ty] ?? ty,
      'Not in library',
    ].join(' · ');

    return UnownedAlbumCard(
      artist: item.artist,
      title: item.title,
      subtitle: sub,
      cover: item.cover,
      deezerId: item.deezerId,
      menuItems: (ctx) => [
        listenLaterMenuItem(
          ctx,
          ref,
          artist: item.artist,
          title: item.title,
          deezerId: item.deezerId,
        ),
      ],
    );
  }
}
