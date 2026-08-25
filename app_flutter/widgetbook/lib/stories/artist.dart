import 'package:aria/core/theme.dart';
import 'package:aria/features/artist/artist_discography.dart';
import 'package:aria/features/artist/artist_info_tab.dart';
import 'package:aria/features/artist/artist_overview.dart';
import 'package:aria/features/artist/composer_page.dart';
import 'package:aria/features/artist/edit_artist_dialog.dart';
import 'package:aria/features/artist/person_card.dart';
import 'package:aria/features/artist/reidentify_artist_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:widgetbook/widgetbook.dart';

import '../api.dart';
import '../fixtures.dart';
import 'catalogue.dart';
import 'components.dart' show Variant;
import 'foundations.dart' show Section, StoryPage;

/// The artist page is three tabs over one name. Everything below takes the
/// name and resolves the rest from providers, so a story is a string — which
/// is also why they all work against the stub with no wiring.

Widget artistPersonCardStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'PersonCard',
        note: 'The artist page\'s card for members, bands and similar '
            'artists. Same shape as the album page\'s CreditCard, minus the '
            'role line and plus a secondary-tap hook.',
        child: Wrap(
          spacing: AriaSpace.s5,
          runSpacing: AriaSpace.s5,
          children: [
            for (final name in fixtureArtists.take(3))
              Variant(
                label: name,
                child: PersonCard(
                  name: name,
                  imageUrl: storybookClient.peopleImgUrl(name),
                  onTap: () {},
                ),
              ),
            const Variant(
              label: 'not enriched',
              child: PersonCard(name: 'Paul Chambers', subtitle: 'bass'),
            ),
          ],
        ),
      ),
    ],
  );
}

Widget artistBioStory(BuildContext context) {
  final long = context.knobs.boolean(label: 'long bio', initialValue: true);

  return StoryPage(
    children: [
      Section(
        title: 'ArtistBio',
        note: 'Wikipedia summary with a link out. Clamped on the overview '
            'tab and shown whole here — the "more" affordance belongs to the '
            'tab, not the component.',
        child: ArtistBio(
          name: 'Miles Davis',
          summary: long
              ? fixtureArtistInfo.bio
              : 'Trumpeter and bandleader, 1926–1991.',
          url: fixtureArtistInfo.url,
        ),
      ),
      const Section(
        title: 'Nothing researched',
        note: 'No summary and no link: the block says so rather than '
            'collapsing, so the tab does not look broken.',
        child: ArtistBio(name: 'Paul Chambers'),
      ),
    ],
  );
}

Widget artistFactsHeroStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ArtistFactsHero',
        note: 'Portrait, lifespan, area, instruments, and the counts derived '
            'from the tracks handed in — the hero never queries the library '
            'itself.',
        child: ArtistFactsHero(
          name: 'Miles Davis',
          tracks: fixtureTracks,
          onMoreBio: () {},
        ),
      ),
    ],
  );
}

Widget artistTopTracksStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'ArtistTopTracks',
        note: 'Ranked by play count from `/api/stats`, not by track number. '
            'Nothing played means nothing shown.',
        child: ArtistTopTracks(name: 'Miles Davis'),
      ),
    ],
  );
}

Widget artistPeopleShelvesStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ArtistPeopleShelves',
        note: 'Members, bands and similar artists. `inLibrary` decides which '
            'names are links to a library page and which are dead names — a '
            'similar artist you do not own cannot be navigated to.',
        child: ArtistPeopleShelves(
          name: 'Miles Davis',
          inLibrary: fixtureArtists.toSet(),
        ),
      ),
      Section(
        title: 'None of them owned',
        child: ArtistPeopleShelves(
          name: 'Miles Davis',
          inLibrary: const <String>{},
        ),
      ),
    ],
  );
}

Widget artistDiscographyStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'ArtistDiscography',
        note: 'Library albums, albums the artist only appears on, and the '
            'releases the server knows about that nobody here owns — the '
            'last of those open the unowned-release page.',
        child: ArtistDiscography(name: 'Miles Davis'),
      ),
    ],
  );
}

Widget artistInfoTabStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'ArtistInfoTab',
        note: 'The whole Info tab: bio, facts and external links, composed '
            'from the parts above.',
        child: ArtistInfoTab(name: 'Miles Davis'),
      ),
    ],
  );
}

Widget artistOverviewStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ArtistOverview',
        note: 'The Overview tab: hero, top tracks, albums, works and people. '
            'onMoreBio switches the page to Info in place rather than '
            'navigating, which is why it is a callback and not a route.',
        child: ArtistOverview(name: 'Miles Davis', onMoreBio: () {}),
      ),
    ],
  );
}

Widget composerHeroStory(BuildContext context) {
  return StoryPage(
    children: const [
      Section(
        title: 'ComposerHero',
        note: 'Open Opus portrait, epoch and dates. A composer is not an '
            'artist: no discography, no similar-artists shelf, and the works '
            'index below it is the page.',
        child: ComposerHero(name: 'Johann Sebastian Bach'),
      ),
    ],
  );
}

Widget artistEditorStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ArtistEditorDialog',
        note: 'Overrides on top of what the enricher found. Bio is override-'
            'only and never prefilled — a large remote text prefilled into a '
            'field is a text you will accidentally freeze.',
        child: SizedBox(
          height: 560,
          child: ArtistEditorDialog(
            name: 'Miles Davis',
            original: const {
              'type': 'Person',
              'area': 'United States',
              'born': '1926-05-26',
              'died': '1991-09-28',
            },
            overrides: const {'area': 'Alton, Illinois'},
            patch: (body) async => body,
          ),
        ),
      ),
    ],
  );
}

Widget artistReidentifyStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ArtistReidentifyDialog',
        note: 'MusicBrainz artist search, for when the enricher attached the '
            'wrong person — two musicians sharing a name is the usual cause.',
        child: SizedBox(
          height: 420,
          child: Consumer(
            builder: (context, ref, _) =>
                ArtistReidentifyDialog(ref: ref, name: 'Miles Davis'),
          ),
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final artistEntries = <Entry>[
  Entry(
    component: 'PersonCard',
    key: 'artist-person-card',
    builder: artistPersonCardStory,
  ),
  Entry(component: 'ArtistBio', key: 'artist-bio', builder: artistBioStory),
  Entry(
    component: 'ArtistFactsHero',
    key: 'artist-facts-hero',
    builder: artistFactsHeroStory,
  ),
  Entry(
    component: 'ArtistTopTracks',
    key: 'artist-top-tracks',
    builder: artistTopTracksStory,
    golden: false,
  ),
  Entry(
    component: 'ArtistPeopleShelves',
    key: 'artist-people-shelves',
    builder: artistPeopleShelvesStory,
  ),
  Entry(
    component: 'ArtistDiscography',
    key: 'artist-discography',
    builder: artistDiscographyStory,
  ),
  Entry(
    component: 'ArtistInfoTab',
    key: 'artist-info-tab',
    builder: artistInfoTabStory,
  ),
  Entry(
    component: 'ArtistOverview',
    key: 'artist-overview',
    builder: artistOverviewStory,
    golden: false,
  ),
  Entry(
    component: 'ComposerHero',
    key: 'composer-hero',
    builder: composerHeroStory,
  ),
  Entry(
    component: 'ArtistEditorDialog',
    key: 'artist-editor',
    builder: artistEditorStory,
  ),
  Entry(
    component: 'ArtistReidentifyDialog',
    key: 'artist-reidentify',
    builder: artistReidentifyStory,
  ),
];
