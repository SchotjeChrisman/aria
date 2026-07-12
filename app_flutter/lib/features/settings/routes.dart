import 'package:go_router/go_router.dart';
import '../../core/phosphor_icons.dart';

import '../../core/router.dart';
import 'about_screen.dart';
import 'account_screen.dart';
import 'data_screen.dart';
import 'downloads_screen.dart';
import 'eq_screen.dart';
import 'library_screen.dart';
import 'logs_screen.dart';
import 'playback_screen.dart';
import 'settings_page.dart';

final settingsFeatureEntry = FeatureEntry(
  destination: const AppDestination(
    path: '/settings',
    label: 'Settings',
    icon: PhosphorIconsThin.gear,
    selectedIcon: PhosphorIconsFill.gear,
  ),
  routes: [
    GoRoute(
      path: '/settings',
      builder: (_, _) => const SettingsPage(),
      routes: [
        // Category detail sub-pages (grouped settings buckets).
        GoRoute(path: 'playback', builder: (_, _) => const PlaybackScreen()),
        GoRoute(path: 'data', builder: (_, _) => const DataScreen()),
        GoRoute(path: 'library', builder: (_, _) => const LibraryScreen()),
        GoRoute(path: 'account', builder: (_, _) => const AccountScreen()),
        GoRoute(path: 'about', builder: (_, _) => const AboutScreen()),
        // Leaf detail pages (pushed from within the category pages).
        GoRoute(path: 'eq', builder: (_, _) => const EqScreen()),
        GoRoute(path: 'logs', builder: (_, _) => const LogsScreen()),
        GoRoute(
          path: 'downloads',
          builder: (_, _) => const DownloadsScreen(),
        ),
      ],
    ),
  ],
);
