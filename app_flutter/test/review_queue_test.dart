import 'dart:convert';

import 'package:aria/features/review/providers.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// The review queue mixes two different questions under one endpoint, and the
// badge is what tells the user whether any of it is theirs to answer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MatchDecision decision(String state, {String reason = 'weak-match'}) =>
      MatchDecision.fromJson({
        'albumId': '$state-$reason',
        'state': state,
        'reason': reason,
        'candidates': null,
      });

  ProviderContainer withQueue(List<MatchDecision> queue) {
    final c = ProviderContainer(
      overrides: [
        reviewQueueProvider.overrideWith((_) async => queue),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('the badge counts only albums still awaiting an answer', () async {
    final c = withQueue([
      decision('review'),
      decision('review', reason: 'low-separation'),
      // `local` rows are in the same queue but they are a settled outcome, and
      // the server retries them on its own. Counting them would nag forever
      // about a decision nobody has to make.
      decision('local', reason: 'no-candidates'),
      decision('local', reason: 'no-plausible-candidate'),
    ]);
    await c.read(reviewQueueProvider.future);

    expect(c.read(reviewCountProvider), 2);
  });

  test('the badge is zero, not an error, before the queue has loaded', () {
    // reviewCountProvider reads .value off an unresolved AsyncValue. A badge
    // that throws here would take the whole Library settings page down.
    final c = withQueue([decision('review')]);
    expect(c.read(reviewCountProvider), 0);
  });

  test('a settled library badges nothing', () async {
    final c = withQueue([decision('local', reason: 'no-candidates')]);
    await c.read(reviewQueueProvider.future);
    expect(c.read(reviewCountProvider), 0);
  });

  test('the client parses a bare array from /api/match/review', () async {
    // The endpoint returns a bare JSON array, not an envelope. _list casts
    // hard, so an envelope would surface as a raw TypeError rather than an
    // AriaApiException.
    final client = AriaClient(
      baseUrl: 'http://s',
      httpClient: MockClient((req) async {
        expect(req.url.path, '/api/match/review');
        return http.Response(
          jsonEncode([
            {
              'albumId': 'a',
              'state': 'review',
              'reason': 'weak-match',
              'separation': 0,
              'candidates': [
                {'mbid': 'm', 'title': 'T', 'distance': 0.12, 'why': {'artist': 1}},
              ],
            },
          ]),
          200,
        );
      }),
    );
    addTearDown(client.close);

    final ds = await client.matchReview();
    expect(ds, hasLength(1));
    expect(ds.single.separation, 0.0);
    expect(ds.single.candidates.single.why['artist'], 1.0);
  });

  test('a rematched decision carries no title, so the dialog must not re-read it', () {
    // GET/POST /api/albums/{id}/match return the decision WITHOUT album or
    // albumArtist — Matches.Get does not join the albums table the way the
    // queue's NonMatched does, and both fields are omitempty. Verified against
    // the live server. A dialog that recomputes its header from the refreshed
    // decision blanks the title of the album the user is looking at.
    final fromQueue = MatchDecision.fromJson({
      'albumId': 'a',
      'state': 'review',
      'reason': 'weak-match',
      'album': 'Puppet Show',
      'albumArtist': 'Ally Venable Band',
      'candidates': null,
    });
    final fromRematch = MatchDecision.fromJson({
      'albumId': 'a',
      'state': 'review',
      'reason': 'weak-match',
      'candidates': null,
    });

    expect(fromQueue.album, 'Puppet Show');
    expect(fromRematch.album, isEmpty);
    expect(fromRematch.albumArtist, isEmpty);
  });
}
