import 'package:aria/core/library_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('enrich SSE frames map to busy correctly', () {
    expect(enrichBusy({'phase': 'albums', 'running': true}), true);
    expect(enrichBusy({'phase': 'idle', 'running': false}), false);
    // Defensive: junk frames must read as idle, never as a stuck busy.
    expect(enrichBusy('garbage'), false);
    expect(enrichBusy(null), false);
  });
}
