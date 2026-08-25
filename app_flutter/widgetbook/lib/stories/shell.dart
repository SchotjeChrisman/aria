import 'package:aria/core/router.dart';
import 'package:aria/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:widgetbook/widgetbook.dart';

import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// App chrome — the navigation rail and the bars that float over every page.
/// These live in `../lib/core/router.dart` rather than under a feature,
/// because the shell is what the features are mounted inside.

/// The real destination table, filtered the way the shell filters it. Read
/// from `featureEntries` rather than transcribed: a feature that adds itself
/// to the router shows up in the catalogue with no edit here.
List<AppDestination> _destinations({required bool wide}) => [
      for (final e in featureEntries)
        if (e.destination case final d?)
          if (wide ? d.inRail : d.inBar) d,
    ];

/// The shell needs a StatefulNavigationShell, and only go_router builds one —
/// while resolving a StatefulShellRoute. So the story stands up its own
/// router over the app's own branch list, rather than the app's router. It is
/// a real shell around real pages; the alternative was faking the argument,
/// which would catalogue the fake.
Widget adaptiveShellStory(BuildContext context) {
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AdaptiveShell(shell: shell),
        branches: [
          for (final e in featureEntries)
            if (e.destination != null) StatefulShellBranch(routes: e.routes),
        ],
      ),
    ],
  );

  return StoryPage(
    children: [
      Section(
        title: 'AdaptiveShell',
        note: 'Rail on wide layouts, bottom bar on narrow ones, and the '
            'floating bars over both. Which destinations show is decided by '
            'the breakpoint band, not the pixel width — resize with the '
            'viewport addon to cross one.',
        child: SizedBox(
          height: 620,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: AriaTheme.light(),
            routerConfig: router,
          ),
        ),
      ),
    ],
  );
}

Widget sidebarStory(BuildContext context) {
  final extended = context.knobs
      .boolean(label: 'extended (labels shown)', initialValue: true);
  final width = context.knobs.double
      .slider(label: 'width', initialValue: 220, min: 72, max: 280);
  final selected = context.knobs.int
      .slider(label: 'selected index', initialValue: 0, min: 0, max: 5);

  final dests = _destinations(wide: true);

  return StoryPage(
    children: [
      Section(
        title: 'Sidebar',
        note: 'The wide-layout rail. Extended shows labels beside the icons; '
            'collapsed is icons only at rail width. Which destinations appear '
            'is the band\'s decision, not the sidebar\'s — it renders the list '
            'it is handed.',
        // No height given: the rail is a Column that sizes to its
        // destinations, and pinning it to a guessed height only decides
        // whether it overflows.
        child: Sidebar(
          destinations: dests,
          selectedIndex: selected.clamp(0, dests.length - 1),
          onSelect: (_) {},
          extended: extended,
          width: width,
        ),
      ),
      Section(
        title: 'Nothing selected',
        note: 'selectedIndex is nullable: on a route that owns no branch — a '
            'pushed album page, say — no item is highlighted rather than the '
            'wrong one.',
        child: Sidebar(
          destinations: dests,
          selectedIndex: null,
          onSelect: (_) {},
          extended: false,
          width: 72,
        ),
      ),
    ],
  );
}

Widget sidebarItemStory(BuildContext context) {
  final dests = _destinations(wide: true);

  return StoryPage(
    children: [
      Section(
        title: 'SidebarItem',
        note: 'Selected takes the accent colour and the filled icon weight; '
            'unselected is the dim foreground and the thin one. That weight '
            'swap is the selection signal, not just the colour.',
        child: SizedBox(
          width: 220,
          child: Column(
            children: [
              for (final (i, d) in dests.take(4).indexed)
                SidebarItem(
                  dest: d,
                  selected: i == 1,
                  extended: true,
                  onTap: () {},
                ),
            ],
          ),
        ),
      ),
      Section(
        title: 'Collapsed',
        child: Wrap(
          spacing: AriaSpace.s4,
          children: [
            for (final (i, d) in dests.take(4).indexed)
              Variant(
                label: d.label,
                child: SizedBox(
                  width: 72,
                  child: SidebarItem(
                    dest: d,
                    selected: i == 1,
                    extended: false,
                    onTap: () {},
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

Widget floatingBarsStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'FloatingBars',
        note: 'The selection bar over the transport bar, pinned to the bottom '
            'of every page. It is Positioned, so it only makes sense inside a '
            'Stack — which is what the shell gives it.',
        child: SizedBox(
          height: 220,
          child: Stack(
            children: [
              ColoredBox(
                color: AriaColors.of(context).bgRaised,
                child: const SizedBox.expand(),
              ),
              const FloatingBars(),
            ],
          ),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final shellEntries = <Entry>[
  Entry(
    component: 'AdaptiveShell',
    key: 'adaptive-shell',
    builder: adaptiveShellStory,
  ),
  Entry(component: 'Sidebar', key: 'sidebar', builder: sidebarStory),
  Entry(
    component: 'SidebarItem',
    key: 'sidebar-item',
    builder: sidebarItemStory,
  ),
  Entry(
    component: 'FloatingBars',
    key: 'floating-bars',
    builder: floatingBarsStory,
  ),
];
