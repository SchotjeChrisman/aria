import 'package:aria/features/home/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// The daily dot grid shows this calendar week plus the three before it — not
/// a rolling 28-day window, which used to file a play from last Saturday into
/// the current week's Saturday column, ahead of "today".
void main() {
  // Wednesday 2026-08-26, 12:00 local.
  final now = DateTime(2026, 8, 26, 12);

  test('this week is Monday-anchored, not a rolling 7 days', () {
    final (weeks, grid) = bucketWeeks([
      (DateTime(2026, 8, 24, 9), 100), // Mon this week
      (DateTime(2026, 8, 26, 9), 200), // Wed = today
      (DateTime(2026, 8, 22, 9), 400), // Sat, 4 days ago → LAST week
    ], now);

    expect(weeks[0], 300);
    expect(weeks[1], 400);
    expect(grid[0][0], 100); // Mon
    expect(grid[0][2], 200); // Wed
    expect(grid[1][5], 400); // last week's Sat, not this week's
  });

  test('days this week has not reached draw no dot', () {
    final (_, grid) = bucketWeeks(const [], now);
    expect(grid[0].sublist(3), everyElement(-1)); // Thu..Sun
    expect(grid[0].sublist(0, 3), everyElement(0)); // Mon..Wed
    expect(grid[1], everyElement(0)); // past weeks keep all 7 days
  });

  test('week boundaries land on the right row', () {
    final (weeks, _) = bucketWeeks([
      (DateTime(2026, 8, 23, 23), 1), // Sun, end of last week
      (DateTime(2026, 8, 17), 2), // Mon, start of last week
      (DateTime(2026, 8, 10), 4), // two weeks back
      (DateTime(2026, 8, 3), 8), // three weeks back
      (DateTime(2026, 8, 2), 16), // four weeks back → dropped
      (DateTime(2026, 8, 30), 32), // Sunday, still in the future → dropped
    ], now);
    expect(weeks, [0, 3, 4, 8]);
  });
}
