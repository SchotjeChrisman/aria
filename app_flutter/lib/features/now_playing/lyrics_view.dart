import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/player_providers.dart';
import '../../core/theme.dart';
import '../../widgets/empty_state.dart';
import 'lrc.dart';
import 'providers.dart';
import 'transport_bar.dart';

/// Full-screen lyrics, pushed from now-playing (mirrors QueueScreen).
class LyricsScreen extends StatelessWidget {
  const LyricsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: c.bg,
        elevation: 0,
        title: Text('Lyrics', style: Theme.of(context).textTheme.titleMedium),
      ),
      body: const LyricsView(),
      bottomNavigationBar: const TransportBar(),
    );
  }
}

/// Lyrics pane for the current track (legacy loadLyrics + syncLyrics):
/// synced LRC highlights and follows the playing line; plain text scrolls;
/// the legacy empty-state strings are kept verbatim.
class LyricsView extends ConsumerWidget {
  const LyricsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    if (track == null) {
      return const EmptyState(message: 'Nothing playing.');
    }
    final lyrics = ref.watch(lyricsProvider(track.id));
    return lyrics.when(
      loading: () => const EmptyState(message: 'Looking up lyrics…'),
      error: (_, _) => const EmptyState(message: 'No lyrics found.'),
      data: (d) {
        if (d == null || d.isEmpty) {
          return const EmptyState(message: 'No lyrics found.');
        }
        final c = AriaColors.of(context);
        final Widget body = d.lines != null
            ? _SyncedLyrics(key: ValueKey(track.id), lines: d.lines!)
            : SingleChildScrollView(
                padding: const EdgeInsets.all(AriaSpace.s5),
                child: Text(
                  d.plain!,
                  style: TextStyle(height: 1.8, color: c.fg),
                ),
              );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Legacy #lyrics-src attribution.
            Padding(
              padding: const EdgeInsets.only(
                right: AriaSpace.s5,
                top: AriaSpace.s2,
              ),
              child: Text(
                'LRCLIB',
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            Expanded(child: body),
          ],
        );
      },
    );
  }
}

class _SyncedLyrics extends ConsumerStatefulWidget {
  const _SyncedLyrics({super.key, required this.lines});

  final List<LrcLine> lines;

  @override
  ConsumerState<_SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends ConsumerState<_SyncedLyrics> {
  late List<GlobalKey> _keys;
  final _scroll = ScrollController();
  int _last = -2; // never a valid index, so the first line always scrolls

  @override
  void initState() {
    super.initState();
    _keys = [for (final _ in widget.lines) GlobalKey()];
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    // Rebuild only when the highlighted line changes, not on every tick.
    final idx = ref.watch(
      playbackPositionProvider.select(
        (pos) => currentLrcIndex(widget.lines, pos.value ?? 0),
      ),
    );

    if (idx != _last) {
      _last = idx;
      // Legacy scrollIntoView({block:'center', behavior:'smooth'}).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || idx < 0 || idx >= _keys.length) return;
        final ctx = _keys[idx].currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.5,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }

    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(
        horizontal: AriaSpace.s5,
        vertical: 120, // room so first/last lines can center like legacy
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < widget.lines.length; i++)
            Padding(
              key: _keys[i],
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                // legacy renders '&nbsp;' for empty timed lines
                widget.lines[i].text.isEmpty ? ' ' : widget.lines[i].text,
                style: TextStyle(
                  fontSize: i == idx ? 17 : 15,
                  height: 1.5,
                  fontWeight: i == idx ? FontWeight.w600 : FontWeight.w400,
                  color: i == idx ? c.fg : c.fgDim,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
