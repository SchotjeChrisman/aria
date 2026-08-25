import 'package:aria/features/playlists/playlists_screen.dart';
import 'package:aria/features/playlists/smart_editor.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// Two kinds of playlist share one tile. A manual playlist holds track ids; a
/// smart one holds a query and is evaluated server-side, which is what the
/// badge is warning you about.

Widget playlistTileStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'PlaylistTile',
        note: 'Cover art is a mosaic of the first few tracks\' albums, so a '
            'playlist looks like what is in it. Smart playlists carry the '
            'badge and no track count until the server evaluates them.',
        child: Column(
          children: [
            for (final p in fixturePlaylists)
              Variant(
                label: p.type,
                child: SizedBox(width: 420, child: PlaylistTile(playlist: p)),
              ),
          ],
        ),
      ),
    ],
  );
}

Widget smartBadgeStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'SmartBadge',
        note: 'One word, accent-tinted. It marks the playlists whose contents '
            'are a query rather than a list — the only ones you cannot drag '
            'a track into.',
        child: Align(alignment: Alignment.centerLeft, child: SmartBadge()),
      ),
    ],
  );
}

Widget smartEditorStory(BuildContext context) {
  final existing = context.knobs
      .boolean(label: 'edit an existing playlist', initialValue: true);

  return StoryPage(
    children: [
      Section(
        title: 'SmartEditorDialog',
        note: 'The rule builder behind a smart playlist: field/operator/value '
            'rows, an any-vs-all combinator, and the numeric ranges (year, '
            'loudness, dynamic range) as paired bounds rather than free text.',
        child: SizedBox(
          height: 640,
          child: SmartEditorDialog(
            playlist: existing
                ? fixturePlaylists.firstWhere((p) => p.type == 'smart')
                : null,
          ),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final playlistEntries = <Entry>[
  Entry(
    component: 'PlaylistTile',
    key: 'playlist-tile',
    builder: playlistTileStory,
  ),
  Entry(component: 'SmartBadge', key: 'smart-badge', builder: smartBadgeStory),
  Entry(
    component: 'SmartEditorDialog',
    key: 'smart-editor',
    builder: smartEditorStory,
  ),
];
