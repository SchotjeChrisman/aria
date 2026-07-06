import 'package:flutter/material.dart';

/// Legacy nameForm() as a dialog: resolves to a trimmed non-empty name, or
/// null on cancel.
Future<String?> promptName(
  BuildContext context, {
  required String title,
  String? initial,
  String placeholder = 'Name',
}) {
  // Not disposed: the dialog's exit animation outlives the returned future.
  final ctrl = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (context) {
      void submit() {
        final v = ctrl.text.trim();
        if (v.isEmpty) return;
        Navigator.of(context).pop(v);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 60,
          decoration: InputDecoration(hintText: placeholder, counterText: ''),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: submit, child: const Text('Save')),
        ],
      );
    },
  );
}
