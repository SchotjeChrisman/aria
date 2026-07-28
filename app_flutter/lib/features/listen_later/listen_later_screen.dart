import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/phosphor_icons.dart';
import '../../core/theme.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/unowned_album_card.dart';
import 'providers.dart';

/// The full Listen Later list. Everything here is by definition not in the
/// library — the server drops entries as albums arrive, so there is no
/// "owned" state to render.
class ListenLaterScreen extends ConsumerWidget {
  const ListenLaterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(listenLaterProvider);
    return Scaffold(
      body: ListView(
        padding: ariaPagePadding(context),
        children: [
          Text('Listen Later', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AriaSpace.s4),
          switch (async) {
            AsyncLoading() => const Padding(
              padding: EdgeInsets.only(top: AriaSpace.s6),
              child: Center(child: CircularProgressIndicator()),
            ),
            AsyncError() => EmptyState(
              message: 'Cannot reach the server — check Settings.',
              icon: PhosphorIconsRegular.cloudSlash,
              action: OutlinedButton(
                onPressed: () => ref.invalidate(listenLaterProvider),
                child: const Text('Retry'),
              ),
            ),
            AsyncData(:final value) when value.isEmpty => const EmptyState(
              message:
                  'Nothing saved yet — right-click an album you don\'t own, '
                  'on the New Releases shelf or an artist\'s discography, and '
                  'pick "Listen later".',
              icon: PhosphorIconsRegular.listPlus,
            ),
            AsyncData(:final value) => GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: AriaBreakpoint.of(context).gridColumns,
                crossAxisSpacing: AriaSpace.s5,
                mainAxisSpacing: AriaSpace.s5,
                childAspectRatio: 0.72,
              ),
              itemCount: value.length,
              itemBuilder: (context, i) {
                final e = value[i];
                final year =
                    (e.date != null && e.date!.length >= 4) ? e.date!.substring(0, 4) : null;
                return UnownedAlbumCard(
                  artist: e.artist,
                  title: e.title,
                  subtitle: [
                    e.artist,
                    ?year,
                    if (e.type != 'album') e.type,
                  ].join(' · '),
                  cover: e.cover,
                  deezerId: e.deezerId,
                  menuItems: (ctx) => [
                    AriaMenuItem(
                      'Remove',
                      () => removeFromListenLater(
                        ctx,
                        ref,
                        id: e.id,
                        title: e.title,
                      ),
                      icon: PhosphorIconsRegular.trash,
                      destructive: true,
                    ),
                  ],
                );
              },
            ),
          },
        ],
      ),
    );
  }
}
