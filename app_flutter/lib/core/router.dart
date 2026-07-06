import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/album/routes.dart' as album;
import '../features/artist/routes.dart' as artist;
import '../features/home/routes.dart' as home;
import '../features/library/routes.dart' as library_;
import '../features/now_playing/routes.dart' as now_playing;
import '../features/playlists/routes.dart' as playlists;
import '../features/radio/routes.dart' as radio;
import '../features/search/routes.dart' as search;
import '../features/settings/routes.dart' as settings;
import '../features/stats/routes.dart' as stats;
import '../features/tags/routes.dart' as tags;
import '../widgets/selection_bar.dart';
import 'connection.dart';
import 'theme.dart';

// ---------------------------------------------------------------------------
// Per-feature route registration pattern
// ---------------------------------------------------------------------------
// Each feature exports a top-level `featureEntry` from
// lib/features/<name>/routes.dart:
//
//   final featureEntry = FeatureEntry(
//     destination: AppDestination(path: '/library', label: 'Library',
//         icon: Icons.grid_view_outlined, selectedIcon: Icons.grid_view),
//     routes: [
//       GoRoute(path: '/library', builder: ..., routes: [ /* nested */ ]),
//     ],
//   );
//
// and gets added to [featureEntries] below (the only per-feature line in
// core). Entries WITH a destination become shell branches (nav tabs, state
// preserved per tab); entries with destination == null are plain routes
// pushed above the shell (full-screen pages like /setup).

class AppDestination {
  const AppDestination({
    required this.path,
    required this.label,
    required this.icon,
    this.selectedIcon,
  });

  final String path;
  final String label;
  final IconData icon;
  final IconData? selectedIcon;
}

class FeatureEntry {
  const FeatureEntry({this.destination, required this.routes});

  final AppDestination? destination;
  final List<RouteBase> routes;
}

/// Feature registry. Tab order mirrors the legacy sidebar; destination-less
/// entries (detail + overlay pages) are pushed above the shell.
final List<FeatureEntry> featureEntries = [
  home.homeFeatureEntry,
  library_.featureEntry,
  search.searchFeatureEntry,
  playlists.featureEntry,
  tags.featureEntry,
  radio.radioFeatureEntry,
  stats.statsFeatureEntry,
  settings.settingsFeatureEntry,
  album.featureEntry,
  artist.featureEntry,
  now_playing.featureEntry,
];

final routerProvider = Provider<GoRouter>((ref) {
  // Recreated only when first-run state flips (setup completed / URL cleared).
  final hasServer = ref.watch(serverUrlProvider.select((u) => u != null));

  final branches = [
    for (final e in featureEntries)
      if (e.destination != null) StatefulShellBranch(routes: e.routes),
  ];
  final plainRoutes = [
    for (final e in featureEntries)
      if (e.destination == null) ...e.routes,
  ];

  return GoRouter(
    // Home is the default landing view, like legacy renderHome.
    initialLocation: hasServer ? '/home' : '/setup',
    redirect: (context, state) {
      final atSetup = state.matchedLocation == '/setup';
      if (!hasServer && !atSetup) return '/setup';
      if (hasServer && atSetup) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/setup', builder: (_, _) => const ServerSetupScreen()),
      ...plainRoutes,
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AdaptiveShell(shell: shell),
        branches: branches,
      ),
    ],
  );
});

/// NavigationRail on wide layouts (desktop), NavigationBar on narrow
/// (Android phones). Width-based, not platform-based, so desktop windows
/// resized narrow and Android tablets both do the right thing.
class AdaptiveShell extends StatelessWidget {
  const AdaptiveShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  static const _railBreakpoint = 700.0;

  @override
  Widget build(BuildContext context) {
    final destinations = [
      for (final e in featureEntries)
        if (e.destination != null) e.destination!,
    ];
    final wide = MediaQuery.sizeOf(context).width >= _railBreakpoint;
    final c = AriaColors.of(context);

    if (!wide) {
      return Scaffold(
        body: Column(
          children: [
            Expanded(child: shell),
            const SelectionBar(),
            const now_playing.TransportBar(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: shell.currentIndex,
          onDestinationSelected: _select,
          destinations: [
            for (final d in destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon ?? d.icon),
                label: d.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: shell.currentIndex,
                  onDestinationSelected: _select,
                  labelType: NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AriaSpace.s6),
                    // Legacy .brand: letterspaced uppercase wordmark in accent.
                    child: Text(
                      'ARIA',
                      style: TextStyle(
                        fontSize: 16,
                        letterSpacing: 4.8,
                        color: c.accent,
                      ),
                    ),
                  ),
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selectedIcon ?? d.icon),
                        label: Text(d.label),
                      ),
                  ],
                ),
                VerticalDivider(width: 1, color: c.line),
                Expanded(child: shell),
              ],
            ),
          ),
          const SelectionBar(),
          const now_playing.TransportBar(),
        ],
      ),
    );
  }

  void _select(int i) =>
      shell.goBranch(i, initialLocation: i == shell.currentIndex);
}
