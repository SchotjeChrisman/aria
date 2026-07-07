import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
    this.inRail = true,
    this.inBar = true,
  });

  final String path;
  final String label;
  final IconData icon;
  final IconData? selectedIcon;

  /// Show on wide layouts (NavigationRail) / narrow layouts (NavigationBar).
  /// Every destination still gets a shell branch regardless.
  final bool inRail;
  final bool inBar;
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
  ...library_.featureEntries,
  search.searchFeatureEntry,
  playlists.featureEntry,
  tags.featureEntry,
  radio.radioFeatureEntry,
  stats.statsFeatureEntry,
  settings.settingsFeatureEntry,
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
  static const _extendedBreakpoint = 1100.0;

  /// Branch index == position in this unfiltered list.
  static final _all = <AppDestination>[
    for (final e in featureEntries)
      if (e.destination != null) e.destination!,
  ];

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= _railBreakpoint;
    final c = AriaColors.of(context);

    final visible = [
      for (final d in _all)
        if (wide ? d.inRail : d.inBar) d,
    ];
    // Highlight the item whose path owns the current branch — '/library'
    // fronts '/library/albums' etc. on narrow layouts.
    final currentPath = _all[shell.currentIndex].path;
    int? selected;
    for (var i = 0; i < visible.length; i++) {
      final p = visible[i].path;
      if (currentPath == p || currentPath.startsWith('$p/')) {
        selected = i;
        break;
      }
    }
    void select(int i) {
      final branch = _all.indexOf(visible[i]);
      shell.goBranch(branch, initialLocation: branch == shell.currentIndex);
    }

    if (!wide) {
      return Scaffold(
        // Scaffold auto-adds the hamburger when a drawer is present.
        appBar: AppBar(
          title: Text(
            'ARIA',
            style: TextStyle(fontSize: 16, letterSpacing: 4.8, color: c.fg),
          ),
        ),
        // Drawer lists the narrow-layout destination set (the Library hub
        // fronts the per-section pages there, same as the old bottom bar).
        drawer: NavigationDrawer(
          selectedIndex: selected,
          onDestinationSelected: (i) {
            Navigator.pop(context);
            select(i);
          },
          children: [
            for (final d in visible)
              NavigationDrawerDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon ?? d.icon),
                label: Text(d.label),
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(child: shell),
            const SelectionBar(),
            const now_playing.TransportBar(),
          ],
        ),
      );
    }

    // Sidebar tracks window width: compact icon rail from 700px, expanding
    // to icons+labels past 1100px, with the extended width scaling with the
    // window.
    final extended = width >= _extendedBreakpoint;
    final rail = NavigationRail(
      selectedIndex: selected,
      onDestinationSelected: select,
      extended: extended,
      labelType: extended
          ? NavigationRailLabelType.none
          : NavigationRailLabelType.all,
      minExtendedWidth: (width * 0.18).clamp(180.0, 240.0),
      leading: Padding(
        padding: const EdgeInsets.symmetric(vertical: AriaSpace.s6),
        // Legacy .brand: letterspaced uppercase wordmark.
        child: Text(
          'ARIA',
          style: TextStyle(fontSize: 16, letterSpacing: 4.8, color: c.fg),
        ),
      ),
      destinations: [
        for (final d in visible)
          NavigationRailDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.selectedIcon ?? d.icon),
            label: Text(d.label),
          ),
      ],
    );

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                // Rail doesn't scroll natively; with the library split into
                // five entries it can overflow short windows.
                LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: IntrinsicHeight(child: rail),
                    ),
                  ),
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
}
