import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/theme.dart';

class SortOption {
  const SortOption(this.key, this.label);
  final String key;
  final String label;
}

/// Browse sort pick, persisted across sessions like legacy sortPrefKey().
/// NOTE: profile-unaware for now — legacy keys are per profile; swap the
/// 'default' slot for the active profile id once the profiles feature lands.
class LibrarySortNotifier extends Notifier<String> {
  LibrarySortNotifier(this.page, this.options, this.fallback);

  final String page;
  final List<SortOption> options;
  final String fallback;

  String get _prefsKey => 'aria.sort.default.$page';

  @override
  String build() {
    final saved = ref.read(sharedPrefsProvider).getString(_prefsKey);
    return options.any((o) => o.key == saved) ? saved! : fallback;
  }

  void set(String key) {
    if (!options.any((o) => o.key == key)) return;
    state = key;
    ref.read(sharedPrefsProvider).setString(_prefsKey, key);
  }
}

// Legacy sortBtn() option sets per page.
const albumSortOptions = [
  SortOption('artist', 'Artist'),
  SortOption('title', 'Title'),
  SortOption('yearNew', 'Newest first'),
  SortOption('yearOld', 'Oldest first'),
  SortOption('added', 'Recently added'),
  SortOption('plays', 'Most played'),
];

const artistSortOptions = [
  SortOption('name', 'Name'),
  SortOption('albums', 'Most albums'),
  SortOption('plays', 'Most played'),
];

const composerSortOptions = [
  SortOption('name', 'Name'),
  SortOption('works', 'Most works'),
  SortOption('albums', 'Most albums'),
  SortOption('plays', 'Most played'),
];

final albumSortProvider = NotifierProvider<LibrarySortNotifier, String>(
  () => LibrarySortNotifier('albums', albumSortOptions, 'artist'),
);

final artistSortProvider = NotifierProvider<LibrarySortNotifier, String>(
  () => LibrarySortNotifier('artists', artistSortOptions, 'name'),
);

final composerSortProvider = NotifierProvider<LibrarySortNotifier, String>(
  () => LibrarySortNotifier('composers', composerSortOptions, 'name'),
);

/// Quiet sort dropdown (legacy .sort-sel).
class SortDropdown extends StatelessWidget {
  const SortDropdown({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<SortOption> options;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: value,
        isDense: true,
        borderRadius: BorderRadius.circular(AriaRadius.md),
        dropdownColor: c.bgRaised,
        style: TextStyle(fontSize: 13, color: c.fgDim),
        icon: Icon(Icons.swap_vert, size: 16, color: c.fgDim),
        items: [
          for (final o in options)
            DropdownMenuItem(value: o.key, child: Text(o.label)),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}
