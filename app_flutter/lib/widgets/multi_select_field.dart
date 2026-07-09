import 'package:flutter/material.dart';

import '../core/theme.dart';

// Shared filter primitives for the library Tracks filter and the smart-playlist
// editor — both render the same string multi-selects (legacy FILTER_STRINGS /
// multiSelect). The two forms differ in what they DO with the picks (live
// client-side filtering vs. serialized server rules), so only the UI pieces and
// field list live here.

/// The string multi-select fields, in display order.
const filterStringFields = <(String, String)>[
  ('albumArtist', 'Primary artist'),
  ('credited', 'Performer'), // artist + conductor + orchestra + performers
  ('genre', 'Genre'),
  ('tag', 'Tag'),
  ('composer', 'Composer'),
  ('format', 'Format'),
];

const releaseTypes = ['Album', 'EP', 'Single', 'Compilation', 'Live'];

/// One multi-select's mutable draft: picked values plus any/all combinator.
/// The enclosing form owns persisting/serializing it.
class MultiSelectState {
  MultiSelectState({List<String>? vals, this.mode = 'any'}) : vals = [...?vals];

  final List<String> vals;
  String mode; // any = OR, all = AND
}

/// Legacy multiSelect(): chips for picks, a searchable option list (shown while
/// the search box is focused or has text, capped at 200 hits — the search box
/// is how you narrow down), AND/OR toggle at 2+ picks. Mutates [state] in place;
/// [options] is resolved by the caller so the widget stays provider-agnostic.
class MultiSelectField extends StatefulWidget {
  const MultiSelectField({
    super.key,
    required this.label,
    required this.options,
    required this.state,
  });

  final String label;
  final List<String> options;
  final MultiSelectState state;

  @override
  State<MultiSelectField> createState() => _MultiSelectFieldState();
}

class _MultiSelectFieldState extends State<MultiSelectField> {
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
    final q = _search.text.trim().toLowerCase();
    // Focus alone drives visibility: typing implies focus, and leftover search
    // text must not pin the list open after focus leaves (it blocked the next
    // field). onTapOutside below closes it reliably across platforms.
    final showList = _focus.hasFocus;
    final hits = [
      for (final v in widget.options)
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
                onTapOutside: (_) => _focus.unfocus(),
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
