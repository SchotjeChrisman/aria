import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'providers.dart';
import 'smart_filter.dart';

/// Legacy multiSelect(): chips for picks, searchable option list (shown while
/// the search box is focused or has text, capped at 200 hits — the search box
/// is how you narrow down), AND/OR toggle at 2+ picks. Mutates [state] in
/// place; the enclosing form owns saving.
class MultiSelectField extends ConsumerStatefulWidget {
  const MultiSelectField({
    super.key,
    required this.field,
    required this.label,
    required this.state,
  });

  final String field;
  final String label;
  final MultiSelectState state;

  @override
  ConsumerState<MultiSelectField> createState() => _MultiSelectFieldState();
}

class _MultiSelectFieldState extends ConsumerState<MultiSelectField> {
  final _search = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _search.addListener(_changed);
    _focus.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final st = widget.state;
    final options =
        ref.watch(smartFieldValuesProvider(widget.field)).value ??
        const <String>[];
    final q = _search.text.trim().toLowerCase();
    final showList = _focus.hasFocus || q.isNotEmpty;
    final hits = [
      for (final v in options)
        if (q.isEmpty || v.toLowerCase().contains(q)) v,
    ].take(200).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: AriaSpace.s1),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                focusNode: _focus,
                decoration: const InputDecoration(hintText: 'search…'),
              ),
            ),
            if (st.vals.length >= 2) ...[
              const SizedBox(width: AriaSpace.s2),
              DropdownButton<String>(
                value: st.mode,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'any', child: Text('match any (OR)')),
                  DropdownMenuItem(
                    value: 'all',
                    child: Text('match all (AND)'),
                  ),
                ],
                onChanged: (v) => setState(() => st.mode = v ?? 'any'),
              ),
            ],
          ],
        ),
        if (showList)
          Container(
            margin: const EdgeInsets.only(top: AriaSpace.s1),
            constraints: const BoxConstraints(maxHeight: 180),
            decoration: BoxDecoration(
              color: c.bgRaised,
              border: Border.all(color: c.line),
              borderRadius: BorderRadius.circular(AriaRadius.sm),
            ),
            child: hits.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(AriaSpace.s3),
                    child: Text('No matches', style: TextStyle(color: c.fgDim)),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: hits.length,
                    itemBuilder: (context, i) {
                      final v = hits[i];
                      final sel = st.vals.contains(v);
                      return InkWell(
                        onTap: () => setState(() {
                          sel ? st.vals.remove(v) : st.vals.add(v);
                        }),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AriaSpace.s3,
                            vertical: AriaSpace.s2,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  v,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: sel ? c.accent : c.fg,
                                  ),
                                ),
                              ),
                              if (sel)
                                Icon(Icons.check, size: 16, color: c.accent),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        if (st.vals.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AriaSpace.s2),
            child: Wrap(
              spacing: AriaSpace.s2,
              runSpacing: AriaSpace.s1,
              children: [
                for (final v in st.vals)
                  InputChip(
                    label: Text(v),
                    onDeleted: () => setState(() => st.vals.remove(v)),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
