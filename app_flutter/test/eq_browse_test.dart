import 'package:aria/core/connection.dart';
import 'package:aria/features/settings/eq_browse.dart';
import 'package:aria/features/settings/eq_screen.dart' show opraProvider;
import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget home, {
    required List<OpraProduct> products,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final sharedPrefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(sharedPrefs),
          opraProvider.overrideWith((ref) async => products),
        ],
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('duplicate-author curves render distinct subtitles',
      (tester) async {
    const product = OpraProduct(
      vendor: 'Sony',
      product: 'WH-1000XM4',
      eqs: [
        EqProfile(author: 'AutoEQ', details: 'Measured by Harpo'),
        EqProfile(author: 'AutoEQ', details: 'ANC on'),
      ],
    );
    await pump(tester, const EqCurvesScreen(product: product),
        products: const [product]);

    expect(find.text('AutoEQ'), findsNWidgets(2));
    expect(find.text('Measured by Harpo'), findsOneWidget);
    expect(find.text('ANC on'), findsOneWidget);
  });

  testWidgets('pinned brands appear on empty query and vanish on search',
      (tester) async {
    final products = [
      const OpraProduct(vendor: 'Sony', product: 'A'),
      const OpraProduct(vendor: 'Zebra Audio', product: 'B'),
    ];
    await pump(tester, const EqBrandsScreen(), products: products);

    // Pinned Sony shows even though 'Zebra Audio' sorts after it.
    expect(find.text('Sony'), findsWidgets);
    expect(find.byType(Divider), findsOneWidget);

    // Searching a term matching only the non-pinned vendor hides pinned rows.
    await tester.enterText(find.byType(TextField), 'zebra');
    await tester.pumpAndSettle();
    expect(find.text('Sony'), findsNothing);
    expect(find.text('Zebra Audio'), findsOneWidget);
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('more than 50 rows shows the refine-search hint', (tester) async {
    final products = [
      for (var i = 0; i < 60; i++)
        OpraProduct(vendor: 'Brand${i.toString().padLeft(3, '0')}', product: 'x'),
    ];
    await pump(tester, const EqBrandsScreen(), products: products);

    // Type a query so pinned rows are gone and all 60 vendors match.
    await tester.enterText(find.byType(TextField), 'brand');
    await tester.pumpAndSettle();

    // The hint sits past the 50-row cap; scroll it into the lazy ListView
    // (the TextField owns the other Scrollable, so target the ListView's).
    final hint = find.textContaining('more — refine your search');
    await tester.scrollUntilVisible(
      hint,
      500,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(hint, findsOneWidget);
  });
}
