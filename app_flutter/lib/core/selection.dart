import 'package:aria_api/aria_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Multi-select mode (legacy selOn/selection/selEnter/selToggle/selTracks):
// context menus enter selection with one item; while active, taps toggle
// membership instead of playing; the SelectionBar offers the bulk verbs.

class SelectionItem {
  const SelectionItem({
    required this.kind, // track | album | artist
    required this.key,
    required this.tracks,
  });

  /// Tracks this item expands to (album/artist expand to their tracks),
  /// resolved by the caller at toggle time — legacy selTracks().
  final List<Track> tracks;
  final String kind;
  final String key;
}

class SelectionState {
  const SelectionState({this.active = false, this.items = const {}});

  final bool active;

  /// "kind:key" -> item, insertion-ordered.
  final Map<String, SelectionItem> items;

  bool contains(String kind, String key) => items.containsKey('$kind:$key');

  /// Selection -> deduped track list (legacy selTracks()).
  List<Track> get tracks {
    final byId = <String, Track>{};
    for (final it in items.values) {
      for (final t in it.tracks) {
        byId[t.id] = t;
      }
    }
    return byId.values.toList();
  }

  /// The selection as tag items for the bulk tag menu.
  List<TagItem> get tagItems => [
    for (final it in items.values) TagItem(kind: it.kind, key: it.key),
  ];
}

final selectionProvider = NotifierProvider<SelectionNotifier, SelectionState>(
  SelectionNotifier.new,
);

class SelectionNotifier extends Notifier<SelectionState> {
  @override
  SelectionState build() => const SelectionState();

  /// Legacy selEnter(): start fresh with one item.
  void enter(SelectionItem item) {
    state = SelectionState(
      active: true,
      items: {'${item.kind}:${item.key}': item},
    );
  }

  /// Legacy selToggle(). Exits nothing — an empty active selection stays in
  /// select mode until Done.
  void toggle(SelectionItem item) {
    if (!state.active) return enter(item);
    final k = '${item.kind}:${item.key}';
    final items = {...state.items};
    if (items.containsKey(k)) {
      items.remove(k);
    } else {
      items[k] = item;
    }
    state = SelectionState(active: true, items: items);
  }

  void exit() => state = const SelectionState();
}
