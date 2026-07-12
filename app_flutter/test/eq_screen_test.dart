import 'dart:convert';

import 'package:aria/core/connection.dart';
import 'package:aria/core/phosphor_icons.dart';
import 'package:aria/core/eq.dart';
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

const _fav = EqProfile(
  name: 'Sony WH-1000XM4 · oratory1990',
  bands: [EqBand(type: 'peak_dip', frequency: 200, gainDb: -2, q: 1)],
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
    'aria.eq': jsonEncode({'enabled': enabled}),
    'aria.eq.custom': jsonEncode([_preset.toJson()]),
  };

  testWidgets('selecting a headphone favourite and a custom preset both apply',
      (tester) async {
    final container = await pump(
      tester,
      prefs: {
        ...presetPrefs(enabled: false),
        'aria.eq.favourites': jsonEncode([_fav.toJson()]),
      },
    );

    // Favourite -> headphone slot; enabling happens automatically.
    await tester.tap(find.text(_fav.name!));
    await tester.pump();
    // Custom preset -> custom slot.
    await tester.tap(find.text('My EQ'));
    await tester.pump();

    final eq = container.read(eqProvider);
    expect(eq.headphone?.name, _fav.name);
    expect(eq.custom?.name, 'My EQ');
    expect(eq.enabled, isTrue);
    // Combined chain stacks both bands.
    final combined = combineEq(eq.headphone, eq.custom);
    expect(combined!.bands.length, 2);
  });

  testWidgets('clearing each slot leaves the other intact', (tester) async {
    final container = await pump(
      tester,
      prefs: {
        'aria.eq': jsonEncode({
          'enabled': true,
          'headphone': _fav.toJson(),
          'custom': _preset.toJson(),
        }),
        'aria.eq.custom': jsonEncode([_preset.toJson()]),
      },
    );

    // Two clear (×) buttons, one per filled slot.
    final clears = find.byIcon(PhosphorIconsRegular.x);
    expect(clears, findsNWidgets(2));

    // Clear the headphone slot (first ×).
    await tester.tap(clears.first);
    await tester.pump();
    expect(container.read(eqProvider).headphone, isNull);
    expect(container.read(eqProvider).custom?.name, 'My EQ');

    // Clear the custom slot (now the only ×).
    await tester.tap(find.byIcon(PhosphorIconsRegular.x));
    await tester.pump();
    expect(container.read(eqProvider).custom, isNull);
  });

  testWidgets('master switch flips enabled without touching slots',
      (tester) async {
    final container = await pump(
      tester,
      prefs: {
        'aria.eq': jsonEncode({'enabled': true, 'custom': _preset.toJson()}),
        'aria.eq.custom': jsonEncode([_preset.toJson()]),
      },
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();

    final eq = container.read(eqProvider);
    expect(eq.enabled, isFalse);
    expect(eq.custom?.name, 'My EQ'); // slot preserved
  });

  testWidgets('un-favouriting removes the row', (tester) async {
    final container = await pump(
      tester,
      prefs: {
        ...presetPrefs(enabled: false),
        'aria.eq.favourites': jsonEncode([_fav.toJson()]),
      },
    );

    expect(find.text(_fav.name!), findsOneWidget);
    // The filled star trailing un-favourites.
    await tester.tap(find.byIcon(PhosphorIconsFill.star));
    await tester.pump();

    expect(container.read(favouriteEqProvider), isEmpty);
    expect(find.text(_fav.name!), findsNothing);
  });

  testWidgets('deleting the preset in the custom slot clears it',
      (tester) async {
    final container = await pump(
      tester,
      prefs: {
        'aria.eq': jsonEncode({'enabled': true, 'custom': _preset.toJson()}),
        'aria.eq.custom': jsonEncode([_preset.toJson()]),
      },
    );

    await tester.tap(find.byIcon(PhosphorIconsRegular.trash));
    await tester.pump();

    expect(container.read(customEqPresetsProvider), isEmpty);
    expect(container.read(eqProvider).custom, isNull);
  });

  testWidgets('editing the custom-slot preset keeps enabled off',
      (tester) async {
    final container = await pump(
      tester,
      prefs: {
        'aria.eq': jsonEncode({'enabled': false, 'custom': _preset.toJson()}),
        'aria.eq.custom': jsonEncode([_preset.toJson()]),
      },
    );

    await tester.tap(find.byIcon(PhosphorIconsRegular.pencilSimple));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final eq = container.read(eqProvider);
    expect(eq.custom?.name, 'My EQ');
    expect(eq.enabled, isFalse);
  });

  testWidgets('renaming the custom-slot preset re-points the slot',
      (tester) async {
    final container = await pump(
      tester,
      prefs: {
        'aria.eq': jsonEncode({'enabled': true, 'custom': _preset.toJson()}),
        'aria.eq.custom': jsonEncode([_preset.toJson()]),
      },
    );

    await tester.tap(find.byIcon(PhosphorIconsRegular.pencilSimple));
    await tester.pumpAndSettle();
    // Rename in the dialog's Name field (pre-filled with the old name).
    await tester.enterText(find.widgetWithText(TextField, 'My EQ'), 'My EQ v2');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Slot follows the rename instead of pointing at a now-gone preset.
    final eq = container.read(eqProvider);
    expect(eq.custom?.name, 'My EQ v2');
    expect(eq.enabled, isTrue);
  });

  testWidgets('editor refuses to save out-of-range bands', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Add custom EQ'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Q').last, '0');
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
