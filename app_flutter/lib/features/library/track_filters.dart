import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/filter_form.dart';
import '../../widgets/multi_select_field.dart';
import 'album_filters.dart';
import 'library_providers.dart';

// The Tracks-view rich filter (legacy view.filters + openFilterDialog). The
// form is widgets/filter_form.dart, shared with the smart-playlist editor, so
// the two offer exactly the same rows; this file holds the immutable applied
// state and the client-side matching the smart editor delegates to the server.

/// One multi-select: values + match mode (legacy multiSelect state).
@immutable
class MultiFilter {
  const MultiFilter({this.vals = const [], this.mode = 'any'});

  final List<String> vals;
  final String mode; // any (OR) | all (AND)

  bool get isActive => vals.isNotEmpty;
}

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
    this.favourites = false,
    this.combine = 'all',
    this.minSampleRate,
    this.minBits,
    this.loudnessFrom,
    this.loudnessTo,
    this.minDynamicRange,
    this.suspect,
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

  /// Favourites-only (the reserved ♥ metatag).
  final bool favourites;

  /// Cross-field combine mode: 'all' = every active field (AND, default),
  /// 'any' = at least one active field (OR).
  final String combine;

  // Measured off the decoded audio by the server's analysis pass. A track it
  // has not decoded matches none of these — not even `quieter than`, because
  // a missing measurement must fail a comparison, not read as 0. Same rule the
  // server applies to the identical smart-playlist rules.
  final int? minSampleRate; // Hz
  final int? minBits;
  final double? loudnessFrom; // LUFS: louder than this
  final double? loudnessTo; // LUFS: quieter than this
  final double? minDynamicRange; // LU

  /// 'true' = transcodes only, 'false' = exclude transcodes, null = any.
  final String? suspect;

  MultiFilter stringFilter(String field) =>
      strings[field] ?? const MultiFilter();

  /// Legacy activeFilterCount(): one per active group, for the badge.
  int get activeCount {
    var n = strings.values.where((f) => f.isActive).length;
    if (yearFrom != null || yearTo != null) n++;
    for (final v in [
      lossless,
      type,
      played,
      added,
      minSampleRate,
      minBits,
      loudnessFrom,
      loudnessTo,
      minDynamicRange,
      suspect,
    ]) {
      if (v != null) n++;
    }
    if (favourites) n++;
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
  required Set<String> favouriteIds,
  Map<String, int>? playCounts,
}) {
  if (f.isEmpty) return true;

  // Evaluate each ACTIVE field to a bool, then combine: 'all' = every active
  // field must pass (AND), 'any' = at least one active field passes (OR).
  // Inactive fields don't count toward the 'any' OR.
  final results = <bool>[];

  if (f.favourites) results.add(favouriteIds.contains(t.id));
  if (f.stringFilter('albumArtist').isActive) {
    results.add(_msPass(f.stringFilter('albumArtist'), [t.albumArtist]));
  }
  if (f.stringFilter('credited').isActive) {
    results.add(
      _msPass(f.stringFilter('credited'), [
        t.artist,
        t.conductor,
        t.orchestra,
        ...t.performers.map((p) => p.name),
      ]),
    );
  }
  if (f.stringFilter('genre').isActive) {
    results.add(
      _msPass(
        f.stringFilter('genre'),
        trackGenresUp(t, genreParents),
        exact: true,
      ),
    );
  }
  if (f.stringFilter('tag').isActive) {
    results.add(
      _msPass(f.stringFilter('tag'), tagIndex.namesFor(t), exact: true),
    );
  }
  if (f.stringFilter('composer').isActive) {
    results.add(_msPass(f.stringFilter('composer'), [t.composer]));
  }
  if (f.stringFilter('format').isActive) {
    results.add(_msPass(f.stringFilter('format'), [t.format]));
  }
  if (f.yearFrom != null) results.add((t.year ?? -1) >= f.yearFrom!);
  if (f.yearTo != null) results.add((t.year ?? 1 << 31) <= f.yearTo!);
  if (f.lossless != null) results.add((f.lossless == 'true') == t.lossless);
  if (f.type != null) results.add((t.releaseType ?? '') == f.type);
  if (f.played != null && playCounts != null) {
    final played = (playCounts[t.id] ?? 0) > 0;
    results.add((f.played == 'played') == played);
  }
  // The quality rows, matched exactly as the server matches the same smart
  // rules: `>= min` (its `gt min - 1`), strict gt/lt on the continuous ones,
  // and a null measurement fails every one of them.
  if (f.minSampleRate != null) {
    results.add((t.sampleRate ?? -1) >= f.minSampleRate!);
  }
  if (f.minBits != null) results.add((t.bitsPerSample ?? -1) >= f.minBits!);
  if (f.loudnessFrom != null) {
    final v = t.loudnessLufs;
    results.add(v != null && v > f.loudnessFrom!);
  }
  if (f.loudnessTo != null) {
    final v = t.loudnessLufs;
    results.add(v != null && v < f.loudnessTo!);
  }
  if (f.minDynamicRange != null) {
    final v = t.dynamicRangeLu;
    results.add(v != null && v > f.minDynamicRange!);
  }
  if (f.suspect != null) results.add(t.suspect == (f.suspect == 'true'));
  final within = f.added;
  if (within != null && within > 0) {
    final at = t.addedAt == null ? null : DateTime.tryParse(t.addedAt!);
    results.add(
      at != null &&
          !at.isBefore(DateTime.now().subtract(Duration(days: within))),
    );
  }

  // No active field evaluated (e.g. played filter with counts unloaded) passes.
  if (results.isEmpty) return true;
  return f.combine == 'any' ? results.any((r) => r) : results.every((r) => r);
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

/// Applied filters -> an editable draft of the shared form.
FilterDraft draftOf(TrackFilters f) {
  final d = FilterDraft()
    ..match = f.combine
    ..favourites = f.favourites
    ..yearFrom = f.yearFrom
    ..yearTo = f.yearTo
    ..lossless = f.lossless
    ..releaseType = f.type
    ..played = f.played
    ..addedDays = f.added
    ..minSampleRate = f.minSampleRate
    ..minBits = f.minBits
    ..loudnessFrom = f.loudnessFrom
    ..loudnessTo = f.loudnessTo
    ..minDynamicRange = f.minDynamicRange
    ..suspect = f.suspect;
  for (final (field, _) in filterStringFields) {
    final mf = f.stringFilter(field);
    d.strings[field]!
      ..vals.addAll(mf.vals)
      ..mode = mf.mode;
  }
  return d;
}

/// The draft back to applied filters. The smart editor's stateToRules() is
/// this function's opposite number: same draft, different destination.
TrackFilters filtersOf(FilterDraft d) => TrackFilters(
  strings: {
    for (final (field, _) in filterStringFields)
      if (d.strings[field]!.vals.isNotEmpty)
        field: MultiFilter(
          vals: List.of(d.strings[field]!.vals),
          mode: d.strings[field]!.mode,
        ),
  },
  yearFrom: d.yearFrom,
  yearTo: d.yearTo,
  lossless: d.lossless,
  type: d.releaseType,
  played: d.played,
  added: d.addedDays,
  favourites: d.favourites,
  combine: d.match,
  minSampleRate: d.minSampleRate,
  minBits: d.minBits,
  loudnessFrom: d.loudnessFrom,
  loudnessTo: d.loudnessTo,
  minDynamicRange: d.minDynamicRange,
  suspect: d.suspect,
);

/// Legacy openFilterDialog: edit a draft, Apply/Clear/Cancel.
Future<void> showTrackFilterDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const TrackFilterDialog(),
);

class TrackFilterDialog extends ConsumerStatefulWidget {
  const TrackFilterDialog({super.key});

  @override
  ConsumerState<TrackFilterDialog> createState() => TrackFilterDialogState();
}

class TrackFilterDialogState extends ConsumerState<TrackFilterDialog> {
  late final FilterDraft _draft = draftOf(ref.read(trackFiltersProvider));

  void _apply() {
    ref.read(trackFiltersProvider.notifier).apply(filtersOf(_draft));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Filters'),
      content: SizedBox(
        width: 480,
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
