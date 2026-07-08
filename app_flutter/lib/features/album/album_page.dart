import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/formats.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/art_image.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/library_cards.dart';
import '../../widgets/selection_highlight.dart';
import '../../widgets/shelf.dart';
import '../../widgets/tag_picker.dart';
import '../../widgets/track_actions.dart';
import '../../widgets/track_row.dart';
import 'edit_metadata_dialog.dart';
import 'external_link.dart';
import 'person_card.dart';
import 'providers.dart';
import 'reidentify_dialog.dart';

/// Path contract with the artist feature (features never import each other).
String _artistPath(String name) => artistPath(name);

/// Album detail page, ported from legacy renderAlbum().
class AlbumPage extends ConsumerWidget {
  const AlbumPage({super.key, required this.albumId});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: ref
            .watch(albumsByIdProvider)
            .when(
              // Metadata edits invalidate the library cache underneath this
              // derived provider (a "reload", not a "refresh") — keep showing
              // the previous album instead of flashing a spinner.
              skipLoadingOnReload: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => const EmptyState(
                message: 'Could not load the library.',
                icon: Icons.cloud_off,
              ),
              data: (byId) {
                final album = byId[albumId];
                if (album == null) {
                  return const EmptyState(
                    message: 'Album not found.',
                    icon: Icons.album_outlined,
                  );
                }
                return _AlbumBody(album: album);
              },
            ),
      ),
    );
  }
}

class _AlbumBody extends ConsumerWidget {
  const _AlbumBody({required this.album});

  final Album album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(albumApiProvider);
    final currentId = ref.watch(currentTrackProvider)?.id;
    final queue = ref.read(queueProvider.notifier);

    return ListView(
      padding: const EdgeInsets.all(AriaSpace.s6),
      children: [
        _header(context, ref, api, queue),
        const SizedBox(height: AriaSpace.s4),
        _infoBox(context, ref),
        const SizedBox(height: AriaSpace.s4),
        ..._trackRows(context, ref, currentId, queue),
        ..._creditsLine(context),
        ..._performerShelf(context),
        ..._relatedShelf(context, ref),
      ],
    );
  }

  // ------------------------------------------------------------- header

  Widget _header(
    BuildContext context,
    WidgetRef ref,
    AriaClient api,
    QueueNotifier queue,
  ) {
    final c = AriaColors.of(context);
    final ty = album.releaseType;
    final dim = TextStyle(color: c.fgDim);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ArtImage(
          url: api.artUrl(album.id),
          fallbackText: album.title,
          size: 180,
          borderRadius: AriaRadius.lg,
        ),
        const SizedBox(width: AriaSpace.s6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                album.title,
                style: Theme.of(context).textTheme.titleLarge,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AriaSpace.s2),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _PersonLink(name: album.albumArtist),
                  if (album.year != null) Text(' · ${album.year}', style: dim),
                  if (ty != null && ty != 'Album') ...[
                    Text(' · ', style: dim),
                    _RtBadge(type: ty),
                  ],
                  Text(
                    ' · ${album.tracks.length} tracks'
                    ' · ${formatDuration(album.duration)}',
                    style: dim,
                  ),
                ],
              ),
              const SizedBox(height: AriaSpace.s5),
              // Wrap, not Row: next to 180px art on a 390px phone the
              // remaining column is too narrow for three buttons in a line.
              Wrap(
                spacing: AriaSpace.s3,
                runSpacing: AriaSpace.s2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () => queue.playQueue(album.tracks, 0),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Play album'),
                  ),
                  Builder(
                    builder: (bctx) => OutlinedButton.icon(
                      onPressed: () => _editMenu(bctx, context, ref),
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Edit'),
                    ),
                  ),
                  // Only when the album folder has PDFs; nothing while
                  // loading / on error (house style).
                  if (ref.watch(bookletsProvider(album.id)).value
                      case final booklets? when booklets.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () => _openBooklet(context, booklets),
                      icon: const Icon(Icons.menu_book_outlined, size: 16),
                      label: const Text('Booklet'),
                    ),
                  // Legacy albumCtx verbs: Play next / Add to queue /
                  // Add to playlist / Tags / Select.
                  Builder(
                    builder: (bctx) => IconButton(
                      tooltip: 'More',
                      icon: const Icon(Icons.more_horiz),
                      onPressed: () => showAriaContextMenu(
                        bctx,
                        _menuAnchor(bctx),
                        albumMenuItems(
                          context,
                          ref,
                          albumId: album.id,
                          tracks: album.tracks,
                          artistName: album.albumArtist,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  static Offset _menuAnchor(BuildContext buttonCtx) {
    final box = buttonCtx.findRenderObject() as RenderBox?;
    return box == null
        ? Offset.zero
        : box.localToGlobal(Offset(0, box.size.height));
  }

  // Legacy editMenu: the single deliberate entry point for anything that
  // rewrites data — two clicks minimum.
  void _editMenu(BuildContext buttonCtx, BuildContext pageCtx, WidgetRef ref) {
    showAriaContextMenu(buttonCtx, _menuAnchor(buttonCtx), [
      AriaMenuItem(
        'Edit metadata…',
        () => showAlbumEditor(pageCtx, ref, album),
        icon: Icons.edit_outlined,
      ),
      AriaMenuItem(
        'Tags…',
        () => showTagPicker(pageCtx, kind: 'album', key: album.id),
        icon: Icons.sell_outlined,
      ),
      AriaMenuItem(
        'Re-identify…',
        () => showAlbumReidentify(pageCtx, ref, album),
        icon: Icons.sync,
      ),
    ]);
  }

  /// One booklet opens straight away; several offer a sheet of names first.
  void _openBooklet(BuildContext context, List<String> booklets) {
    void view(String name) => context.push(
      '/album/${Uri.encodeComponent(album.id)}'
      '/booklet/${Uri.encodeComponent(name)}',
    );
    if (booklets.length == 1) {
      view(booklets.first);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final name in booklets)
              ListTile(
                leading: const Icon(Icons.menu_book_outlined),
                title: Text(name),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  view(name);
                },
              ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------- deep album data
  // Label/date (MusicBrainz) + blurb (Wikipedia), fetched on entry and cached
  // server-side; the box simply stays empty until data lands (legacy).

  Widget _infoBox(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    return ref
        .watch(albumInfoProvider(album.id))
        .when(
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
          data: (d) {
            if (d == null) return const SizedBox.shrink();
            final facts = [
              d.label,
              d.date,
              d.country,
            ].whereType<String>().join(' · ');
            if (facts.isEmpty && d.blurb == null && d.url == null) {
              return const SizedBox.shrink();
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (facts.isNotEmpty)
                  Text(facts, style: Theme.of(context).textTheme.bodySmall),
                if (d.blurb != null) ...[
                  const SizedBox(height: AriaSpace.s2),
                  Text(d.blurb!),
                ],
                if (d.url != null) ...[
                  const SizedBox(height: AriaSpace.s2),
                  InkWell(
                    onTap: () => openExternal(d.url!),
                    child: Text(
                      'Wikipedia →',
                      style: TextStyle(
                        color: c.fg,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        );
  }

  // ---------------------------------------------------------- track list
  // Classical grouping (legacy): when any track carries work+movement, rows
  // group under work headers and show the movement instead of the title.

  List<Widget> _trackRows(
    BuildContext context,
    WidgetRef ref,
    String? currentId,
    QueueNotifier queue,
  ) {
    final grouped = album.tracks.any(
      (t) => (t.work ?? '').isNotEmpty && (t.movement ?? '').isNotEmpty,
    );
    final composerVaries =
        album.tracks
            .map((t) => t.composer)
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .toSet()
            .length >
        1;

    final rows = <Widget>[];
    String? curWork;
    for (var i = 0; i < album.tracks.length; i++) {
      final t = album.tracks[i];
      if (grouped && (t.work ?? '').isNotEmpty && t.work != curWork) {
        curWork = t.work;
        rows.add(
          _WorkHeader(
            work: t.work!,
            composer: composerVaries ? t.composer : null,
          ),
        );
      }
      final inWork =
          grouped && (t.work ?? '').isNotEmpty && (t.movement ?? '').isNotEmpty;
      rows.add(
        SelectionHighlight(
          kind: 'track',
          itemKey: t.id,
          child: Padding(
            padding: EdgeInsets.only(left: inWork ? AriaSpace.s4 : 0),
            child: TrackRow(
              number: t.trackNo ?? i + 1,
              title: (inWork ? t.movement : t.title) ?? '',
              duration: t.duration,
              format: t.format,
              bitsPerSample: t.bitsPerSample,
              sampleRate: t.sampleRate,
              lossless: t.lossless,
              isCurrent: t.id == currentId,
              onTap: () {
                if (selectionTapHandled(ref, trackSelectionItem(t))) return;
                queue.playQueue(album.tracks, i);
              },
              onSecondary: (pos) => _trackMenu(context, ref, pos, t),
            ),
          ),
        ),
      );
    }
    return rows;
  }

  // Legacy trackCtx (shared vocabulary) + this page's 'Edit track…'.
  void _trackMenu(BuildContext context, WidgetRef ref, Offset pos, Track t) {
    showAriaContextMenu(
      context,
      pos,
      trackMenuItems(
        context,
        ref,
        t,
        goToAlbum: false, // already here
        extra: [
          AriaMenuItem(
            'Edit track…',
            () => showTrackEditor(context, ref, t),
            icon: Icons.edit_outlined,
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- credits

  List<Widget> _creditsLine(BuildContext context) {
    final c = AriaColors.of(context);
    // (label, name) pairs, unique, first-seen order — legacy credits line.
    final cred = <(String, String)>{};
    for (final t in album.tracks) {
      if ((t.composer ?? '').isNotEmpty) cred.add(('Composed by', t.composer!));
      if ((t.conductor ?? '').isNotEmpty) {
        cred.add(('Conducted by', t.conductor!));
      }
      if ((t.orchestra ?? '').isNotEmpty) cred.add(('', t.orchestra!));
    }
    if (cred.isEmpty) return const [];
    return [
      const SizedBox(height: AriaSpace.s5),
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (i, entry) in cred.indexed) ...[
            if (i > 0) Text(' · ', style: TextStyle(color: c.fgDim)),
            if (entry.$1.isNotEmpty)
              Text('${entry.$1} ', style: TextStyle(color: c.fgDim)),
            _PersonLink(name: entry.$2),
          ],
        ],
      ),
    ];
  }

  List<Widget> _performerShelf(BuildContext context) {
    // Per-performer credits (MusicBrainz recording relationships),
    // aggregated across the album — name -> roles.
    final roles = <String, Set<String>>{};
    for (final t in album.tracks) {
      for (final p in t.performers) {
        (roles[p.name] ??= <String>{}).add(p.role ?? '');
      }
    }
    if (roles.isEmpty) return const [];
    return [const SizedBox(height: AriaSpace.s6), _CreditsShelf(roles: roles)];
  }

  List<Widget> _relatedShelf(BuildContext context, WidgetRef ref) {
    // Same-genre albums by other artists; nothing while loading (house style).
    final related =
        ref.watch(relatedAlbumsProvider(album.id)).value ?? const <Album>[];
    if (related.isEmpty) return const [];
    return [
      const SizedBox(height: AriaSpace.s6),
      Shelf(
        title: 'Related Albums',
        height: 236,
        itemCount: related.length,
        itemBuilder: (context, i) {
          final a = related[i];
          return AlbumGridCard(
            albumId: a.id,
            title: a.title,
            artistName: a.albumArtist,
            tracks: a.tracks,
            hasArt: a.hasArt,
          );
        },
      ),
    ];
  }
}

// --------------------------------------------------------------- fragments

/// Inline person link (legacy plink): tap → artist page.
class _PersonLink extends StatelessWidget {
  const _PersonLink({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return InkWell(
      onTap: () => context.push(_artistPath(name)),
      child: Text(name, style: TextStyle(color: c.fg)),
    );
  }
}

/// Small release-type pill (legacy .rt-badge), only for non-Album types.
class _RtBadge extends StatelessWidget {
  const _RtBadge({required this.type});

  final String type;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: c.lineStrong),
        borderRadius: BorderRadius.circular(AriaRadius.pill),
      ),
      child: Text(
        type.toUpperCase(),
        style: TextStyle(fontSize: 10.5, letterSpacing: 0.8, color: c.fgDim),
      ),
    );
  }
}

class _WorkHeader extends StatelessWidget {
  const _WorkHeader({required this.work, this.composer});

  final String work;
  final String? composer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AriaSpace.s3,
        AriaSpace.s4,
        AriaSpace.s3,
        AriaSpace.s1,
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AriaSpace.s2,
        children: [
          Text(work, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (composer != null && composer!.isNotEmpty)
            InkWell(
              onTap: () => context.push(_artistPath(composer!)),
              child: Text(
                composer!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

/// Credits shelf; asks the server to research faces still missing
/// (legacy warmVisible) and refreshes the people map once.
class _CreditsShelf extends ConsumerStatefulWidget {
  const _CreditsShelf({required this.roles});

  final Map<String, Set<String>> roles;

  @override
  ConsumerState<_CreditsShelf> createState() => _CreditsShelfState();
}

class _CreditsShelfState extends ConsumerState<_CreditsShelf> {
  @override
  void initState() {
    super.initState();
    Future.microtask(_warm);
  }

  Future<void> _warm() async {
    try {
      final people = await ref.read(albumPeopleProvider.future);
      final missing = widget.roles.keys
          .where((n) => !people.containsKey(n))
          .take(40)
          .toList();
      if (missing.isEmpty) return;
      await ref.read(albumApiProvider).warmPeople(missing);
      // Research takes a moment server-side; one delayed refresh is enough —
      // portraits are cached for the next visit either way.
      await Future<void>.delayed(const Duration(seconds: 3));
      if (mounted) ref.invalidate(albumPeopleProvider);
    } catch (_) {
      // faces are progressive enhancement — never surface an error
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(albumPeopleProvider).value ?? const {};
    final entries = widget.roles.entries.toList();
    return Shelf(
      title: 'Credits',
      height: 176,
      itemWidth: 132,
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        return CreditCard(
          name: e.key,
          subtitle: e.value.where((r) => r.isNotEmpty).join(', '),
          imageUrl: people[e.key],
          onTap: () => context.push(_artistPath(e.key)),
        );
      },
    );
  }
}
