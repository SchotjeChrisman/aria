import 'package:aria/core/tag_tree.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter_test/flutter_test.dart';

Tag tag(String id, String name, {String? parent, bool folder = false}) =>
    Tag(id: id, name: name, parent: parent, folder: folder);

void main() {
  group('one-level folder partitioning', () {
    final all = [
      tag('moods', 'Moods', folder: true),
      tag('empty', 'Empty', folder: true), // folder with no tags
      tag('calm', 'Calm', parent: 'moods'),
      tag('warm', 'Warm', parent: 'moods'),
      tag('loose', 'Loose'), // top-level tag, no folder
    ];

    test('folders lists only folder rows, by name', () {
      expect(folders(all).map((t) => t.id), ['empty', 'moods']);
    });

    test('looseTags excludes folders and foldered tags', () {
      expect(looseTags(all).map((t) => t.id), ['loose']);
    });

    test(
      'tagsInFolder returns a folder\'s tags, empty folder yields nothing',
      () {
        expect(tagsInFolder(all, 'moods').map((t) => t.id), ['calm', 'warm']);
        expect(tagsInFolder(all, 'empty'), isEmpty);
      },
    );
  });
}
