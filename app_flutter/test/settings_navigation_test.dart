import 'dart:async';

import 'package:aria/core/connection.dart';
import 'package:aria/core/profiles_providers.dart';
import 'package:aria/core/quality.dart';
import 'package:aria/features/settings/about_screen.dart';
import 'package:aria/features/settings/account_screen.dart';
import 'package:aria/features/settings/data_screen.dart';
import 'package:aria/features/settings/downloads_screen.dart';
import 'package:aria/features/settings/eq_screen.dart';
import 'package:aria/features/settings/library_screen.dart';
import 'package:aria/features/settings/logs_screen.dart';
import 'package:aria/features/settings/playback_screen.dart';
import 'package:aria/features/settings/routes.dart';
import 'package:aria/features/settings/settings_providers.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Smoke test for the settings sub-page split: each category route builds and
/// the nested leaf routes (eq/logs/downloads) still push from their category.
void main() {
  late GoRouter router;

  Future<void> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    router = GoRouter(
      initialLocation: '/settings',
      routes: settingsFeatureEntry.routes,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          // Keep the selectors enabled without hitting /api/status.
          transcodeAvailableProvider.overrideWithValue(true),
          // Network-backed providers stay inert so nothing hangs/leaks timers.
          serverSettingsProvider.overrideWith(
            (ref) => Completer<Settings>().future,
          ),
          // Resolve (not left loading): a loading spinner animates forever and
          // pumpAndSettle would never settle.
          profilesProvider.overrideWith((ref) async => <Profile>[]),
          enrichStatusProvider.overrideWith((ref) => Stream.empty()),
          networkKindProvider.overrideWith(
            (ref) => Stream.value(NetKind.wifi),
          ),
          opraProvider.overrideWith((ref) async => <OpraProduct>[]),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('each settings category route builds', (tester) async {
    await pump(tester);

    final cases = <String, Type>{
      '/settings/playback': PlaybackScreen,
      '/settings/data': DataScreen,
      '/settings/library': LibraryScreen,
      '/settings/account': AccountScreen,
      '/settings/about': AboutScreen,
    };
    for (final entry in cases.entries) {
      router.go(entry.key);
      await tester.pumpAndSettle();
      expect(find.byType(entry.value), findsOneWidget, reason: entry.key);
      expect(tester.takeException(), isNull, reason: entry.key);
    }
  });

  testWidgets('nested eq/logs/downloads leaves still push', (tester) async {
    await pump(tester);

    router.go('/settings/playback');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Headphone EQ'));
    await tester.pumpAndSettle();
    expect(find.byType(EqScreen), findsOneWidget);

    router.go('/settings/data');
    await tester.pumpAndSettle();
    // The quality sections above push the tile below the fold.
    await tester.scrollUntilVisible(find.text('Downloads'), 200);
    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadsScreen), findsOneWidget);

    router.go('/settings/about');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logs'));
    await tester.pumpAndSettle();
    expect(find.byType(LogsScreen), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
