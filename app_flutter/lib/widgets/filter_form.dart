import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'multi_select_field.dart';

// The one filter form. The library Tracks filter and the smart-playlist editor
// render THIS — they used to render two hand-kept copies that drifted (the
// editor grew the quality rows, the Tracks dialog grew Favourites, neither got
// the other's). What still differs is only what each does with the picks:
// Tracks matches the loaded library client-side, the editor serializes to
// server rules. Anything visible lives here, so it cannot diverge again.

/// The mutable draft both forms edit. Rows write into it as you type, so
/// there is no "collect the scalars" step left to forget on save.
class FilterDraft {
  FilterDraft()
    : strings = {
        for (final (f, _) in filterStringFields) f: MultiSelectState(),
      };

  /// field -> picked values + any/all mode.
  final Map<String, MultiSelectState> strings;

  /// Cross-field combine: 'all' = every active field (AND), 'any' = at least
  /// one (OR). Serializes to SmartRules.match.
  String match = 'all';

  bool favourites = false;
  int? yearFrom;
  int? yearTo;
  String? lossless; // 'true' | 'false' | null (Any)
  String? releaseType;
  String? played; // 'played' | 'never' | null (Any)
  int? addedDays;

  // Measured off the decoded audio by /api/analyze. A track the server has not
  // decoded matches none of these — not even `quieter than`, since a null must
  // fail every comparison rather than read as 0.
  int? minSampleRate; // Hz
  int? minBits;
  double? loudnessFrom; // LUFS: louder than this
  double? loudnessTo; // LUFS: quieter than this
  double? minDynamicRange; // LU
  String? suspect; // 'false' (exclude) | 'true' (only) | null (Any)
}

/// Every filter row, in order, editing [draft] in place. [options] holds the
/// multi-select option list per field — the caller resolves it, because the
/// two forms read it from different providers and a ref.watch cannot cross
/// into a child's build.
class FilterForm extends StatefulWidget {
  const FilterForm({super.key, required this.draft, required this.options});

  final FilterDraft draft;
  final Map<String, List<String>> options;

  @override
  State<FilterForm> createState() => _FilterFormState();
}

class _FilterFormState extends State<FilterForm> {
  Widget _row(String label, Widget control) => Padding(
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

  /// Writes straight through to the draft on every keystroke. signed+decimal:
  /// LUFS are negative and fractional.
  ///
  /// [initial] is READ ONCE — TextFormField ignores a changed initialValue on
  /// rebuild — which holds only because both dialogs create the draft in a
  /// `late final` and nothing else writes these fields. Anything that resets
  /// or reloads a draft in place has to key or control these fields, or they
  /// will show stale text while the draft says otherwise.
  Widget _numField(num? initial, String hint, ValueChanged<num?> onChanged) =>
      TextFormField(
        initialValue: initial?.toString() ?? '',
        keyboardType: const TextInputType.numberWithOptions(
          signed: true,
          decimal: true,
        ),
        decoration: InputDecoration(hintText: hint),
        onChanged: (s) => onChanged(num.tryParse(s.trim())),
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
    dropdownColor: AriaColors.of(context).bgRaised,
    items: [
      const DropdownMenuItem<String?>(value: null, child: Text('Any')),
      for (final (v, l) in options)
        DropdownMenuItem<String?>(value: v, child: Text(l)),
    ],
    onChanged: (v) => setState(() => onChanged(v)),
  );

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('Match all fields')),
              ButtonSegment(value: 'any', label: Text('Match any field')),
            ],
            selected: {d.match},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => d.match = s.first),
          ),
        ),
        const SizedBox(height: AriaSpace.s4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Favourites only'),
          value: d.favourites,
          onChanged: (v) => setState(() => d.favourites = v),
        ),
        for (final (field, label) in filterStringFields) ...[
          MultiSelectField(
            label: label,
            options: widget.options[field] ?? const [],
            state: d.strings[field]!,
          ),
          const SizedBox(height: AriaSpace.s4),
        ],
        _row(
          'Year',
          Row(
            children: [
              Expanded(
                child: _numField(
                  d.yearFrom,
                  'from',
                  (v) => d.yearFrom = v?.toInt(),
                ),
              ),
              const SizedBox(width: AriaSpace.s2),
              Expanded(
                child: _numField(d.yearTo, 'to', (v) => d.yearTo = v?.toInt()),
              ),
            ],
          ),
        ),
        _row(
          'Quality',
          _anySelect(
            value: d.lossless,
            options: const [('true', 'Lossless'), ('false', 'Lossy')],
            onChanged: (v) => d.lossless = v,
          ),
        ),
        _row(
          'Release type',
          _anySelect(
            value: d.releaseType,
            options: [for (final t in releaseTypes) (t, t)],
            onChanged: (v) => d.releaseType = v,
          ),
        ),
        // Legacy: played/never only — no exact play-count UI.
        _row(
          'Played',
          _anySelect(
            value: d.played,
            options: const [('played', 'Played'), ('never', 'Never played')],
            onChanged: (v) => d.played = v,
          ),
        ),
        _row(
          'Added (days)',
          _numField(d.addedDays, 'e.g. 30', (v) => d.addedDays = v?.toInt()),
        ),
        // Everything below needs the analysis pass: a track the server has not
        // decoded matches none of these rows.
        _row(
          'Minimum sample rate',
          _anySelect(
            value: d.minSampleRate?.toString(),
            options: const [
              ('44100', '44.1 kHz'),
              ('48000', '48 kHz'),
              ('88200', '88.2 kHz'),
              ('96000', '96 kHz'),
              ('192000', '192 kHz'),
            ],
            onChanged: (v) => d.minSampleRate = v == null ? null : int.parse(v),
          ),
        ),
        _row(
          'Minimum bit depth',
          _anySelect(
            value: d.minBits?.toString(),
            options: const [('16', '16-bit'), ('24', '24-bit')],
            onChanged: (v) => d.minBits = v == null ? null : int.parse(v),
          ),
        ),
        _row(
          'Loudness (LUFS)',
          Row(
            children: [
              Expanded(
                child: _numField(
                  d.loudnessFrom,
                  'louder than -14',
                  (v) => d.loudnessFrom = v?.toDouble(),
                ),
              ),
              const SizedBox(width: AriaSpace.s2),
              Expanded(
                child: _numField(
                  d.loudnessTo,
                  'quieter than -20',
                  (v) => d.loudnessTo = v?.toDouble(),
                ),
              ),
            ],
          ),
        ),
        _row(
          'Dynamic range over (LU)',
          _numField(
            d.minDynamicRange,
            'e.g. 8',
            (v) => d.minDynamicRange = v?.toDouble(),
          ),
        ),
        _row(
          'Suspect files',
          _anySelect(
            value: d.suspect,
            options: const [
              ('false', 'Exclude transcodes'),
              ('true', 'Only transcodes'),
            ],
            onChanged: (v) => d.suspect = v,
          ),
        ),
      ],
    );
  }
}
