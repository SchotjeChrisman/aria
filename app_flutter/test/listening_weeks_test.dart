import 'package:aria/features/home/home_screen.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// The home page's listening box buckets by Monday-start calendar weeks, so the
/// current (partial) week is always its own row — a rolling 28-day window used
/// to smear today's plays across the same bucket as last week's.
void main() {
  const byId = {
    't': Track(id: 't', albumId: 'a', duration: 60),
  };

  PlayRef playOn(DateTime d) => PlayRef(id: 't', at: d.toIso8601String());

  ({List<double> weekSecs, List<List<double>> dayGrid}) bucket(
    List<DateTime> plays,
    DateTime now,
  ) =>
      bucketListening(plays.map(playOn).toList(), byId, now);

  test('today lands in the current week, however far into it we are', () {
    // Wednesday 2026-08-12: the week started Monday the 10th.
    final now = DateTime(2026, 8, 12, 15);
    final r = bucket([
      DateTime(2026, 8, 12, 9), // today
      DateTime(2026, 8, 10, 20), // Monday, same week
    ], now);

    expect(r.weekSecs, [120, 0, 0, 0]);
    expect(r.dayGrid[0][2], 60); // Wednesday
    expect(r.dayGrid[0][0], 60); // Monday
  });

  test('the day before Monday falls into last week, not the current one', () {
    final now = DateTime(2026, 8, 10, 8); // Monday morning
    final r = bucket([
      DateTime(2026, 8, 10, 7), // this week (Monday)
      DateTime(2026, 8, 9, 23), // Sunday — previous calendar week
    ], now);

    expect(r.weekSecs, [60, 60, 0, 0]);
    expect(r.dayGrid[1][6], 60); // Sunday of last week
  });

  test('buckets run back three whole weeks and drop anything older', () {
    final now = DateTime(2026, 8, 12, 15); // week of Mon 2026-08-10
    final r = bucket([
      DateTime(2026, 8, 11), // this week
      DateTime(2026, 8, 3), // week -1 (Mon)
      DateTime(2026, 7, 30), // week -2
      DateTime(2026, 7, 21), // week -3
      DateTime(2026, 7, 19), // week -4, dropped
    ], now);

    expect(r.weekSecs, [60, 60, 60, 60]);
  });

  test('plays dated after the current week are ignored', () {
    final now = DateTime(2026, 8, 12, 15);
    final r = bucket([DateTime(2026, 8, 17)], now); // next Monday
    expect(r.weekSecs, [0, 0, 0, 0]);
  });

  test('unknown tracks contribute no time', () {
    final r = bucketListening(
      [PlayRef(id: 'gone', at: DateTime(2026, 8, 12).toIso8601String())],
      byId,
      DateTime(2026, 8, 12, 15),
    );
    expect(r.weekSecs, [0, 0, 0, 0]);
  });
}
