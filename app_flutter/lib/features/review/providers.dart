import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';

// Data layer for the match-review queue. One fetch feeds both the screen and
// the Library tile's count; refresh with ref.invalidate(reviewQueueProvider)
// after any decision changes.

/// Albums the matcher could not settle, best-scoring first.
///
/// autoDispose, like the diagnostics providers next door, and for the reason
/// they are: the queue also changes from OUTSIDE the app. A scan, an
/// enrichment pass or a periodic rescan re-decides albums server-side, and
/// nothing in the client hears about it. Cached for the session, the tile
/// badge and this list would keep reporting a number that stopped being true
/// hours ago — and the only cure would be restarting the app. Disposing when
/// nothing watches means each visit to the Library page or this screen asks
/// the server again, which is one cheap query over stored decisions.
final reviewQueueProvider = FutureProvider.autoDispose<List<MatchDecision>>(
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
