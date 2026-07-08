import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../widgets/art_image.dart';
import 'artist_util.dart';
import 'external_link.dart';
import 'providers.dart';

/// Info tab (legacy heroCard {full:true}): portrait, meta line, biography.
/// The cached bio is only the Wikipedia summary; the full article is fetched
/// client-side and swapped in when it lands (and is actually longer).
class ArtistInfoTab extends ConsumerWidget {
  const ArtistInfoTab({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    return ref
        .watch(artistInfoProvider(name))
        .when(
          loading: () => Text('Researching…', style: TextStyle(color: c.fgDim)),
          error: (_, _) => Text(
            'Nothing found about this name yet.',
            style: TextStyle(color: c.fgDim),
          ),
          data: (d) {
            if (d == null ||
                (d.bio == null && d.image == null && d.similar.isEmpty)) {
              return Text(
                'Nothing found about this name yet.',
                style: TextStyle(color: c.fgDim),
              );
            }
            final dates = d.born != null ? '${d.born}–${d.died ?? ''}' : null;
            final meta = [
              dates,
              d.area,
              d.type,
            ].whereType<String>().join(' · ');

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (d.image != null) ...[
                      ArtImage(
                        url: d.image,
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
                              padding: const EdgeInsets.only(
                                bottom: AriaSpace.s3,
                              ),
                              child: Text(
                                meta,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          _Bio(name: name, summary: d.bio, url: d.url),
                        ],
                      ),
                    ),
                  ],
                ),
                if (d.url != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AriaSpace.s4),
                    child: InkWell(
                      onTap: () => openExternal(d.url!),
                      child: Text(
                        'Wikipedia →',
                        style: TextStyle(color: c.fg, decoration: TextDecoration.underline),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
  }
}

class _Bio extends ConsumerWidget {
  const _Bio({required this.name, this.summary, this.url});

  final String name;
  final String? summary;
  final String? url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final full = url == null ? null : ref.watch(fullBioProvider(url!)).value;
    if (full != null) {
      final blocks = bioBlocks(full);
      // only swap in the full article when it beats the summary (legacy)
      final fullLen = blocks.fold(0, (s, b) => s + b.text.length);
      if (blocks.isNotEmpty && fullLen > (summary ?? '').length) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final b in blocks)
              Padding(
                padding: EdgeInsets.only(
                  top: b.heading ? AriaSpace.s4 : 0,
                  bottom: AriaSpace.s2,
                ),
                child: b.heading
                    ? Text(
                        b.text,
                        style: Theme.of(context).textTheme.titleMedium,
                      )
                    : Text(b.text),
              ),
          ],
        );
      }
    }
    if (summary == null) return const SizedBox.shrink();
    return Text(summary!);
  }
}
