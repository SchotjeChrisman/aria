import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';

/// The catalogue's index: one [Entry] per component, declared beside its
/// story and read by both `main.dart` (to build the navigation tree) and
/// `test/stories_render_test.dart` (to render every one of them).
///
/// Declared once rather than twice because the two lists drifted the moment
/// there were more than a handful: a story with no entry is invisible in the
/// app, and a story with no test is a component nothing renders.

typedef Story = Widget Function(BuildContext);

/// One component in the catalogue.
class Entry {
  const Entry({
    required this.component,
    required this.key,
    required this.builder,
    this.folder,
    this.useCase = 'Default',
    this.golden = true,
  });

  /// Component name, as shown in the tree. Two entries sharing it become two
  /// use cases of the same component.
  final String component;

  /// Optional grouping level between the category and the component.
  final String? folder;

  /// The state this use case shows.
  final String useCase;

  /// Golden file name, and the test's name for this use case.
  final String key;

  final Story builder;

  /// False for use cases whose fixtures move with the wall clock — the play
  /// charts bucket against `DateTime.now()`, so their pixels change daily.
  /// The test still renders them; it just does not compare them.
  final bool golden;
}

/// [entries] as a Widgetbook tree, preserving declaration order at every
/// level: folders in the order they first appear, components in the order
/// they first appear inside a folder, use cases in the order declared.
List<WidgetbookNode> nodesOf(List<Entry> entries) {
  final roots = <String, List<Entry>>{};
  for (final e in entries) {
    (roots[e.folder ?? ''] ??= []).add(e);
  }
  return [
    for (final MapEntry(key: folder, value: group) in roots.entries)
      if (folder.isEmpty)
        ..._components(group)
      else
        WidgetbookFolder(name: folder, children: _components(group)),
  ];
}

List<WidgetbookComponent> _components(List<Entry> entries) {
  final byComponent = <String, List<Entry>>{};
  for (final e in entries) {
    (byComponent[e.component] ??= []).add(e);
  }
  return [
    for (final MapEntry(key: name, value: group) in byComponent.entries)
      WidgetbookComponent(
        name: name,
        useCases: [
          for (final e in group)
            WidgetbookUseCase(name: e.useCase, builder: e.builder),
        ],
      ),
  ];
}
