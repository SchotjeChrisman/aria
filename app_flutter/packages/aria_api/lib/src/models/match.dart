import '../json.dart';

/// `/api/match/review` and `/api/albums/{id}/match` — one album's identity
/// decision and the evidence behind it.
///
/// The review endpoint returns every album the matcher did NOT settle, which is
/// both `review` (it found releases but could not choose) and `local` (it found
/// nothing worth choosing). They read as one queue but they are not the same
/// question, and [candidates] is what tells them apart: a `local` row usually
/// has none, so there is nothing to pick and the only way forward is a manual
/// search or another attempt.
class MatchDecision {
  const MatchDecision({
    required this.albumId,
    required this.state,
    required this.reason,
    this.album = '',
    this.albumArtist = '',
    this.releaseMbid,
    this.releaseGroupMbid,
    this.disambiguation = '',
    this.distance,
    this.separation,
    this.pinned = false,
    this.attempts = 0,
    this.decidedAt = '',
    this.retryAfter = '',
    this.candidates = const [],
  });

  final String albumId;

  /// matched | review | local. Unknown states are shown under their raw name
  /// rather than dropped, so a server that adds one does not need an app
  /// release to stay legible.
  final String state;

  /// ok | pinned | no-candidates | no-plausible-candidate |
  /// indistinguishable-siblings | low-separation | weak-match. Same rule.
  final String reason;

  /// Both are `omitempty` server-side and can be absent.
  final String album;
  final String albumArtist;

  /// Null on every row in a review queue — these are by definition the albums
  /// with no accepted release — so nothing may assume they are present.
  final String? releaseMbid;
  final String? releaseGroupMbid;
  final String disambiguation;

  /// Weighted distance of the winning candidate; 0 is a perfect match. Null
  /// means the matcher never scored this album, which is the opposite of 0 —
  /// see the note on [MatchCandidate.distance].
  final double? distance;

  /// Gap to the best rival release group. Null when there was no rival, and
  /// legitimately 0 when two releases scored identically — the server sends
  /// that as a bare JSON `0`, so it must parse through asDouble and not a cast.
  final double? separation;

  /// The user chose this release; the matcher leaves it alone from now on.
  final bool pinned;
  final int attempts;

  /// ISO-8601 as the server formatted it. Shown verbatim, never parsed for
  /// logic.
  final String decidedAt;

  /// When the server will try this album again on its own. Present on the
  /// rows that found nothing, and usually the answer to "must I do something
  /// about this?" — no, it retries.
  final String retryAfter;

  final List<MatchCandidate> candidates;

  /// True when there is nothing to choose between: MusicBrainz returned no
  /// release the matcher considered worth offering. The detail view branches on
  /// this rather than on [state], because it is the thing that decides whether
  /// a picker can be shown at all.
  bool get hasNoCandidates => candidates.isEmpty;

  factory MatchDecision.fromJson(Map<String, dynamic> j) => MatchDecision(
        albumId: asString(j['albumId']) ?? '',
        state: asString(j['state']) ?? '',
        reason: asString(j['reason']) ?? '',
        album: asString(j['album']) ?? '',
        albumArtist: asString(j['albumArtist']) ?? '',
        releaseMbid: asString(j['releaseMbid']),
        releaseGroupMbid: asString(j['releaseGroupMbid']),
        disambiguation: asString(j['disambiguation']) ?? '',
        distance: asDouble(j['distance']),
        separation: asDouble(j['separation']),
        pinned: asBool(j['pinned']),
        attempts: asInt(j['attempts']) ?? 0,
        decidedAt: asString(j['decidedAt']) ?? '',
        retryAfter: asString(j['retryAfter']) ?? '',
        // candidates is a json.RawMessage server-side, so an unset value
        // marshals to a literal `null`, not to `[]`.
        candidates: [
          for (final c in (j['candidates'] as List? ?? const []))
            MatchCandidate.fromJson(asMap(c)),
        ],
      );
}

/// One release the matcher weighed, with the arithmetic that got it there.
///
/// Deliberately NOT the same model as `AlbumCandidate`, which serves
/// `/api/identify/album/{id}`. That one carries `score` — MusicBrainz search
/// relevance, where HIGHER is better. This one carries [distance] — matcher
/// distance, where LOWER is better. A single model holding both fields is how
/// a later change sorts the list backwards and nobody notices.
class MatchCandidate {
  const MatchCandidate({
    required this.mbid,
    this.rgMbid = '',
    this.title = '',
    this.artist = '',
    this.date = '',
    this.country = '',
    this.disambiguation = '',
    this.tracks,
    this.media,
    this.source = '',
    this.distance,
    this.why = const {},
  });

  final String mbid;
  final String rgMbid;
  final String title;
  final String artist;
  final String date;
  final String country;

  /// MusicBrainz's own note telling two otherwise identical releases apart
  /// ("US reissue", "bonus disc"). Often the only field that decides this
  /// screen's whole question.
  final String disambiguation;

  final int? tracks;
  final int? media;

  /// tag | acoustid | search — where this release came from. `acoustid` means
  /// fingerprints voted for it, which is far stronger evidence than a text
  /// search hit.
  final String source;

  /// Weighted distance; 0 is identical. Null means unscored, NOT perfect —
  /// rendering a null as 0.00 claims the exact opposite of the truth. This is
  /// the same trap that made every unanalysed track the quietest in the library
  /// when a null loudness coerced to 0.
  final double? distance;

  /// Per-component penalty: album, artist, year, mediums, missing, unmatched,
  /// trackTitle, trackLength, trackIndex. This is the breakdown that turns "the
  /// matcher is unsure" into "the matcher is unsure because this release has no
  /// artist credit". Keys the server adds later still render; values that fail
  /// to coerce are dropped rather than silently becoming 0.
  final Map<String, double> why;

  factory MatchCandidate.fromJson(Map<String, dynamic> j) => MatchCandidate(
        mbid: asString(j['mbid']) ?? '',
        rgMbid: asString(j['rgMbid']) ?? '',
        title: asString(j['title']) ?? '',
        artist: asString(j['artist']) ?? '',
        date: asString(j['date']) ?? '',
        country: asString(j['country']) ?? '',
        disambiguation: asString(j['disambiguation']) ?? '',
        tracks: asInt(j['tracks']),
        media: asInt(j['media']),
        source: asString(j['source']) ?? '',
        distance: asDouble(j['distance']),
        why: {
          for (final e in asMap(j['why']).entries)
            if (asDouble(e.value) case final n?) e.key: n,
        },
      );
}
