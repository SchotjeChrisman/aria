import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/phosphor_icons.dart';

import '../../core/formats.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/album_card.dart';
import '../../widgets/art_image.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/format_badge.dart';
import '../../widgets/shelf.dart';
import 'artist_util.dart';
import 'external_link.dart';
import 'providers.dart';

/// Composer page (legacy renderComposer): compositions first — a composer
/// page is about WORKS, not releases. Hero from Open Opus + Wikipedia,
/// expandable work rows with one recording per album, releases demoted to a
/// shelf at the bottom.
class ComposerPage extends ConsumerStatefulWidget {
  const ComposerPage({super.key, required this.name});

  final String name;

  @override
  ConsumerState<ComposerPage> createState() => _ComposerPageState();
}

class _ComposerPageState extends ConsumerState<ComposerPage> {
  final _open = <String>{};

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: ref
            .watch(artistTracksProvider)
            .when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => const EmptyState(
                message: 'Could not load the library.',
                icon: PhosphorIconsRegular.cloudSlash,
              ),
              data: (tracks) => _body(context, c, tracks),
            ),
      ),
    );
  }

  Widget _body(BuildContext context, AriaColors c, List<Track> tracks) {
    final name = widget.name;
    final albums = ref.watch(artistAlbumsProvider).value ?? const <Album>[];
    final albumsById = {for (final a in albums) a.id: a};
    final works = composerWorks(tracks, name);
    final queue = ref.read(queueProvider.notifier);
    final api = ref.watch(artistApiProvider);

    final composerAlbums =
        <String>{
            for (final t in tracks)
              if (t.composer == name) t.albumId,
          }.map((id) => albumsById[id]).whereType<Album>().toList()
          ..sort((x, y) => (y.year ?? 0) - (x.year ?? 0));

    final sortedWorks = works.entries.toList()
      ..sort((x, y) => x.key.compareTo(y.key));

    return ListView(
      padding: ariaPagePadding(context),
      children: [
        Text(name, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AriaSpace.s4),
        _ComposerHero(name: name),
        if (works.isNotEmpty) ...[
          const SizedBox(height: AriaSpace.s6),
          Text.rich(
            TextSpan(
              text: 'Works',
              style: Theme.of(context).textTheme.titleMedium,
              children: [
                TextSpan(
                  text: '  ${works.length}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w400,
                    color: c.fgDim,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AriaSpace.s2),
          for (final e in sortedWorks)
            _workRow(context, c, e.key, e.value, albumsById, queue),
        ],
        if (composerAlbums.isNotEmpty) ...[
          const SizedBox(height: AriaSpace.s6),
          Shelf(
            title: 'Albums featuring his works',
            height: 226,
            itemCount: composerAlbums.length,
            itemBuilder: (context, i) {
              final a = composerAlbums[i];
              return AlbumCard(
                title: a.title,
                subtitle: a.year?.toString() ?? '',
                artUrl: api.artUrl(a.id, version: a.artVersion),
                onTap: () => context.push(albumPath(a.id)),
              );
            },
          ),
        ],
        if (works.isEmpty && composerAlbums.isEmpty)
          const EmptyState(
            message: 'No composer tags for this name.',
            icon: PhosphorIconsRegular.pianoKeys,
          ),
      ],
    );
  }

  Widget _workRow(
    BuildContext context,
    AriaColors c,
    String work,
    Map<String, List<Track>> perAlbum,
    Map<String, Album> albumsById,
    QueueNotifier queue,
  ) {
    final recs = perAlbum.entries.toList();
    final secs = recs
        .expand((e) => e.value)
        .fold<double>(0, (s, t) => s + (t.duration ?? 0));
    final open = _open.contains(work);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () =>
              setState(() => open ? _open.remove(work) : _open.add(work)),
          borderRadius: BorderRadius.circular(AriaRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AriaSpace.s3,
              vertical: 10,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  child: Text(
                    open ? '▾' : '▸',
                    style: TextStyle(color: c.fgDim),
                  ),
                ),
                Expanded(
                  child: Text(
                    work,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  '${recs.length} recording${recs.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 14),
                Text(formatDuration(secs), style: TextStyle(color: c.fgDim)),
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(left: AriaSpace.s8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final e in recs)
                  _recordingRow(context, c, e.value, albumsById[e.key], queue),
              ],
            ),
          ),
      ],
    );
  }

  Widget _recordingRow(
    BuildContext context,
    AriaColors c,
    List<Track> ts,
    Album? album,
    QueueNotifier queue,
  ) {
    final t0 = ts.first;
    // performer line: conductor + orchestra when tagged, else the track artist
    final who = <String>{
      if ((t0.conductor ?? '').isNotEmpty) t0.conductor!,
      if ((t0.orchestra ?? '').isNotEmpty) t0.orchestra!,
    };
    if (who.isEmpty &&
        (t0.artist ?? '').isNotEmpty &&
        t0.artist != widget.name) {
      who.add(t0.artist!);
    }
    final secs = ts.fold<double>(0, (s, t) => s + (t.duration ?? 0));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(PhosphorIconsFill.play, size: 18),
            visualDensity: VisualDensity.compact,
            tooltip: 'Play this recording',
            color: c.fgDim,
            onPressed: () => queue.playQueue(ts, 0),
          ),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final (i, n) in who.indexed.toList()) ...[
                  if (i > 0) Text(' · ', style: TextStyle(color: c.fgDim)),
                  InkWell(
                    onTap: () => context.push(artistPath(n)),
                    child: Text(n),
                  ),
                ],
                if (who.isEmpty)
                  Text('Unknown performer', style: TextStyle(color: c.fgDim)),
                const SizedBox(width: AriaSpace.s2),
                if (album != null)
                  InkWell(
                    onTap: () => context.push(albumPath(album.id)),
                    child: Text(
                      album.title,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else if ((t0.album ?? '').isNotEmpty)
                  Text(
                    t0.album!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          FormatBadge(
            format: t0.format,
            bitsPerSample: t0.bitsPerSample,
            sampleRate: t0.sampleRate,
            lossless: t0.lossless,
          ),
          const SizedBox(width: 14),
          Text(
            '${ts.length > 1 ? '${ts.length} parts · ' : ''}'
            '${formatDuration(secs)}',
            style: TextStyle(color: c.fgDim),
          ),
        ],
      ),
    );
  }
}

/// Hero card from /api/composer/:name (Open Opus + Wikipedia): full name,
/// epoch, dates, portrait, bio, link (legacy heroCard default variant).
class _ComposerHero extends ConsumerWidget {
  const _ComposerHero({required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    return ref
        .watch(composerInfoProvider(name))
        .when(
          loading: () => Text('Researching…', style: TextStyle(color: c.fgDim)),
          error: (_, _) => const SizedBox.shrink(),
          data: (d) {
            if (d == null ||
                (d.bio == null && d.portrait == null && d.epoch == null)) {
              return const SizedBox.shrink();
            }
            final dates = d.born != null ? '${d.born}–${d.died ?? ''}' : null;
            final meta = [
              if (d.fullName != null && d.fullName != name) d.fullName,
              d.epoch,
              dates,
            ].whereType<String>().join(' · ');
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (d.portrait != null) ...[
                  ArtImage(
                    url: d.portrait,
                    fallbackText: name,
                    size: 150,
                    borderRadius: AriaRadius.lg,
                  ),
                  const SizedBox(width: AriaSpace.s6),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (meta.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AriaSpace.s2),
                          child: Text(
                            meta,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      if (d.bio != null) Text(d.bio!),
                      if (d.url != null)
                        Padding(
                          padding: const EdgeInsets.only(top: AriaSpace.s2),
                          child: InkWell(
                            onTap: () => openExternal(d.url!),
                            child: Text(
                              'Wikipedia →',
                              style: TextStyle(
                                color: c.fg,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
  }
}
