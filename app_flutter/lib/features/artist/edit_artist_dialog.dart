import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/phosphor_icons.dart';

import '../../core/theme.dart';
import 'providers.dart';

// Artist metadata editor, ported from legacy openEditor('artist', …): DB
// overrides over enrichment. Fields: type, area, born, died, image URL
// (with live preview), biography (override-only, never prefilled).
// GAP: near-duplicate of the album feature's editor — a shared editor widget
// in lib/widgets would remove both copies.

const _fields = [
  ('type', 'Type'),
  ('area', 'Area'),
  ('born', 'Born'),
  ('died', 'Died'),
  ('image', 'Image URL'),
  ('bio', 'Biography'),
];

Future<void> showArtistEditor(
  BuildContext context,
  WidgetRef ref,
  String name,
) async {
  Map<String, dynamic> original = {}, overrides = {};
  try {
    final e = await ref.read(artistApiProvider).edits('artist', name);
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
    builder: (_) => _ArtistEditorDialog(
      name: name,
      original: original,
      overrides: overrides,
      patch: (body) => ref.read(artistApiProvider).patchArtist(name, body),
    ),
  );
  if (saved == true) {
    // person data comes from the artist endpoints, not the library (legacy)
    ref.invalidate(artistInfoProvider(name));
    ref.invalidate(artistPeopleProvider);
  }
}

class _ArtistEditorDialog extends StatefulWidget {
  const _ArtistEditorDialog({
    required this.name,
    required this.original,
    required this.overrides,
    required this.patch,
  });

  final String name;
  final Map<String, dynamic> original;
  final Map<String, dynamic> overrides;
  final Future<Object?> Function(Map<String, dynamic> body) patch;

  @override
  State<_ArtistEditorDialog> createState() => _ArtistEditorDialogState();
}

class _ArtistEditorDialogState extends State<_ArtistEditorDialog> {
  late final Map<String, TextEditingController> _ctrls = {
    for (final (f, _) in _fields)
      f: TextEditingController(
        // bio is large remote text: override only, never prefilled (legacy)
        text: f == 'bio'
            ? (widget.overrides[f]?.toString() ?? '')
            : (widget.overrides[f] ?? widget.original[f] ?? '').toString(),
      ),
  };
  String? _error;
  bool _busy = false;

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

  void _save() {
    final body = <String, dynamic>{};
    for (final (f, _) in _fields) {
      final v = _ctrls[f]!.text.trim();
      final orig = widget.original[f];
      // blank or back-to-original clears the override (legacy)
      final Object? want = (v.isEmpty || v == (orig?.toString() ?? ''))
          ? null
          : v;
      final cur = widget.overrides.containsKey(f) ? widget.overrides[f] : null;
      if (want != cur) body[f] = want;
    }
    if (body.isEmpty) {
      Navigator.of(context).pop(false);
      return;
    }
    _submit(body);
  }

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return AlertDialog(
      backgroundColor: c.bgRaised,
      title: Text(
        'Edit artist — ${widget.name}',
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
              for (final (f, label) in _fields) _fieldRow(context, f, label),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => _submit({for (final (f, _) in _fields) f: null}),
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
    );
  }

  Widget _fieldRow(BuildContext context, String f, String label) {
    final c = AriaColors.of(context);
    final orig = widget.original[f];
    final edited = widget.overrides.containsKey(f);
    final long = f == 'bio';
    final origLabel = long
        ? (orig != null
              ? 'fetched text, ${orig.toString().length} chars'
              : 'none')
        : (orig != null && orig.toString().isNotEmpty
              ? orig.toString()
              : 'none');

    return Padding(
      padding: const EdgeInsets.only(bottom: AriaSpace.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              if (edited) ...[
                const SizedBox(width: AriaSpace.s2),
                Text('edited', style: TextStyle(fontSize: 11, color: c.accent)),
              ],
            ],
          ),
          const SizedBox(height: AriaSpace.s1),
          TextField(
            controller: _ctrls[f],
            maxLines: long ? 4 : 1,
            onChanged: f == 'image' ? (_) => setState(() {}) : null,
            decoration: InputDecoration(
              hintText: long
                  ? (orig != null ? 'Override the fetched text…' : 'Write one…')
                  : null,
            ),
          ),
          if (f == 'image') _imagePreview(context, orig?.toString()),
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
                tooltip: long
                    ? 'Drop the override, back to the fetched text'
                    : 'Reset this field to the original',
                color: c.fgDim,
                onPressed: () {
                  _ctrls[f]!.text = long ? '' : (orig?.toString() ?? '');
                  setState(() {});
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Live preview of the entered URL next to the original portrait (legacy).
  Widget _imagePreview(BuildContext context, String? orig) {
    final c = AriaColors.of(context);
    final cur = _ctrls['image']!.text.trim();
    Widget fig(String src, String cap) => Padding(
      padding: const EdgeInsets.only(right: AriaSpace.s3, top: AriaSpace.s2),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AriaRadius.sm),
            child: Image.network(
              src,
              width: 84,
              height: 84,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          Text(cap, style: TextStyle(fontSize: 11, color: c.fgDim)),
        ],
      ),
    );
    return Row(
      children: [
        if (cur.isNotEmpty && cur != orig) fig(cur, 'New'),
        if (orig != null && orig.isNotEmpty) fig(orig, 'Original'),
      ],
    );
  }
}
