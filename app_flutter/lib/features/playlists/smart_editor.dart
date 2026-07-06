import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'multi_select.dart';
import 'providers.dart';
import 'smart_filter.dart';

/// Legacy openSmartEditor(): pass null to create, a smart playlist to edit.
Future<void> showSmartEditor(BuildContext context, {Playlist? playlist}) =>
    showDialog(
      context: context,
      builder: (_) => _SmartEditorDialog(playlist: playlist),
    );

class _SmartEditorDialog extends ConsumerStatefulWidget {
  const _SmartEditorDialog({this.playlist});

  final Playlist? playlist;

  @override
  ConsumerState<_SmartEditorDialog> createState() => _SmartEditorDialogState();
}

class _SmartEditorDialogState extends ConsumerState<_SmartEditorDialog> {
  late final SmartFilterState _st = rulesToState(widget.playlist?.rules);
  late final _name = TextEditingController(text: widget.playlist?.name ?? '');
  late final _yearFrom = TextEditingController(
    text: _st.yearFrom?.toString() ?? '',
  );
  late final _yearTo = TextEditingController(
    text: _st.yearTo?.toString() ?? '',
  );
  late final _added = TextEditingController(
    text: _st.addedDays?.toString() ?? '',
  );
  late String _match = widget.playlist?.rules?.match ?? 'all';
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _yearFrom.dispose();
    _yearTo.dispose();
    _added.dispose();
    super.dispose();
  }

  // Legacy applyScalarFilters(): read scalar inputs back into the state.
  void _applyScalars() {
    int? numVal(TextEditingController c) => int.tryParse(c.text.trim());
    _st.yearFrom = numVal(_yearFrom);
    _st.yearTo = numVal(_yearTo);
    _st.addedDays = numVal(_added);
    // lossless / releaseType / played bind to _st directly via the dropdowns.
  }

  Future<void> _save() async {
    setState(() => _error = null);
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Name required.');
      return;
    }
    _applyScalars();
    final r = stateToRules(_st, _match);
    if (r.error != null) {
      setState(() => _error = r.error);
      return;
    }
    setState(() => _saving = true);
    try {
      final n = ref.read(playlistsProvider.notifier);
      final editing = widget.playlist;
      if (editing != null) {
        await n.updateSmart(editing.id, name: name, rules: r.rules!);
      } else {
        await n.createSmart(name, r.rules!);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e is AriaApiException ? e.message : 'Save failed.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(AriaSpace.s5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.playlist != null
                    ? 'Edit smart playlist'
                    : 'New smart playlist',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AriaSpace.s4),
              TextField(
                controller: _name,
                autofocus: widget.playlist == null,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  counterText: '',
                ),
              ),
              const SizedBox(height: AriaSpace.s3),
              Row(
                children: [
                  const Text('Match'),
                  const SizedBox(width: AriaSpace.s2),
                  DropdownButton<String>(
                    value: _match,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('all')),
                      DropdownMenuItem(value: 'any', child: Text('any')),
                    ],
                    onChanged: (v) => setState(() => _match = v ?? 'all'),
                  ),
                  const SizedBox(width: AriaSpace.s2),
                  const Text('of the following:'),
                ],
              ),
              const SizedBox(height: AriaSpace.s3),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (field, label) in filterStringFields) ...[
                        MultiSelectField(
                          field: field,
                          label: label,
                          state: _st.strings[field]!,
                        ),
                        const SizedBox(height: AriaSpace.s4),
                      ],
                      _row(
                        context,
                        'Year',
                        Row(
                          children: [
                            Expanded(child: _numField(_yearFrom, 'from')),
                            const SizedBox(width: AriaSpace.s2),
                            Expanded(child: _numField(_yearTo, 'to')),
                          ],
                        ),
                      ),
                      _row(
                        context,
                        'Quality',
                        _anySelect(
                          value: _st.lossless,
                          options: const [
                            ('true', 'Lossless'),
                            ('false', 'Lossy'),
                          ],
                          onChanged: (v) => setState(() => _st.lossless = v),
                        ),
                      ),
                      _row(
                        context,
                        'Release type',
                        _anySelect(
                          value: _st.releaseType,
                          options: [for (final t in releaseTypes) (t, t)],
                          onChanged: (v) => setState(() => _st.releaseType = v),
                        ),
                      ),
                      // Legacy: played/never only — no exact play-count UI.
                      _row(
                        context,
                        'Played',
                        _anySelect(
                          value: _st.played,
                          options: const [
                            ('played', 'Played'),
                            ('never', 'Never played'),
                          ],
                          onChanged: (v) => setState(() => _st.played = v),
                        ),
                      ),
                      _row(
                        context,
                        'Added (days)',
                        _numField(_added, 'e.g. 30'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AriaSpace.s4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _error ?? '',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: AriaSpace.s2),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : 'Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, Widget control) => Padding(
    padding: const EdgeInsets.only(bottom: AriaSpace.s4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: AriaSpace.s1),
        control,
      ],
    ),
  );

  Widget _numField(TextEditingController ctrl, String hint) => TextField(
    controller: ctrl,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(hintText: hint),
  );

  /// Scalar select with a leading "Any" (null) choice, like legacy sel().
  Widget _anySelect({
    required String? value,
    required List<(String, String)> options,
    required ValueChanged<String?> onChanged,
  }) => DropdownButton<String?>(
    value: value,
    isExpanded: true,
    underline: const SizedBox.shrink(),
    items: [
      const DropdownMenuItem<String?>(value: null, child: Text('Any')),
      for (final (v, l) in options)
        DropdownMenuItem<String?>(value: v, child: Text(l)),
    ],
    onChanged: onChanged,
  );
}
