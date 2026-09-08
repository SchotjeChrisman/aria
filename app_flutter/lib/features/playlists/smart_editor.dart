import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../widgets/filter_form.dart';
import '../../widgets/multi_select_field.dart';
import '../library/track_filters.dart' show trackFilterOptionsProvider;
import 'providers.dart';
import 'smart_filter.dart';

/// Legacy openSmartEditor(): pass null to create, a smart playlist to edit.
Future<void> showSmartEditor(BuildContext context, {Playlist? playlist}) =>
    showDialog(
      context: context,
      builder: (_) => SmartEditorDialog(playlist: playlist),
    );

class SmartEditorDialog extends ConsumerStatefulWidget {
  const SmartEditorDialog({super.key, this.playlist});

  final Playlist? playlist;

  @override
  ConsumerState<SmartEditorDialog> createState() => SmartEditorDialogState();
}

class SmartEditorDialogState extends ConsumerState<SmartEditorDialog> {
  late final FilterDraft _draft = rulesToState(widget.playlist?.rules);
  late final _name = TextEditingController(text: widget.playlist?.name ?? '');
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _error = null);
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Name required.');
      return;
    }
    final r = stateToRules(_draft);
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
              Flexible(
                child: SingleChildScrollView(
                  child: FilterForm(
                    draft: _draft,
                    options: {
                      for (final (field, _) in filterStringFields)
                        field: ref.watch(trackFilterOptionsProvider(field)),
                    },
                  ),
                ),
              ),
              const SizedBox(height: AriaSpace.s4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _error ?? '',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
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
}
