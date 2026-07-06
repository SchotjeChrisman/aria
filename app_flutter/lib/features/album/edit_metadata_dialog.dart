import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'providers.dart';
import 'reidentify_dialog.dart';

// Metadata editor ported from legacy openEditor(): DB overrides layered over
// file tags + enrichment. Every field shows its original value; ↺ resets that
// one field. Save only PATCHes what actually differs from the current
// override state. Files are never touched.

enum _FieldKind { text, number, long, select }

class _Field {
  const _Field(this.key, this.label, [this.kind = _FieldKind.text]);

  final String key;
  final String label;
  final _FieldKind kind;
}

const _releaseTypes = ['Album', 'EP', 'Single', 'Live', 'Compilation'];

const _albumFields = [
  _Field('album', 'Album title'),
  _Field('albumArtist', 'Album artist'),
  _Field('genre', 'Genre'),
  _Field('year', 'Year', _FieldKind.number),
  _Field('releaseType', 'Release type', _FieldKind.select),
  _Field('label', 'Label'),
  _Field('date', 'Release date'),
  _Field('country', 'Country'),
  _Field('blurb', 'Description', _FieldKind.long),
];

const _trackFields = [
  _Field('title', 'Title'),
  _Field('artist', 'Artist'),
  _Field('album', 'Album'),
  _Field('albumArtist', 'Album artist'),
  _Field('genre', 'Genre'),
  _Field('year', 'Year', _FieldKind.number),
  _Field('trackNo', 'Track #', _FieldKind.number),
  _Field('discNo', 'Disc #', _FieldKind.number),
  _Field('composer', 'Composer'),
  _Field('work', 'Work'),
  _Field('movement', 'Movement'),
  _Field('conductor', 'Conductor'),
  _Field('orchestra', 'Orchestra'),
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
  fields: _albumFields,
  patch: (body) => ref.read(albumApiProvider).patchAlbum(album.id, body),
  onSaved: () {
    ref.invalidate(albumTracksProvider);
    ref.invalidate(albumInfoProvider(album.id));
  },
  onReidentify: (ctx) => showAlbumReidentify(ctx, ref, album),
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
  fields: _trackFields,
  patch: (body) => ref.read(albumApiProvider).patchTrack(track.id, body),
  onSaved: () => ref.invalidate(albumTracksProvider),
);

Future<void> _openEditor(
  BuildContext context,
  WidgetRef ref, {
  required String kind,
  required String key,
  required String title,
  required List<_Field> fields,
  required Future<Object?> Function(Map<String, dynamic> body) patch,
  required VoidCallback onSaved,
  void Function(BuildContext ctx)? onReidentify,
}) async {
  Map<String, dynamic> original = {}, overrides = {};
  try {
    final e = await ref.read(albumApiProvider).edits(kind, key);
    if (e != null) {
      original = e.original;
      overrides = e.overrides;
    }
  } catch (_) {
    // older server: originals unknown, editor still works
  }
  if (!context.mounted) return;
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _EditorDialog(
      title: title,
      fields: fields,
      original: original,
      overrides: overrides,
      patch: patch,
      onReidentify: onReidentify,
    ),
  );
  if (saved == true) onSaved();
}

class _EditorDialog extends StatefulWidget {
  const _EditorDialog({
    required this.title,
    required this.fields,
    required this.original,
    required this.overrides,
    required this.patch,
    this.onReidentify,
  });

  final String title;
  final List<_Field> fields;
  final Map<String, dynamic> original;
  final Map<String, dynamic> overrides;
  final Future<Object?> Function(Map<String, dynamic> body) patch;
  final void Function(BuildContext ctx)? onReidentify;

  @override
  State<_EditorDialog> createState() => _EditorDialogState();
}

class _EditorDialogState extends State<_EditorDialog> {
  late final Map<String, TextEditingController> _ctrls = {
    for (final f in widget.fields)
      f.key: TextEditingController(text: _initialText(f)),
  };
  String? _error;
  bool _busy = false;

  // Legacy: large remote text (blurb/bio) never prefills — override only.
  String _initialText(_Field f) {
    final over = widget.overrides[f.key];
    final orig = widget.original[f.key];
    if (f.kind == _FieldKind.long) return over?.toString() ?? '';
    if (f.kind == _FieldKind.select) {
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
      } else if (f.kind == _FieldKind.number) {
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
    if (body.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }
    _submit(body);
  }

  void _clearAll() => _submit({for (final f in widget.fields) f.key: null});

  void _reset(_Field f) {
    final orig = widget.original[f.key];
    _ctrls[f.key]!.text = f.kind == _FieldKind.long
        ? ''
        : (orig?.toString() ?? (f.kind == _FieldKind.select ? 'Album' : ''));
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

  Widget _fieldRow(BuildContext context, _Field f) {
    final c = AriaColors.of(context);
    final orig = widget.original[f.key];
    final edited = widget.overrides.containsKey(f.key);
    // Large remote text: show size only, never the content (legacy).
    final origLabel = f.kind == _FieldKind.long
        ? (orig != null
              ? 'fetched text, ${orig.toString().length} chars'
              : 'none')
        : (orig != null && orig.toString().isNotEmpty
              ? orig.toString()
              : 'none');

    Widget input;
    if (f.kind == _FieldKind.select) {
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
        maxLines: f.kind == _FieldKind.long ? 4 : 1,
        maxLength: f.kind == _FieldKind.long ? null : 300,
        buildCounter:
            (
              context, {
              required currentLength,
              required isFocused,
              maxLength,
            }) => null,
        keyboardType: f.kind == _FieldKind.number ? TextInputType.number : null,
        decoration: InputDecoration(
          hintText: f.kind == _FieldKind.long
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
                icon: const Icon(Icons.undo, size: 15),
                visualDensity: VisualDensity.compact,
                tooltip: f.kind == _FieldKind.long
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
