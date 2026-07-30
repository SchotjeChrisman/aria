import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';

// Data layer for the match-review queue. One fetch feeds both the screen and
// the Library tile's count; refresh with ref.invalidate(reviewQueueProvider)
// after any decision changes.

/// Albums the matcher could not settle, best-scoring first.
///
/// Deliberately NOT autoDispose, unlike the diagnostics providers next door:
/// the Library settings tile reads the same list to show its count, so leaving
/// the screen must not throw the fetch away and make the tile refetch and
/// flicker on every visit. The list only changes when a matching pass runs or
/// the user decides something, and both invalidate it explicitly.
final reviewQueueProvider = FutureProvider<List<MatchDecision>>(
  (ref) => ref.watch(apiClientProvider).matchReview(),
);

/// How many albums are still waiting on a human answer.
///
/// Counts `review` only. The queue also carries `local` rows — albums where
/// MusicBrainz offered nothing — but those are a settled outcome, not a task:
/// badging them would nag forever about a decision the matcher already made
/// and will retry on its own.
final reviewCountProvider = Provider<int>(
  (ref) =>
      ref
          .watch(reviewQueueProvider)
          .value
          ?.where((d) => d.state == 'review')
          .length ??
      0,
);
