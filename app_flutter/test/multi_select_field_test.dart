import 'package:aria/widgets/multi_select_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// The option list is shown only while the search field has focus, and the
/// field gives up focus on tap-OUTSIDE. Anything that makes an option count as
/// outside breaks picking with a mouse.
void main() {
  group('MultiSelectField', () {
    testWidgets('clicking an option selects it instead of closing the list', (
      tester,
    ) async {
      final state = MultiSelectState();
      await tester.pumpWidget(
        _app(
          MultiSelectField(
            label: 'Genre',
            options: const ['Jazz', 'Rock'],
            state: state,
          ),
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.text('Jazz'), findsOneWidget, reason: 'list should be open');

      // Press, let a frame render, then release — the real click sequence.
      // tester.tap() fires down and up inside one frame, which hides the bug:
      // the list is torn down by the rebuild that onTapOutside schedules, so
      // the release has to land on a list that is already gone.
      final press = await tester.startGesture(
        tester.getCenter(find.text('Jazz')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await press.up();
      await tester.pumpAndSettle();

      expect(state.vals, ['Jazz']);
      // and the list stays open, so a second pick needs no re-focus
      expect(find.text('Rock'), findsOneWidget);
    });
  });
}
