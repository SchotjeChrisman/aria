import 'dart:io';

import 'package:aria_widgetbook/stories/all.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every widget under `../lib/widgets`, `../lib/features` and `../lib/core`
/// must be in the catalogue — components and destinations alike. `../lib`
/// itself is not scanned: the only widget there is the app root.
///
/// The list is not maintained here — it is read out of those three
/// directories on each run,
/// so a widget added to the app and not to the catalogue fails this test
/// rather than quietly going missing. That is the whole point: a hand-kept
/// list of "what to catalogue" is a list that goes stale.
///
/// Screens and pages are in scope too: the catalogue is where the UI is
/// tested, and half of what can be wrong with a page — its padding, its
/// scroll extent, its empty state — is invisible in the components it is
/// built from. Their use cases live in `lib/stories/pages.dart`.
void main() {
  final widgetClass = RegExp(
    r'^class ([A-Z]\w*) extends '
    r'(?:StatelessWidget|StatefulWidget|ConsumerWidget|ConsumerStatefulWidget)',
    multiLine: true,
  );

  /// `../lib/foo/bar.dart` as the app's own package URI, which is how a
  /// story imports it.
  String packageUri(String path) =>
      'package:aria/${path.split('../lib/').last}';

  test('every widget under ../lib/{widgets,features,core} has a story', () {
    // Keyed by package URI, because that is what a story imports, and two
    // files can hold a class of the same name — there are two PersonCards.
    // A name-only check would let a storyless component hide behind its
    // twin's story.
    final components = <String, List<String>>{};
    for (final dir in ['../lib/widgets', '../lib/features', '../lib/core']) {
      for (final f in Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        for (final m in widgetClass.allMatches(f.readAsStringSync())) {
          (components[packageUri(f.path)] ??= []).add(m.group(1)!);
        }
      }
    }

    // Non-trivial floor: if the scan ever matches nothing — a renamed
    // directory, a changed base class — an empty set would pass silently.
    expect(
      components.values.fold(0, (n, names) => n + names.length),
      greaterThan(80),
    );

    // Each story file with the set of app libraries it imports. A component
    // counts as catalogued only when a file that imports ITS library also
    // names it.
    final stories = [
      for (final f in Directory('lib/stories').listSync().whereType<File>())
        f.readAsStringSync(),
    ];
    final imports = {
      for (final src in stories)
        src: RegExp(r"^import '(package:aria/[^']+)'", multiLine: true)
            .allMatches(src)
            .map((m) => m.group(1)!)
            .toSet(),
    };

    final missing = <String>[];
    for (final MapEntry(key: uri, value: names) in components.entries) {
      final relevant = [
        for (final src in stories)
          if (imports[src]!.contains(uri)) src,
      ].join();
      for (final name in names) {
        if (!RegExp('\\b$name\\b').hasMatch(relevant)) {
          missing.add('$name ($uri)');
        }
      }
    }
    missing.sort();

    expect(
      missing,
      isEmpty,
      reason: 'these widgets have no use case in a story file that imports '
          'them — add one, or make the widget private if it is not a '
          'component or a destination',
    );
  });

  test('every entry has a unique golden key', () {
    final keys = [for (final e in allEntries) e.key];
    expect(keys.toSet().length, keys.length, reason: 'duplicate Entry.key');
  });
}
