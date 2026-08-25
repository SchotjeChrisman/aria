import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/library_providers.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../album/providers.dart' show albumInfoProvider;
import 'providers.dart';

/// Human names for the distance components. This map is the entire reason the
/// server persists `why`: it turns "the matcher was unsure" into "the matcher
/// was unsure because the artist credit does not match", which is usually the
/// difference between deciding in two seconds and opening MusicBrainz.
/// Components added server-side later show under their raw key.
const _whyLabels = <String, String>{
  'album': 'Album title',
  'artist': 'Artist credit',
  'year': 'Year',
  'mediums': 'Disc count',
  'missing': 'Tracks MusicBrainz has that you do not',
  'unmatched': 'Tracks you have that MusicBrainz does not',
  'trackTitle': 'Track titles',
  'trackLength': 'Track lengths',
  'trackIndex': 'Track order',
};

/// Resolve one album's identity: pick a release, give up on matching, or ask
/// the server to try again.
///
/// [ref] MUST outlive the row that opened this dialog. Every action here
/// invalidates `reviewQueueProvider`, which rebuilds the very list the row
/// belongs to — and a row whose album has just left the queue is unmounted by
/// that rebuild. A tile's own ref would be disposed underneath the still-open
/// dialog, so the next action taken in it would throw instead of running.
/// Pass the screen's ref, which lives as long as the route.
Future<void> showMatchDetail(
  BuildContext context,
  WidgetRef ref,
  MatchDecision decision,
) => showDialog<void>(
  context: context,
  builder: (_) => MatchDetailDialog(ref: ref, decision: decision),
);

/// The injected ref must be the SCREEN's, never a list tile's — see the note on
/// [showMatchDetail]. Invalidations fired from here have to land after this
/// dialog pops AND after the list underneath it has rebuilt.
class MatchDetailDialog extends StatefulWidget {
  const MatchDetailDialog({
    super.key,
    required this.ref,
    required this.decision,
  });

  final WidgetRef ref;
  final MatchDecision decision;

  @override
  State<MatchDetailDialog> createState() => MatchDetailDialogState();
}

class MatchDetailDialogState extends State<MatchDetailDialog> {
  late MatchDecision _d = widget.decision;
  String? _status;
  bool _busy = false;

  /// Captured once from the row that opened this dialog, and never re-read from
  /// [_d]. The queue endpoint joins the albums table for a title; the
  /// single-album match endpoints do NOT, and `album`/`albumArtist` are
  /// `omitempty` — so the decision returned by "Try again" carries neither.
  /// Recomputing the title from the refreshed decision blanks the header of
  /// the dialog the user is looking at.
  late final String _title = [
    widget.decision.albumArtist,
    widget.decision.album,
  ].where((s) => s.isNotEmpty).join(' — ');

  /// Every action here changes an album's identity, which moves credits and
  /// artwork as well as the title — so the whole library view goes stale, not
  /// just this album.
  ///
  /// These first two are the set `invalidateLibrary` invalidates; that helper
  /// takes a provider `Ref` and cannot be handed a widget's `WidgetRef`, so it
  /// is spelled out here. peopleProvider matters as much as the track list: a
  /// different release means different credits, and that is what it caches.
  void _refresh() {
    widget.ref.invalidate(libraryTracksProvider);
    widget.ref.invalidate(peopleProvider);
    widget.ref.invalidate(albumInfoProvider(_d.albumId));
    widget.ref.invalidate(reviewQueueProvider);
  }

  /// A 502 from this server means matching is unavailable or the attempt
  /// failed upstream. Rendering the raw body instead would put a proxy's HTML
  /// error page in a dialog.
  String _explain(Object e, String fallback) {
    if (e is AriaApiException) {
      if (e.statusCode == 502) {
        return 'MusicBrainz could not be reached. Try again in a moment.';
      }
      if (e.statusCode == 0) return 'The server did not respond in time.';
    }
    return fallback;
  }

  Future<void> _run(
    String busyText,
    Future<void> Function() body, {
    required String failure,
    bool close = true,
  }) async {
    setState(() {
      _busy = true;
      _status = busyText;
    });
    try {
      await body();
      // BEFORE the mounted guard, deliberately. The dialog is dismissible
      // (barrier, Close, back button) while a ~10s request is in flight, and
      // closing it does not cancel the request — the server still commits. If
      // the invalidations sat behind `mounted` they would be skipped for a
      // mutation that succeeded, leaving the library, credits, artwork and this
      // very queue showing the old identity until the app restarts. _refresh
      // touches no BuildContext, only the ref, so it is safe when unmounted.
      _refresh();
      if (!mounted) return;
      if (close) {
        Navigator.of(context).pop();
        return;
      }
      setState(() => _status = null);
    } catch (e) {
      if (mounted) setState(() => _status = _explain(e, failure));
    } finally {
      // pop() has already unmounted us on the success path, so this guard is
      // load-bearing rather than defensive.
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept(MatchCandidate c) => _run(
    'Re-identifying… (MusicBrainz is slow, ~10s)',
    () => widget.ref
        .read(apiClientProvider)
        .reidentifyAlbum(_d.albumId, mbid: c.mbid),
    failure: 'Re-identify failed — server or MusicBrainz unavailable.',
  );

  Future<void> _useMyTags() => _run(
    'Dropping the MusicBrainz match…',
    () => widget.ref
        .read(apiClientProvider)
        .patchAlbum(_d.albumId, {'state': 'local'}),
    failure: 'Failed — server unavailable.',
  );

  /// Stays open on success, unlike the other two: the call returns the fresh
  /// decision, and the whole point of pressing it is to look at the new
  /// candidate list. Closing would hide the answer that was just fetched.
  Future<void> _tryAgain() => _run(
    'Re-matching… (MusicBrainz is slow, ~15s)',
    () async {
      final fresh = await widget.ref
          .read(apiClientProvider)
          .rematchAlbum(_d.albumId);
      if (mounted) setState(() => _d = fresh);
    },
    failure: 'Re-match failed — the server could not reach MusicBrainz.',
    close: false,
  );

  /// Pop first: pushInShell must not run with this dialog still on top, or the
  /// album page opens underneath it.
  void _openAlbum() {
    Navigator.of(context).pop();
    pushInShell(context, '/album/${_d.albumId}');
  }

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final theme = Theme.of(context);

    return AlertDialog(
      backgroundColor: c.bgRaised,
      title: Text(
        _title.isEmpty ? 'Match review' : _title,
        style: theme.textTheme.titleMedium,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.all(AriaSpace.s2),
                  child: Text(_status!, style: TextStyle(color: c.fgDim)),
                ),
              if (_d.hasNoCandidates)
                _noCandidates(context)
              else
                for (final cand in _d.candidates) _candidateRow(context, cand),
              const Divider(height: AriaSpace.s4),
              // Hidden when the album is already local — there the answer is
              // in force and the button would do nothing.
              if (_d.state != 'local') _localRow(context),
            ],
          ),
        ),
      ),
      actions: [
        // The way out of a dead end. For an album with no candidates there is
        // nothing here to pick, and the answer is a manual MusicBrainz search
        // — which the album page already offers, along with the metadata
        // editor and artwork. Rebuilding a search box in this dialog would
        // duplicate a flow that exists two taps away.
        TextButton(
          onPressed: _busy ? null : _openAlbum,
          child: const Text('Open album'),
        ),
        TextButton(
          onPressed: _busy ? null : _tryAgain,
          child: const Text('Try again'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _noCandidates(BuildContext context) {
    final c = AriaColors.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AriaSpace.s3,
        vertical: AriaSpace.s2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('MusicBrainz returned no release for this album.'),
          const SizedBox(height: AriaSpace.s2),
          Text(
            'Your tags are being used as-is. Nothing is wrong with the files — '
            'the album may simply not be in MusicBrainz.',
            style: theme.textTheme.bodySmall?.copyWith(color: c.fgDim),
          ),
          if (_d.retryAfter.isNotEmpty) ...[
            const SizedBox(height: AriaSpace.s2),
            Text(
              'The server retries on its own after ${_d.retryAfter}.',
              style: theme.textTheme.bodySmall?.copyWith(color: c.fgDim),
            ),
          ],
        ],
      ),
    );
  }

  Widget _localRow(BuildContext context) {
    final c = AriaColors.of(context);
    return InkWell(
      onTap: _busy ? null : _useMyTags,
      borderRadius: BorderRadius.circular(AriaRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AriaSpace.s3,
          vertical: AriaSpace.s2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Not in MusicBrainz — use my own tags'),
            Text(
              'Drops this album’s MusicBrainz data. Your files are untouched.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: c.fgDim),
            ),
          ],
        ),
      ),
    );
  }

  Widget _candidateRow(BuildContext context, MatchCandidate cand) {
    final theme = Theme.of(context);
    final c = AriaColors.of(context);
    final sub = [
      cand.artist,
      cand.date,
      cand.country,
      if (cand.tracks != null) '${cand.tracks} tracks',
      if ((cand.media ?? 1) > 1) '${cand.media} discs',
      if (cand.source.isNotEmpty) cand.source,
    ].where((s) => s.isNotEmpty).join(' · ');

    // Worst offender first: the component that actually cost this candidate
    // the match is the one worth reading, and a zero explains nothing.
    final why = cand.why.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return InkWell(
      // Left tappable for the whole ~10s call, a double tap fires two POSTs.
      onTap: _busy ? null : () => _accept(cand),
      borderRadius: BorderRadius.circular(AriaRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AriaSpace.s3,
          vertical: AriaSpace.s2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    cand.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (cand.distance != null)
                  Text(
                    cand.distance!.toStringAsFixed(2),
                    style: theme.textTheme.bodySmall?.copyWith(color: c.fgDim),
                  ),
              ],
            ),
            if (cand.disambiguation.isNotEmpty)
              Text(
                cand.disambiguation,
                style: theme.textTheme.bodySmall?.copyWith(color: c.fgDim),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (sub.isNotEmpty)
              Text(
                sub,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (why.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AriaSpace.s1),
                child: Text(
                  why
                      .map(
                        (e) =>
                            '${_whyLabels[e.key] ?? e.key} '
                            '${e.value.toStringAsFixed(2)}',
                      )
                      .join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(color: c.fgDim),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
