import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import 'now_playing_screen.dart';
import 'queue_screen.dart';

export 'transport_bar.dart' show TransportBar;

/// No nav destination: now-playing and queue are full-screen pages pushed
/// above the shell (legacy overlay/panel). The persistent [TransportBar]
/// must be mounted by core's AdaptiveShell under the branch content — see
/// the feature report's gap list.
final featureEntry = FeatureEntry(
  routes: [
    GoRoute(path: '/now-playing', builder: (_, _) => const NowPlayingScreen()),
    GoRoute(path: '/queue', builder: (_, _) => const QueueScreen()),
  ],
);
