import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'providers.dart';

/// Legacy reidentifyMenu (album flavor): MusicBrainz candidate list → pick →
/// server drops its cache and re-enriches; then the library reloads because
/// credits/releaseType may have changed.
Future<void> showAlbumReidentify(
  BuildContext context,
  WidgetRef ref,
  Album album,
) => showDialog<void>(
  context: context,
  builder: (_) => AlbumReidentifyDialog(ref: ref, album: album),
);

class AlbumReidentifyDialog extends StatefulWidget {
  const AlbumReidentifyDialog({
    super.key,
    required this.ref,
    required this.album,
  });

  final WidgetRef ref;
  final Album album;

  @override
  State<AlbumReidentifyDialog> createState() => AlbumReidentifyDialogState();
}

class AlbumReidentifyDialogState extends State<AlbumReidentifyDialog> {
  List<AlbumCandidate>? _candidates;
  String? _status = 'Searching MusicBrainz…';

  @override
  void initState() {
    super.initState();
    widget.ref
        .read(albumApiProvider)
        .identifyAlbum(widget.album.id)
        .then((cands) {
          if (!mounted) return;
          setState(() {
            _candidates = cands;
            _status = cands.isEmpty ? 'No matches found.' : null;
          });
        })
        .catchError((_) {
          if (mounted) setState(() => _status = 'MusicBrainz unavailable.');
        });
  }

  /// The "none of these" answer. It is a plain album edit — `state: local`
  /// means "not in MusicBrainz, my tags are the truth" — and the server drops
  /// the album's derived MusicBrainz data on the spot. It lives at the bottom
  /// of the candidate list rather than behind a button in the editor because
  /// this is exactly where the user is already deciding about identity.
  Future<void> _useMyTags() async {
    setState(() => _status = 'Dropping the MusicBrainz match…');
    try {
      await widget.ref
          .read(albumApiProvider)
          .patchAlbum(widget.album.id, {'state': 'local'});
      widget.ref.invalidate(albumTracksProvider);
      widget.ref.invalidate(albumInfoProvider(widget.album.id));
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _status = 'Failed — server unavailable.');
    }
  }

  Future<void> _pick(AlbumCandidate c) async {
    setState(() => _status = 'Re-identifying… (MusicBrainz is slow, ~10s)');
    try {
      await widget.ref
          .read(albumApiProvider)
          .reidentifyAlbum(widget.album.id, mbid: c.mbid);
      widget.ref.invalidate(albumTracksProvider);
      widget.ref.invalidate(albumInfoProvider(widget.album.id));
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(
          () => _status =
              'Re-identify failed — server or MusicBrainz unavailable.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final cands = _candidates;
    return AlertDialog(
      backgroundColor: c.bgRaised,
      title: Text(
        'Re-identify — ${widget.album.title}',
        style: Theme.of(context).textTheme.titleMedium,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.all(AriaSpace.s2),
                  child: Text(_status!, style: TextStyle(color: c.fgDim)),
                )
              else
                for (final cand in cands!) _candidateRow(context, cand),
              // Always reachable, including when the search found nothing —
              // which is exactly when "not in MusicBrainz" is the right answer.
              const Divider(height: AriaSpace.s4),
              _localRow(context),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _localRow(BuildContext context) {
    final c = AriaColors.of(context);
    return InkWell(
      onTap: _useMyTags,
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
              // Not a free action: rebuilding it costs MusicBrainz round-trips.
              'Drops this album\u2019s MusicBrainz data. Your files are untouched.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.fgDim),
            ),
          ],
        ),
      ),
    );
  }

  Widget _candidateRow(BuildContext context, AlbumCandidate cand) {
    final sub = [
      cand.artist,
      cand.date,
      cand.country,
      if (cand.trackCount != null) '${cand.trackCount} tracks',
    ].whereType<String>().join(' · ');
    return InkWell(
      onTap: () => _pick(cand),
      borderRadius: BorderRadius.circular(AriaRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AriaSpace.s3,
          vertical: AriaSpace.s2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(cand.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (sub.isNotEmpty)
              Text(
                sub,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }
}
