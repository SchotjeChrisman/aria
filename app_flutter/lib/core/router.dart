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

  /// Branch index == position in this unfiltered list.
  static final _all = <AppDestination>[
    for (final e in featureEntries)
      if (e.destination != null) e.destination!,
  ];

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final band = AriaBreakpoint.fromWidth(width);
    final wide = band != AriaBreakpoint.mobile;
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
        // Bars float over the content (frosted, shadowed) rather than docking
        // in the column, so content scrolls under them. Scroll bodies reserve
        // `transportFloatInset` at the bottom (via ariaPagePadding) to clear it.
        body: Column(
          children: [
            const now_playing.PlaybackUnavailableBanner(),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: shell),
                  const _FloatingBars(),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Sidebar morphs per band: compact icon rail on tablet, expanding to
    // icons+labels on desktop, with the extended width scaling with the
    // window. Custom (not NavigationRail) so the whole item highlights when
    // active — no Material icon-background pill.
    final extended = band == AriaBreakpoint.desktop;
    final sidebar = _Sidebar(
      destinations: visible,
      selectedIndex: selected,
      onSelect: select,
      extended: extended,
      width: extended ? (width * 0.16).clamp(150.0, 200.0) : 68,
    );

    // Rail spans the full height; the bottom bars live in the content column
    // to its right, so they align to the content area rather than the whole
    // window. They span the full content width (not the 1200 cap) — only the
    // scrolling content above them is centered and capped.
    return Scaffold(
      body: Row(
        // Stretch so the sidebar scroll view fills the height and its items
        // top-align (and scroll when a short window can't fit them all).
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Rail doesn't scroll natively; with the library split into
          // five entries it can overflow short windows. Flat sidebar (no
          // full-height fill), so it just scrolls — no stretch-to-viewport.
          SingleChildScrollView(child: sidebar),
          // Sole rail/content separator — a soft hairline (lineStrong reads too
          // heavy for a flat sidebar; plain line is invisible on white).
          const VerticalDivider(width: 1, color: Color(0xFFE0E0E4)),
          Expanded(
            // Top alert strip, then the content. Bars float over the content
            // area (aligned to content, not the whole window, so they clear the
            // rail). Content scrolls under them.
            child: Column(
              children: [
                const now_playing.PlaybackUnavailableBanner(),
                Expanded(
                  child: Stack(
                    children: [
                      // Provide the centering inset from the content-area width;
                      // the scroll views fold it into their own horizontal
                      // padding so the scrollable stays full-width (wheel works
                      // over the margins) while content is capped + centered.
                      Positioned.fill(
                        child: LayoutBuilder(
                          builder: (context, box) => ContentInset(
                            inset:
                                ((box.maxWidth -
                                            AriaBreakpoint.maxContentWidth) /
                                        2)
                                    .clamp(0.0, double.infinity),
                            child: shell,
                          ),
                        ),
                      ),
                      const _FloatingBars(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Flat sidebar: brand wordmark + a column of items. Each item highlights as a
/// whole (rounded accent-tint fill) when active — no NavigationRail icon pill.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
    required this.extended,
    required this.width,
  });

  final List<AppDestination> destinations;
  final int? selectedIndex;
  final ValueChanged<int> onSelect;
  final bool extended;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AriaSpace.s4),
            // Legacy .brand: letterspaced uppercase wordmark.
            child: Text(
              'ARIA',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, letterSpacing: 4, color: c.fg),
            ),
          ),
          for (final (i, d) in destinations.indexed)
            _SidebarItem(
              dest: d,
              selected: i == selectedIndex,
              extended: extended,
              onTap: () => onSelect(i),
            ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.dest,
    required this.selected,
    required this.extended,
    required this.onTap,
  });

  final AppDestination dest;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final fg = selected ? c.accent : c.fgDim;
    final icon = Icon(
      selected ? (dest.selectedIcon ?? dest.icon) : dest.icon,
      color: fg,
      size: 22,
    );
    final label = Text(
      dest.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: fg),
    );
    final content = extended
        ? Row(
            children: [
              icon,
              const SizedBox(width: AriaSpace.s3),
              Expanded(child: label),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [icon, const SizedBox(height: AriaSpace.s1), label],
          );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AriaSpace.s2,
      ),
      child: Material(
        // Active item is marked by colour only (accent icon + label) — no fill.
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AriaRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AriaRadius.md),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: extended ? AriaSpace.s3 : AriaSpace.s1,
              vertical: AriaSpace.s2,
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// The selection + transport bars, bottom-anchored and floating over the
/// content. [SelectionBar] collapses to nothing when no selection is active;
/// [TransportBar] is always present. `mainAxisSize.min` keeps the stack pinned
/// to the bottom edge without stealing hit-tests from the content above.
class _FloatingBars extends StatelessWidget {
  const _FloatingBars();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          SelectionBar(),
          now_playing.TransportBar(),
        ],
      ),
    );
  }
}
