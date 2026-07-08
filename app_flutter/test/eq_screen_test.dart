import 'dart:convert';

import 'package:aria/core/connection.dart';
import 'package:aria/core/player_providers.dart';
import 'package:aria/features/settings/eq_screen.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _preset = EqProfile(
  name: 'My EQ',
  bands: [EqBand(type: 'peak_dip', frequency: 1000, gainDb: 3, q: 1)],
);

void main() {
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Future<List<OpraProduct>> Function()? opra,
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final sharedPrefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(sharedPrefs),
          opraProvider.overrideWith((ref) => (opra ?? () async => [])()),
        ],
        child: const MaterialApp(home: EqScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(EqScreen)));
  }

  /// Prefs seed with 'My EQ' as a stored custom preset.
  Map<String, Object> presetPrefs({required bool enabled}) => {
    'aria.eq': jsonEncode({'enabled': enabled, ..._preset.toJson()}),
    'aria.eq.custom': jsonEncode([_preset.toJson()]),
  };

  testWidgets('local head stays usable when the OPRA fetch fails', (
    tester,
  ) async {
    final container = await pump(
      tester,
      opra: () async => throw Exception('502'),
      prefs: presetPrefs(enabled: true),
    );

    // Off, custom presets, and Add render despite the failed fetch; the
    // error shows as an inline row below them.
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('My EQ'), findsOneWidget);
    expect(find.text('Add custom EQ'), findsOneWidget);
    expect(find.textContaining('Could not load the OPRA database'),
        findsOneWidget);

    await tester.tap(find.text('Off'));
    expect(container.read(eqProvider).profile, isNull);
  });

  testWidgets('deleting the active preset resets the EQ to off', (
    tester,
  ) async {
    final container = await pump(tester, prefs: presetPrefs(enabled: true));

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();

    expect(container.read(customEqPresetsProvider), isEmpty);
    final eq = container.read(eqProvider);
    expect(eq.profile, isNull);
    expect(eq.enabled, isFalse);
  });

  testWidgets('editing the selected preset keeps the enabled flag off', (
    tester,
  ) async {
    final container = await pump(tester, prefs: presetPrefs(enabled: false));

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final eq = container.read(eqProvider);
    expect(eq.profile?.name, 'My EQ');
    expect(eq.enabled, isFalse);
  });

  testWidgets('editor refuses to save out-of-range bands', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Add custom EQ'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Q').last,
      '0',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Dialog stays open with the validation message.
    expect(find.text('New custom EQ'), findsOneWidget);
    expect(find.textContaining('Invalid EQ'), findsOneWidget);

    // Let the snackbar timer expire so no timers are pending at teardown.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
