import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/art_image.dart';
import '../../widgets/empty_state.dart';
import 'lyrics_view.dart';
import 'providers.dart';
import 'signal_path.dart';
import 'transport_bar.dart';

/// Expanded now-playing (legacy #np-overlay): big art + title/sub + signal
/// path, synced lyrics beside (wide) or below (narrow). The transport stays
/// visible at the bottom, like the legacy now-bar under the overlay.
class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final c = AriaColors.of(context);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: c.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          tooltip: 'Close',
          onPressed: () => context.pop(),
        ),
      ),
      body: track == null
          ? const EmptyState(message: 'Nothing playing.')
          : LayoutBuilder(
              builder: (context, box) {
                final wide = box.maxWidth >= 760;
                final meta = _Meta(track: track, centered: !wide);
                if (wide) {
                  return Padding(
                    padding: const EdgeInsets.all(AriaSpace.s8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(flex: 5, child: meta),
                        const SizedBox(width: AriaSpace.s8),
                        const Expanded(flex: 4, child: LyricsView()),
                      ],
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.all(AriaSpace.s5),
                  child: Column(
                    children: [
                      meta,
                      const SizedBox(height: AriaSpace.s4),
                      const Expanded(child: LyricsView()),
                    ],
                  ),
                );
              },
            ),
      bottomNavigationBar: const TransportBar(),
    );
  }
}

class _Meta extends ConsumerWidget {
  const _Meta({required this.track, required this.centered});

  final Track track;
  final bool centered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final artUrl = ref.read(apiClientProvider).artUrl(track.albumId);
    final align = centered
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: align,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: centered ? 240 : 420,
            maxHeight: centered ? 240 : 420,
          ),
          child: AspectRatio(
            aspectRatio: 1,
            child: ArtImage(
              url: artUrl,
              fallbackText: track.album,
              borderRadius: AriaRadius.lg,
            ),
          ),
        ),
        const SizedBox(height: AriaSpace.s5),
        Text(
          trackTitleLine(track),
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AriaSpace.s1),
        Text(
          trackSubLine(track),
          style: TextStyle(fontSize: 15, color: c.fgDim),
          textAlign: centered ? TextAlign.center : TextAlign.start,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AriaSpace.s4),
        const SignalPath(),
      ],
    );
  }
}
