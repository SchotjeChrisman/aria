import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'lyrics_view.dart';
import 'now_playing_screen.dart';
import 'queue_screen.dart';

export 'transport_bar.dart' show TransportBar, PlaybackUnavailableBanner;

/// No nav destination: now-playing, lyrics and queue are full-screen pages
/// pushed above the shell (legacy overlay/panel). The persistent
/// [TransportBar] must be mounted by core's AdaptiveShell under the branch
/// content — see the feature report's gap list.
final featureEntry = FeatureEntry(
  routes: [
    GoRoute(path: '/now-playing', builder: (_, _) => const NowPlayingScreen()),
    GoRoute(path: '/lyrics', builder: (_, _) => const LyricsScreen()),
    GoRoute(path: '/queue', builder: (_, _) => const QueueScreen()),
  ],
);
