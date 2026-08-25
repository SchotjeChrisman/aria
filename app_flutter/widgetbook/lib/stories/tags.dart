import 'package:aria/features/tags/tag_grid.dart';
import 'package:aria/features/tags/tags_screen.dart';
import 'package:flutter/material.dart';

import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// Tags are a tree: folders hold tags, tags hold albums and tracks. All three
/// components take the whole tag list as `all` — membership counts are
/// computed by walking it, so a tile cannot show a stale count.

Widget tagGridStory(BuildContext context) {
  final tags = [
    for (final t in fixtureTags)
      if (!t.folder) t,
  ];

  return StoryPage(
    children: [
      Section(
        title: 'TagGrid',
        note: 'A GridView, so it needs a bounded height from its parent — on '
            'the tag screens that is the page scroll view.',
        child: SizedBox(
          height: 260,
          child: TagGrid(all: fixtureTags, tags: tags),
        ),
      ),
      Section(
        title: 'Empty',
        note: 'No tags yet. The grid draws nothing rather than a placeholder; '
            'the empty state belongs to the screen above it.',
        child: SizedBox(
          height: 80,
          child: TagGrid(all: fixtureTags, tags: const []),
        ),
      ),
    ],
  );
}

Widget tagTileStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'TagTile',
        note: 'Item count comes from the tag itself; a tile with no items '
            'still shows, because an empty tag you just made is not a '
            'mistake.',
        child: Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final tag in fixtureTags)
              if (!tag.folder)
                Variant(
                  label: '${tag.items.length} items',
                  child: SizedBox(
                    width: 190,
                    height: 240,
                    child: TagTile(all: fixtureTags, tag: tag),
                  ),
                ),
          ],
        ),
      ),
    ],
  );
}

Widget folderRowStory(BuildContext context) {
  final folder = fixtureTags.firstWhere((t) => t.folder);
  return StoryPage(
    children: [
      Section(
        title: 'FolderRow',
        note: 'A folder and the tags inside it, on one row. Right-click for '
            'rename and delete — deleting a folder does not delete its tags.',
        child: FolderRow(all: fixtureTags, folder: folder),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final tagEntries = <Entry>[
  Entry(component: 'TagGrid', key: 'tag-grid', builder: tagGridStory),
  Entry(component: 'TagTile', key: 'tag-tile', builder: tagTileStory),
  Entry(component: 'FolderRow', key: 'folder-row', builder: folderRowStory),
];
