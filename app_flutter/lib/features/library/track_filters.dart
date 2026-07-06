import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import 'album_filters.dart';
import 'library_providers.dart';

// The Tracks-view rich filter (legacy view.filters + openFilterDialog):
// artist / album-artist / credited / genre / tag / composer / format
// multi-selects with AND-OR modes, year range, lossless/lossy, release
// type, played/never-played, added-within-days.

/// One multi-select: values + match mode (legacy multiSelect state).
@immutable
class MultiFilter {
  const MultiFilter({this.vals = const [], this.mode = 'any'});

  final List<String> vals;
  final String mode; // any (OR) | all (AND)

  bool get isActive => vals.isNotEmpty;
}

/// Legacy FILTER_STRINGS order.
const trackFilterStringFields = [
  ('artist', 'Artist'),
  ('albumArtist', 'Album artist'),
  ('credited', 'Credited artist'),
  ('genre', 'Genre'),
  ('tag', 'Tag'),
  ('composer', 'Composer'),
  ('format', 'Format'),
];

const releaseTypes = ['Album', 'EP', 'Single', 'Compilation', 'Live'];

@immutable
class TrackFilters {
  const TrackFilters({
    this.strings = const {},
    this.yearFrom,
    this.yearTo,
    this.lossless,
    this.type,
    this.played,
    this.added,
  });

  /// field -> MultiFilter, only active fields present.
  final Map<String, MultiFilter> strings;
  final int? yearFrom;
  final int? yearTo;

  /// 'true' = lossless only, 'false' = lossy only, null = any.
  final String? lossless;
  final String? type;

  /// 'played' | 'never' | null.
  final String? played;

  /// Added within the last N days.
  final int? added;

  MultiFilter stringFilter(String field) =>
      strings[field] ?? const MultiFilter();

  /// Legacy activeFilterCount(): one per active group, for the badge.
  int get activeCount {
    var n = strings.values.where((f) => f.isActive).length;
    if (yearFrom != null || yearTo != null) n++;
    for (final v in [lossless, type, played, added]) {
      if (v != null) n++;
    }
    return n;
  }

  bool get isEmpty => activeCount == 0;
}

class TrackFiltersNotifier extends Notifier<TrackFilters> {
  @override
  TrackFilters build() => const TrackFilters();

  void apply(TrackFilters f) => state = f;
  void clear() => state = const TrackFilters();
}

final trackFiltersProvider =
    NotifierProvider<TrackFiltersNotifier, TrackFilters>(
      TrackFiltersNotifier.new,
    );

// ------------------------------------------------------------- matching

/// Legacy msPass: any = OR, all = AND; contains-match, except [exact]
/// (genre/tag: 'Pop' must not substring-match 'Pop Rock').
bool _msPass(MultiFilter f, Iterable<String?> values, {bool exact = false}) {
  if (f.vals.isEmpty) return true;
  final vs = [
    for (final v in values)
      if (v != null && v.isNotEmpty) v.toLowerCase(),
  ];
  bool one(String q) {
    final ql = q.toLowerCase();
    return exact ? vs.contains(ql) : vs.any((v) => v.contains(ql));
  }

  return f.mode == 'all' ? f.vals.every(one) : f.vals.any(one);
}

/// Legacy trackPassesFilters(). [playCounts] null = counts not loaded yet:
/// the played filter passes everything until they land (legacy).
bool trackPassesFilters(
  Track t,
  TrackFilters f, {
  required Map<String, String?> genreParents,
  required TagNameIndex tagIndex,
  Map<String, int>? playCounts,
}) {
  if (f.isEmpty) return true;
  if (!_msPass(f.stringFilter('artist'), [t.artist])) return false;
  if (!_msPass(f.stringFilter('albumArtist'), [t.albumArtist])) return false;
  if (!_msPass(f.stringFilter('credited'), [
    t.artist,
    t.conductor,
    t.orchestra,
    ...t.performers.map((p) => p.name),
  ])) {
    return false;
  }
  if (!_msPass(
    f.stringFilter('genre'),
    trackGenresUp(t, genreParents),
    exact: true,
  )) {
    return false;
  }
  if (!_msPass(f.stringFilter('tag'), tagIndex.namesFor(t), exact: true)) {
    return false;
  }
  if (!_msPass(f.stringFilter('composer'), [t.composer])) return false;
  if (!_msPass(f.stringFilter('format'), [t.format])) return false;
  if (f.yearFrom != null && !((t.year ?? -1) >= f.yearFrom!)) return false;
  if (f.yearTo != null && !((t.year ?? 1 << 31) <= f.yearTo!)) return false;
  if (f.lossless != null && (f.lossless == 'true') != t.lossless) return false;
  if (f.type != null && (t.releaseType ?? '') != f.type) return false;
  if (f.played != null && playCounts != null) {
    final played = (playCounts[t.id] ?? 0) > 0;
    if ((f.played == 'played') != played) return false;
  }
  final within = f.added;
  if (within != null && within > 0) {
    final at = t.addedAt == null ? null : DateTime.tryParse(t.addedAt!);
    if (at == null ||
        at.isBefore(DateTime.now().subtract(Duration(days: within)))) {
      return false;
    }
  }
  return true;
}

// --------------------------------------------------------- option lists

/// Distinct values per string field, from the loaded library.
final trackFilterOptionsProvider = Provider.family<List<String>, String>((
  ref,
  field,
) {
  switch (field) {
    case 'genre':
      return ref.watch(genreOptionsProvider);
    case 'tag':
      return ref.watch(tagOptionsProvider);
    case 'format':
      return ref.watch(formatOptionsProvider);
  }
  final tracks = ref.watch(loadedTracksProvider);
  final vals = <String>{};
  for (final t in tracks) {
    switch (field) {
      case 'artist':
        if ((t.artist ?? '').isNotEmpty) vals.add(t.artist!);
      case 'albumArtist':
        if ((t.albumArtist ?? '').isNotEmpty) vals.add(t.albumArtist!);
      case 'composer':
        if ((t.composer ?? '').isNotEmpty) vals.add(t.composer!);
      case 'credited':
        for (final v in [
          t.artist,
          t.conductor,
          t.orchestra,
          ...t.performers.map((p) => p.name),
        ]) {
          if (v != null && v.isNotEmpty) vals.add(v);
        }
    }
  }
  return vals.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
});

// ---------------------------------------------------------------- dialog

/// Legacy openFilterDialog: edit a draft, Apply/Clear/Cancel.
Future<void> showTrackFilterDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _FilterDialog());

class _FilterDialog extends ConsumerStatefulWidget {
  const _FilterDialog();

  @override
  ConsumerState<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends ConsumerState<_FilterDialog> {
  late final Map<String, List<String>> _vals;
  late final Map<String, String> _modes;
  late final TextEditingController _yearFrom;
  late final TextEditingController _yearTo;
  late final TextEditingController _added;
  String? _lossless;
  String? _type;
  String? _played;

  @override
  void initState() {
    super.initState();
    final f = ref.read(trackFiltersProvider);
    _vals = {
      for (final (field, _) in trackFilterStringFields)
        field: [...f.stringFilter(field).vals],
    };
    _modes = {
      for (final (field, _) in trackFilterStringFields)
        field: f.stringFilter(field).mode,
    };
    _yearFrom = TextEditingController(text: f.yearFrom?.toString() ?? '');
    _yearTo = TextEditingController(text: f.yearTo?.toString() ?? '');
    _added = TextEditingController(text: f.added?.toString() ?? '');
    _lossless = f.lossless;
    _type = f.type;
    _played = f.played;
  }

  @override
  void dispose() {
    _yearFrom.dispose();
    _yearTo.dispose();
    _added.dispose();
    super.dispose();
  }

  int? _num(TextEditingController c) => int.tryParse(c.text.trim());

  void _apply() {
    ref
        .read(trackFiltersProvider.notifier)
        .apply(
          TrackFilters(
            strings: {
              for (final (field, _) in trackFilterStringFields)
                if (_vals[field]!.isNotEmpty)
                  field: MultiFilter(vals: _vals[field]!, mode: _modes[field]!),
            },
            yearFrom: _num(_yearFrom),
            yearTo: _num(_yearTo),
            lossless: _lossless,
            type: _type,
            played: _played,
            added: _num(_added),
          ),
        );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);

    Widget label(String s) => Padding(
      padding: const EdgeInsets.only(top: AriaSpace.s4, bottom: AriaSpace.s1),
      child: Text(s, style: Theme.of(context).textTheme.labelMedium),
    );

    Widget dropdown(
      String? value,
      List<(String, String)> options,
      ValueChanged<String?> onChanged,
    ) => DropdownButton<String?>(
      value: value,
      isExpanded: true,
      underline: const SizedBox.shrink(),
      dropdownColor: c.bgRaised,
      items: [
        const DropdownMenuItem(child: Text('Any')),
        for (final (v, l) in options)
          DropdownMenuItem(value: v, child: Text(l)),
      ],
      onChanged: (v) => setState(() => onChanged(v)),
    );

    return AlertDialog(
      title: const Text('Filters'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (field, fieldLabel) in trackFilterStringFields) ...[
                label(fieldLabel),
                _MultiSelectField(
                  options: ref.watch(trackFilterOptionsProvider(field)),
                  vals: _vals[field]!,
                  mode: _modes[field]!,
                  onModeChanged: (m) => setState(() => _modes[field] = m),
                  onChanged: () => setState(() {}),
                ),
              ],
              label('Year'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _yearFrom,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: 'from'),
                    ),
                  ),
                  const SizedBox(width: AriaSpace.s3),
                  Expanded(
                    child: TextField(
                      controller: _yearTo,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(hintText: 'to'),
                    ),
                  ),
                ],
              ),
              label('Quality'),
              dropdown(_lossless, const [
                ('true', 'Lossless'),
                ('false', 'Lossy'),
              ], (v) => _lossless = v),
              label('Release type'),
              dropdown(_type, [
                for (final t in releaseTypes) (t, t),
              ], (v) => _type = v),
              label('Played'),
              dropdown(_played, const [
                ('played', 'Played'),
                ('never', 'Never played'),
              ], (v) => _played = v),
              label('Added (days)'),
              TextField(
                controller: _added,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: 'e.g. 30'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            ref.read(trackFiltersProvider.notifier).clear();
            Navigator.of(context).pop();
          },
          child: const Text('Clear'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _apply, child: const Text('Apply')),
      ],
    );
  }
}

/// Legacy multiSelect(): search box narrows the option list; picked values
/// become chips; AND/OR toggle appears at 2+ picks. Mutates [vals] in place.
class _MultiSelectField extends StatefulWidget {
  const _MultiSelectField({
    required this.options,
    required this.vals,
    required this.mode,
    required this.onModeChanged,
    required this.onChanged,
  });

  final List<String> options;
  final List<String> vals;
  final String mode;
  final ValueChanged<String> onModeChanged;
  final VoidCallback onChanged;

  @override
  State<_MultiSelectField> createState() => _MultiSelectFieldState();
}

class _MultiSelectFieldState extends State<_MultiSelectField> {
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
    final q = _search.text.trim().toLowerCase();
    final showList = _focus.hasFocus || q.isNotEmpty;
    final hits = [
      for (final v in widget.options)
        if (q.isEmpty || v.toLowerCase().contains(q)) v,
    ].take(200).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                focusNode: _focus,
                decoration: const InputDecoration(hintText: 'search…'),
              ),
            ),
            if (widget.vals.length >= 2) ...[
              const SizedBox(width: AriaSpace.s2),
              DropdownButton<String>(
                value: widget.mode,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'any', child: Text('match any (OR)')),
                  DropdownMenuItem(
                    value: 'all',
                    child: Text('match all (AND)'),
                  ),
                ],
                onChanged: (v) => widget.onModeChanged(v ?? 'any'),
              ),
            ],
          ],
        ),
        if (showList)
          Container(
            margin: const EdgeInsets.only(top: AriaSpace.s1),
            constraints: const BoxConstraints(maxHeight: 160),
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
                      final sel = widget.vals.contains(v);
                      return InkWell(
                        onTap: () {
                          sel ? widget.vals.remove(v) : widget.vals.add(v);
                          widget.onChanged();
                        },
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
        if (widget.vals.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AriaSpace.s2),
            child: Wrap(
              spacing: AriaSpace.s2,
              runSpacing: AriaSpace.s1,
              children: [
                for (final v in widget.vals)
                  InputChip(
                    label: Text(v),
                    onDeleted: () {
                      widget.vals.remove(v);
                      widget.onChanged();
                    },
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
