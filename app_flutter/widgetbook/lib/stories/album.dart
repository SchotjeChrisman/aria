import 'package:aria/core/theme.dart';
import 'package:aria/features/album/album_page.dart';
import 'package:aria/features/album/edit_metadata_dialog.dart';
import 'package:aria/features/album/person_card.dart';
import 'package:aria/features/album/reidentify_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:widgetbook/widgetbook.dart';

import '../api.dart';
import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// The album page's parts. Credits are the interesting half: an album knows
/// its performers as role -> names, and every one of them is a link to a
/// person who may or may not be in the library.

Widget creditCardStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'CreditCard',
        note: 'Portrait, name, role. The portrait falls back to initials, '
            'which is the common case — most sidemen are not enriched.',
        child: Wrap(
          spacing: AriaSpace.s5,
          runSpacing: AriaSpace.s5,
          children: [
            Variant(
              label: 'with portrait',
              child: CreditCard(
                name: 'Miles Davis',
                subtitle: 'trumpet',
                imageUrl: storybookClient.peopleImgUrl('Miles Davis'),
                onTap: () {},
              ),
            ),
            Variant(
              label: 'initials',
              child: CreditCard(
                name: 'Wynton Kelly',
                subtitle: 'piano',
                onTap: () {},
              ),
            ),
            const Variant(
              label: 'no role',
              child: CreditCard(name: 'Teo Macero'),
            ),
            const Variant(
              label: 'long name and role',
              child: CreditCard(
                name: 'Julian “Cannonball” Adderley',
                subtitle: 'alto saxophone, arrangement',
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

Widget personLinkStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'PersonLink',
        note: 'A name that navigates to the artist page. Inline in credit '
            'lines, where a card would be too heavy — the whole component is '
            'the tap target and the underline.',
        child: Wrap(
          spacing: 12,
          children: [
            PersonLink(name: 'Miles Davis'),
            PersonLink(name: 'Bill Evans'),
            PersonLink(name: 'Johann Sebastian Bach'),
          ],
        ),
      ),
    ],
  );
}

Widget releaseTypeBadgeStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'ReleaseTypeBadge',
        note: 'Only drawn for the types worth flagging — a plain album gets '
            'no badge, because most albums are albums and a badge on every '
            'one says nothing.',
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ReleaseTypeBadge(type: 'Album'),
            ReleaseTypeBadge(type: 'EP'),
            ReleaseTypeBadge(type: 'Single'),
            ReleaseTypeBadge(type: 'Live'),
            ReleaseTypeBadge(type: 'Compilation'),
          ],
        ),
      ),
    ],
  );
}

Widget workHeaderStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'WorkHeader',
        note: 'Groups the movements of one classical work inside an album\'s '
            'track list. The composer line is dropped when the album is by '
            'that composer anyway.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            WorkHeader(
              work: 'Goldberg Variations, BWV 988',
              composer: 'Johann Sebastian Bach',
            ),
            SizedBox(height: 24),
            WorkHeader(work: 'Goldberg Variations, BWV 988'),
          ],
        ),
      ),
    ],
  );
}

Widget creditsShelfStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'CreditsShelf',
        note: 'Performers grouped by role. Portraits are warmed in one '
            'bounded request when the shelf appears, so the initials you see '
            'first are replaced as the server answers.',
        child: CreditsShelf(
          roles: {
            'trumpet': {'Miles Davis'},
            'piano': {'Bill Evans Trio', 'Glenn Gould'},
            'tenor saxophone': {'John Coltrane'},
            'producer': {'Teo Macero', 'Irving Townsend'},
          },
        ),
      ),
      Section(
        title: 'One role',
        child: CreditsShelf(
          roles: {
            'piano': {'Glenn Gould'},
          },
        ),
      ),
    ],
  );
}

Widget metadataEditorStory(BuildContext context) {
  final derived = context.knobs
      .boolean(label: 'values came from MusicBrainz', initialValue: true);

  return StoryPage(
    children: [
      Section(
        title: 'MetadataEditorDialog',
        note: 'One dialog serves albums and tracks — the field list is the '
            'argument. A field whose value was derived from a match shows its '
            'provenance, so overwriting one is a visible decision.',
        child: SizedBox(
          height: 620,
          child: Consumer(
            builder: (context, ref, _) => MetadataEditorDialog(
              title: 'Edit album — Kind of Blue',
              fields: albumEditorFields,
              original: const {
                'album': 'Kind of Blue',
                'albumArtist': 'Miles Davis',
                'genre': 'Jazz',
                'year': 1959,
                'releaseType': 'Album',
                'label': 'Columbia',
                'date': '1959-08-17',
                'country': 'US',
              },
              overrides: const {'genre': 'Modal Jazz'},
              source: derived
                  ? const {
                      'kind': 'album',
                      'releaseMbid': 'f1d1-0001',
                      'releaseTitle': 'Kind of Blue',
                      'distance': 0.02,
                      'separation': 0.41,
                      'decidedAt': '2026-05-02T09:00:00Z',
                      'pinned': false,
                    }
                  : null,
              patch: (body) async => body,
              artAlbumId: 'a-kind-of-blue',
              client: storybookClient,
            ),
          ),
        ),
      ),
      Section(
        title: 'Track fields',
        note: 'Same dialog, the track field list: title, artist, track and '
            'disc numbers, composer, work and movement.',
        child: SizedBox(
          height: 620,
          child: MetadataEditorDialog(
            title: 'Edit track — So What',
            fields: trackEditorFields,
            original: const {
              'title': 'So What',
              'artist': 'Miles Davis',
              'album': 'Kind of Blue',
              'trackNo': 1,
            },
            overrides: const {},
            patch: (body) async => body,
          ),
        ),
      ),
    ],
  );
}

Widget albumReidentifyStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'AlbumReidentifyDialog',
        note: 'Searches MusicBrainz on open. The stub answers with no '
            'candidates, which is the state worth catalogueing — it is what '
            'you see for anything obscure, and the dialog has to say so '
            'rather than spin.',
        child: SizedBox(
          height: 420,
          child: Consumer(
            builder: (context, ref, _) => AlbumReidentifyDialog(
              ref: ref,
              album: albumById('a-kind-of-blue'),
            ),
          ),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final albumEntries = <Entry>[
  Entry(component: 'CreditCard', key: 'credit-card', builder: creditCardStory),
  Entry(component: 'PersonLink', key: 'person-link', builder: personLinkStory),
  Entry(
    component: 'ReleaseTypeBadge',
    key: 'release-type-badge',
    builder: releaseTypeBadgeStory,
  ),
  Entry(component: 'WorkHeader', key: 'work-header', builder: workHeaderStory),
  Entry(
    component: 'CreditsShelf',
    key: 'credits-shelf',
    builder: creditsShelfStory,
  ),
  Entry(
    component: 'MetadataEditorDialog',
    key: 'metadata-editor',
    builder: metadataEditorStory,
  ),
  Entry(
    component: 'AlbumReidentifyDialog',
    key: 'album-reidentify',
    builder: albumReidentifyStory,
  ),
];
