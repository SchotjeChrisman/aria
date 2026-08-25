import 'package:aria_api/aria_api.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/phosphor_icons.dart';

import '../../core/theme.dart';
import '../../widgets/art_image.dart';
import 'providers.dart';
import 'reidentify_dialog.dart';

// Metadata editor ported from legacy openEditor(): DB overrides layered over
// file tags + enrichment. Every field shows its original value; ↺ resets that
// one field. Save only PATCHes what actually differs from the current
// override state. Files are never touched.

enum EditorFieldKind { text, number, long, select }

class EditorField {
  const EditorField(this.key, this.label, [this.kind = EditorFieldKind.text]);

  final String key;
  final String label;
  final EditorFieldKind kind;
}

const _releaseTypes = ['Album', 'EP', 'Single', 'Live', 'Compilation'];

const albumEditorFields = [
  EditorField('album', 'Album title'),
  EditorField('albumArtist', 'Album artist'),
  EditorField('genre', 'Genre'),
  EditorField('year', 'Year', EditorFieldKind.number),
  EditorField('releaseType', 'Release type', EditorFieldKind.select),
  EditorField('label', 'Label'),
  EditorField('date', 'Release date'),
  EditorField('country', 'Country'),
  EditorField('blurb', 'Description', EditorFieldKind.long),
];

const trackEditorFields = [
  EditorField('title', 'Title'),
  EditorField('artist', 'Artist'),
  EditorField('album', 'Album'),
  EditorField('albumArtist', 'Album artist'),
  EditorField('genre', 'Genre'),
  EditorField('year', 'Year', EditorFieldKind.number),
  EditorField('trackNo', 'Track #', EditorFieldKind.number),
  EditorField('discNo', 'Disc #', EditorFieldKind.number),
  EditorField('composer', 'Composer'),
  EditorField('work', 'Work'),
  EditorField('movement', 'Movement'),
  EditorField('conductor', 'Conductor'),
  EditorField('orchestra', 'Orchestra'),
];

Future<void> showAlbumEditor(
  BuildContext context,
  WidgetRef ref,
  Album album,
) => _openEditor(
  context,
  ref,
  kind: 'album',
  key: album.id,
  title: 'Edit album — ${album.title}',
  fields: albumEditorFields,
  patch: (body) => ref.read(albumApiProvider).patchAlbum(album.id, body),
  onSaved: () {
    ref.invalidate(albumTracksProvider);
    ref.invalidate(albumInfoProvider(album.id));
  },
  onReidentify: (ctx) => showAlbumReidentify(ctx, ref, album),
  // Album editor only: the cover-art source picker row.
  artAlbumId: album.id,
  client: ref.read(albumApiProvider),
);

Future<void> showTrackEditor(
  BuildContext context,
  WidgetRef ref,
  Track track,
) => _openEditor(
  context,
  ref,
  kind: 'track',
  key: track.id,
  title: 'Edit track — ${track.title ?? ''}',
  fields: trackEditorFields,
  patch: (body) => ref.read(albumApiProvider).patchTrack(track.id, body),
  onSaved: () => ref.invalidate(albumTracksProvider),
);

Future<void> _openEditor(
  BuildContext context,
  WidgetRef ref, {
  required String kind,
  required String key,
  required String title,
  required List<EditorField> fields,
  required Future<Object?> Function(Map<String, dynamic> body) patch,
  required VoidCallback onSaved,
  void Function(BuildContext ctx)? onReidentify,
  String? artAlbumId,
  AriaClient? client,
}) async {
  Map<String, dynamic> original = {}, overrides = {};
  Map<String, dynamic>? source;
  try {
    final e = await ref.read(albumApiProvider).edits(kind, key);
    if (e != null) {
      original = e.original;
      overrides = e.overrides;
      source = e.source;
    }
  } catch (_) {
    // older server: originals unknown, editor still works
  }
  if (!context.mounted) return;
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => MetadataEditorDialog(
      title: title,
      fields: fields,
      original: original,
      overrides: overrides,
      source: source,
      patch: patch,
      onReidentify: onReidentify,
      artAlbumId: artAlbumId,
      client: client,
    ),
  );
  if (saved == true) onSaved();
}

class MetadataEditorDialog extends StatefulWidget {
  const MetadataEditorDialog({
    super.key,
    required this.title,
    required this.fields,
    required this.original,
    required this.overrides,
    required this.patch,
    this.source,
    this.onReidentify,
    this.artAlbumId,
    this.client,
  });

  final String title;
  final List<EditorField> fields;
  final Map<String, dynamic> original;
  final Map<String, dynamic> overrides;

  /// Provenance for the derived half of [original]; null when nothing derived
  /// is showing (never matched, still under review, or marked local).
  final Map<String, dynamic>? source;
  final Future<Object?> Function(Map<String, dynamic> body) patch;
  final void Function(BuildContext ctx)? onReidentify;

  /// Non-null only for the album editor: enables the cover-art source row.
  final String? artAlbumId;
  final AriaClient? client;

  @override
  State<MetadataEditorDialog> createState() => MetadataEditorDialogState();
}

class MetadataEditorDialogState extends State<MetadataEditorDialog> {
  late final Map<String, TextEditingController> _ctrls = {
    for (final f in widget.fields)
      f.key: TextEditingController(text: _initialText(f)),
  };
  String? _error;
  bool _busy = false;

  // Cover-art source picker (album editor only). _artSource is the chosen
  // override (null = default resolution); _origArtSource is its loaded value
  // so save only PATCHes on a real change. _artVersion busts the thumbnail
  // cache after an upload. _fileExists gates the File thumbnail (null = still
  // probing).
  // Captured eagerly in initState — NOT `late`, whose lazy init would read
  // _artSource *after* a thumbnail tap has mutated it and wrongly equal it.
  String? _artSource;
  String? _origArtSource;
  int? _artVersion;
  bool? _fileExists;

  @override
  void initState() {
    super.initState();
    _artSource = widget.overrides['artSource'] as String?;
    _origArtSource = _artSource;
    _artVersion = (widget.overrides['artVersion'] as num?)?.toInt();
    final id = widget.artAlbumId, client = widget.client;
    if (id != null && client != null) {
      client.artExists(id, 'file').then((exists) {
        if (mounted) setState(() => _fileExists = exists);
      }).catchError((_) {
        if (mounted) setState(() => _fileExists = false);
      });
    }
  }

  // Legacy: large remote text (blurb/bio) never prefills — override only.
  String _initialText(EditorField f) {
    final over = widget.overrides[f.key];
    final orig = widget.original[f.key];
    if (f.kind == EditorFieldKind.long) return over?.toString() ?? '';
    if (f.kind == EditorFieldKind.select) {
      return (over ?? orig ?? 'Album').toString();
    }
    return (over ?? orig ?? '').toString();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit(Map<String, dynamic> body) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.patch(body);
      if (mounted) Navigator.of(context).pop(true);
    } on AriaApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Save failed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Legacy save: per field compute the override it should end up with
  /// (null = none); blank or back-to-original clears it; only fields whose
  /// wanted override differs from the current one go in the PATCH body.
  void _save() {
    final body = <String, dynamic>{};
    for (final f in widget.fields) {
      final v = _ctrls[f.key]!.text.trim();
      final orig = widget.original[f.key];
      Object? want;
      if (v.isEmpty || v == (orig?.toString() ?? '')) {
        want = null;
      } else if (f.kind == EditorFieldKind.number) {
        if (!RegExp(r'^\d{1,4}$').hasMatch(v)) {
          setState(() => _error = '${f.label} must be a number.');
          return;
        }
        want = int.parse(v);
      } else {
        want = v;
      }
      final cur = widget.overrides.containsKey(f.key)
          ? widget.overrides[f.key]
          : null;
      if (want != cur) body[f.key] = want;
    }
    // Cover-art source: send only when it changed (null clears the override).
    if (widget.artAlbumId != null && _artSource != _origArtSource) {
      body['artSource'] = _artSource;
    }
    if (body.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }
    _submit(body);
  }

  void _clearAll() => _submit({for (final f in widget.fields) f.key: null});

  /// Custom cover: pick an image, upload it, then select the custom slot and
  /// refresh the thumbnails via the returned artVersion.
  Future<void> _pickCustom() async {
    final res = await FilePicker.platform
        .pickFiles(type: FileType.image, withData: true);
    if (res == null || res.files.isEmpty) return;
    final file = res.files.first;
    if (file.bytes == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final resp =
          await widget.client!.uploadArt(widget.artAlbumId!, file.bytes!, file.name);
      if (!mounted) return;
      setState(() {
        _artSource = 'custom';
        _artVersion = (resp['artVersion'] as num?)?.toInt() ?? _artVersion;
      });
    } on AriaApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Upload failed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reset(EditorField f) {
    final orig = widget.original[f.key];
    _ctrls[f.key]!.text = f.kind == EditorFieldKind.long
        ? ''
        : (orig?.toString() ??
            (f.kind == EditorFieldKind.select ? 'Album' : ''));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return AlertDialog(
      title: Text(
        widget.title,
        style: Theme.of(context).textTheme.titleMedium,
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
              if (widget.source != null) _sourceRow(context),
              if (widget.artAlbumId != null) _artRow(context),
              for (final f in widget.fields) _fieldRow(context, f),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: AriaSpace.s2),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.onReidentify != null)
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    final pageCtx = context;
                    Navigator.of(context).pop(false);
                    widget.onReidentify!(pageCtx);
                  },
            child: const Text('↻ Re-identify…'),
          ),
        TextButton(
          onPressed: _busy ? null : _clearAll,
          child: Text(
            'Clear all edits',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Saving…' : 'Save'),
        ),
      ],
      backgroundColor: c.bgRaised,
    );
  }

  /// One caption line naming the release the corrections came from. That is
  /// the whole UI cost of provenance: one object per entity, not per field —
  /// every corrected field on an album came from the same release, so a badge
  /// beside each of thirteen fields would be thirteen copies of one sentence.
  Widget _sourceRow(BuildContext context) {
    final src = widget.source!;
    final mbid = src['releaseMbid']?.toString() ?? '';
    final title = src['releaseTitle']?.toString() ?? '';
    final pinned = src['pinned'] == true;
    final what = title.isEmpty ? mbid : '\u201c$title\u201d';
    final verb = pinned ? 'Pinned to' : 'Matched to';
    final when = (src['decidedAt']?.toString() ?? '').split('T').first;
    return Padding(
      padding: const EdgeInsets.only(bottom: AriaSpace.s3),
      child: Tooltip(
        message: mbid.isEmpty ? '' : 'MusicBrainz release $mbid',
        child: Text(
          '$verb MusicBrainz release $what'
          '${when.isEmpty ? '' : ' \u00b7 $when'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }

  Widget _artRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AriaSpace.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Cover art', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: AriaSpace.s1),
          Row(
            children: [
              // File is disabled until the probe confirms embedded art exists.
              _artThumb(context, 'File', 'file', enabled: _fileExists == true),
              const SizedBox(width: AriaSpace.s2),
              _artThumb(context, 'API', 'api'),
              const SizedBox(width: AriaSpace.s2),
              _artThumb(context, 'Custom', 'custom'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _artThumb(
    BuildContext context,
    String label,
    String slot, {
    bool enabled = true,
  }) {
    final c = AriaColors.of(context);
    final selected = _artSource == slot;
    return Column(
      children: [
        GestureDetector(
          // Opaque: the thumbnail's whole 64px box is tappable even before the
          // art image paints (DecoratedBox/Image don't absorb hits on their own).
          behavior: HitTestBehavior.opaque,
          onTap: (!enabled || _busy)
              ? null
              : () {
                  if (slot == 'custom') {
                    _pickCustom();
                  } else {
                    setState(() => _artSource = slot);
                  }
                },
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AriaRadius.md),
                border: Border.all(
                  color: selected ? c.accent : Colors.transparent,
                  width: 2,
                ),
              ),
              child: ArtImage(
                key: ValueKey('art-$slot'),
                url: widget.client!
                    .artUrl(widget.artAlbumId!, source: slot, version: _artVersion),
                size: 64,
              ),
            ),
          ),
        ),
        const SizedBox(height: AriaSpace.s1),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: enabled ? c.fg : c.fgDim),
        ),
      ],
    );
  }

  Widget _fieldRow(BuildContext context, EditorField f) {
    final c = AriaColors.of(context);
    final orig = widget.original[f.key];
    final edited = widget.overrides.containsKey(f.key);
    // Large remote text: show size only, never the content (legacy).
    final origLabel = f.kind == EditorFieldKind.long
        ? (orig != null
              ? 'fetched text, ${orig.toString().length} chars'
              : 'none')
        : (orig != null && orig.toString().isNotEmpty
              ? orig.toString()
              : 'none');

    Widget input;
    if (f.kind == EditorFieldKind.select) {
      input = DropdownButtonFormField<String>(
        initialValue: _releaseTypes.contains(_ctrls[f.key]!.text)
            ? _ctrls[f.key]!.text
            : 'Album',
        items: [
          for (final v in _releaseTypes)
            DropdownMenuItem(value: v, child: Text(v)),
        ],
        onChanged: (v) => _ctrls[f.key]!.text = v ?? 'Album',
      );
    } else {
      input = TextField(
        controller: _ctrls[f.key],
        maxLines: f.kind == EditorFieldKind.long ? 4 : 1,
        maxLength: f.kind == EditorFieldKind.long ? null : 300,
        buildCounter:
            (
              context, {
              required currentLength,
              required isFocused,
              maxLength,
            }) => null,
        keyboardType:
            f.kind == EditorFieldKind.number ? TextInputType.number : null,
        decoration: InputDecoration(
          hintText: f.kind == EditorFieldKind.long
              ? (orig != null ? 'Override the fetched text…' : 'Write one…')
              : null,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AriaSpace.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(f.label, style: Theme.of(context).textTheme.labelMedium),
              if (edited) ...[
                const SizedBox(width: AriaSpace.s2),
                Text('edited', style: TextStyle(fontSize: 11, color: c.accent)),
              ],
            ],
          ),
          const SizedBox(height: AriaSpace.s1),
          input,
          Row(
            children: [
              Expanded(
                child: Text(
                  'Original: $origLabel',
                  style: TextStyle(fontSize: 11.5, color: c.fgDim),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(PhosphorIconsRegular.arrowCounterClockwise, size: 15),
                visualDensity: VisualDensity.compact,
                tooltip: f.kind == EditorFieldKind.long
                    ? 'Drop the override, back to the fetched text'
                    : 'Reset this field to the original',
                color: c.fgDim,
                onPressed: () => _reset(f),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
