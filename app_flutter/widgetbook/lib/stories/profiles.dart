import 'package:aria/core/theme.dart';
import 'package:aria/features/profiles/profile_menu.dart';
import 'package:aria/features/profiles/profiles_section.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// Profiles scope plays, stats and playlists. Everything here is coloured
/// from the profile's own hex, so the avatar and the row cannot disagree
/// about which profile you are looking at.

Widget profileAvatarStory(BuildContext context) {
  final size = context.knobs.double
      .slider(label: 'size', initialValue: 28, min: 16, max: 96);

  return StoryPage(
    children: [
      Section(
        title: 'ProfileAvatar',
        note: 'Initial on the profile colour. No portrait ever — a profile is '
            'a listening context, not a person with a photograph.',
        child: Wrap(
          spacing: AriaSpace.s5,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final p in fixtureProfiles)
              Variant(
                label: p.name,
                child: ProfileAvatar(profile: p, size: size),
              ),
          ],
        ),
      ),
      Section(
        title: 'Sizes in use',
        note: '28 in the top bar, 40 in the switcher, 20 beside a play count.',
        child: Wrap(
          spacing: AriaSpace.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final s in [20.0, 28.0, 40.0, 64.0])
              ProfileAvatar(profile: fixtureProfiles.first, size: s),
          ],
        ),
      ),
    ],
  );
}

Widget profileMenuButtonStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'ProfileMenuButton',
        note: 'Avatar plus name, or avatar alone on narrow layouts. Tapping '
            'opens the switcher below.',
        child: Row(
          children: [
            Variant(label: 'full', child: ProfileMenuButton()),
            SizedBox(width: 24),
            Variant(label: 'compact', child: ProfileMenuButton(compact: true)),
          ],
        ),
      ),
    ],
  );
}

Widget profileMenuBodyStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ProfileMenuBody',
        note: 'The switcher sheet: every profile, the active one marked, and '
            'a row to add another. It takes the anchor\'s context so the '
            'dialogs it opens are rooted above the sheet it closes.',
        child: Builder(
          builder: (anchor) => SizedBox(
            width: 320,
            child: ProfileMenuBody(anchorContext: anchor),
          ),
        ),
      ),
    ],
  );
}

Widget profileRowStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ProfileRow',
        note: 'One row of the switcher. The active row is marked rather than '
            'disabled — tapping it again is harmless and closes the sheet.',
        child: SizedBox(
          width: 360,
          child: Column(
            children: [
              for (final (i, p) in fixtureProfiles.indexed)
                ProfileRow(
                  profile: p,
                  isActive: i == 0,
                  onTap: () {},
                  onEdit: () {},
                  onDelete: () {},
                ),
            ],
          ),
        ),
      ),
    ],
  );
}

Widget profileEditorStory(BuildContext context) {
  final existing =
      context.knobs.boolean(label: 'edit an existing one', initialValue: true);

  return StoryPage(
    children: [
      Section(
        title: 'ProfileEditorDialog',
        note: 'A name and a colour off a fixed palette. New profiles start on '
            'a palette entry picked from the clock, so two made in a row are '
            'rarely the same colour.',
        child: SizedBox(
          height: 380,
          child: ProfileEditorDialog(
            profile: existing ? fixtureProfiles.first : null,
          ),
        ),
      ),
    ],
  );
}

Widget profilesSectionStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'ProfilesSection',
        note: 'The settings block: every profile with edit and delete, and '
            'the active one marked. Reads the live provider, so changes made '
            'in the switcher show up here.',
        child: ProfilesSection(),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final profileEntries = <Entry>[
  Entry(
    component: 'ProfileAvatar',
    key: 'profile-avatar',
    builder: profileAvatarStory,
  ),
  Entry(
    component: 'ProfileMenuButton',
    key: 'profile-menu-button',
    builder: profileMenuButtonStory,
  ),
  Entry(
    component: 'ProfileMenuBody',
    key: 'profile-menu-body',
    builder: profileMenuBodyStory,
  ),
  Entry(component: 'ProfileRow', key: 'profile-row', builder: profileRowStory),
  Entry(
    component: 'ProfileEditorDialog',
    key: 'profile-editor',
    builder: profileEditorStory,
  ),
  Entry(
    component: 'ProfilesSection',
    key: 'profiles-section',
    builder: profilesSectionStory,
  ),
];
