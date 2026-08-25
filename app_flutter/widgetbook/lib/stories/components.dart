import 'package:aria/core/phosphor_icons.dart';
import 'package:aria/core/selection.dart';
import 'package:aria/core/theme.dart';
import 'package:aria/core/toast.dart';
import 'package:aria/widgets/album_card.dart';
import 'package:aria/widgets/art_image.dart';
import 'package:aria/widgets/artist_avatar.dart';
import 'package:aria/widgets/context_menu.dart';
import 'package:aria/widgets/empty_state.dart';
import 'package:aria/widgets/filter_bar.dart';
import 'package:aria/widgets/format_badge.dart';
import 'package:aria/widgets/library_cards.dart';
import 'package:aria/widgets/listen_later_shelf.dart';
import 'package:aria/widgets/multi_select_field.dart';
import 'package:aria/widgets/name_dialog.dart';
import 'package:aria/widgets/new_releases_shelf.dart';
import 'package:aria/widgets/selection_bar.dart';
import 'package:aria/widgets/selection_highlight.dart';
import 'package:aria/widgets/shelf.dart';
import 'package:aria/widgets/tag_picker.dart';
import 'package:aria/widgets/track_actions.dart';
import 'package:aria/widgets/track_row.dart';
import 'package:aria/widgets/unowned_album_card.dart';
import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:widgetbook/widgetbook.dart';

import '../api.dart';
import '../fixtures.dart';
import 'catalogue.dart';
import 'foundations.dart' show StoryPage, Section;

/// Use cases for lib/widgets. Every widget here is imported from the app —
/// this file only supplies arguments and states, never a re-implementation.

/// Widgets that read providers are the norm in this app, so use cases render
/// inside the same ProviderScope main.dart installs. Nothing extra is needed
/// here; this comment exists so the absence of per-story mocking reads as
/// deliberate.

// ------------------------------------------------------------------ helpers

/// Labelled specimen, so a page of variants says which state is which.
class Variant extends StatelessWidget {
  const Variant({
    super.key,
    required this.label,
    required this.child,
    this.width,
  });

  final String label;
  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AriaSpace.s5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.labelMedium),
          const SizedBox(height: AriaSpace.s2),
          width == null ? child : SizedBox(width: width, child: child),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- art image

Widget artImageStory(BuildContext context) {
  final size = context.knobs.double
      .slider(label: 'size', initialValue: 160, min: 48, max: 320);
  final hasArt = context.knobs.boolean(label: 'has artwork', initialValue: true);
  final text = context.knobs
      .string(label: 'fallback text', initialValue: 'Kind of Blue');

  return StoryPage(
    children: [
      Section(
        title: 'ArtImage',
        note: 'Network cover, then the locally downloaded copy when offline, '
            'then initials. Real covers are borderless — the border belongs to '
            'the placeholder, or a bare edge round the art looks cheap.',
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Variant(
              label: hasArt ? 'network' : 'fallback',
              child: ArtImage(
                url: hasArt ? artUrlFor('a-kind-of-blue') : null,
                fallbackText: text,
                size: size,
              ),
            ),
          ],
        ),
      ),
      Section(
        title: 'Sizes in use',
        note: 'Grid and shelf tiles decode at ~190px, not at full cover '
            'resolution — a 10k-cover library would otherwise thrash the '
            'image cache.',
        child: Wrap(
          spacing: AriaSpace.s4,
          runSpacing: AriaSpace.s4,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            for (final s in [48.0, 64.0, 96.0, 160.0])
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ArtImage(
                    url: artUrlFor('sunday-at-the-village-vanguard'),
                    fallbackText: 'Sunday',
                    size: s,
                  ),
                  const SizedBox(height: AriaSpace.s1),
                  Text('${s.toInt()}',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
          ],
        ),
      ),
    ],
  );
}

// --------------------------------------------------------------- album card

Widget albumCardStory(BuildContext context) {
  final title = context.knobs
      .string(label: 'title', initialValue: 'Sunday at the Village Vanguard');
  final subtitle =
      context.knobs.stringOrNull(label: 'subtitle', initialValue: 'Bill Evans Trio');
  final hasArt = context.knobs.boolean(label: 'has artwork', initialValue: true);

  return StoryPage(
    children: [
      Section(
        title: 'AlbumCard',
        note: 'Square art, 500-weight title, dim subtitle. Both text lines are '
            'single-line and ellipsized — the grids that hold these cards pin '
            'cell height for exactly two lines.',
        child: SizedBox(
          width: 190,
          child: AlbumCard(
            title: title,
            subtitle: subtitle,
            artUrl: hasArt ? artUrlFor('sunday-at-the-village-vanguard') : null,
            onTap: () {},
          ),
        ),
      ),
      Section(
        title: 'States',
        child: Wrap(
          spacing: AriaSpace.s5,
          runSpacing: AriaSpace.s5,
          children: [
            for (final album in fixtureAlbums)
              Variant(
                width: 190,
                label: album.hasArt ? album.title : '${album.title} · no art',
                child: AlbumCard(
                  title: album.title,
                  subtitle: album.albumArtist,
                  artUrl: album.hasArt ? artUrlFor(album.id) : null,
                  onTap: () {},
                ),
              ),
            Variant(
              width: 190,
              label: 'long title, ellipsized',
              child: AlbumCard(
                title: 'Goldberg Variations, BWV 988 — 1981 Digital Recording',
                subtitle: 'Johann Sebastian Bach · Glenn Gould',
                artUrl: artUrlFor('goldberg-variations-1981'),
                onTap: () {},
              ),
            ),
            Variant(
              width: 190,
              label: 'no subtitle',
              child: AlbumCard(
                title: 'Kind of Blue',
                artUrl: artUrlFor('a-kind-of-blue'),
                onTap: () {},
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

/// The wired card: selection highlight, tap-extends-selection, context menu.
Widget albumGridCardStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'AlbumGridCard',
        note: 'AlbumCard plus the standard wiring shared by home, library and '
            'search. Right-click (or long-press) for the context menu; pick '
            '"Select…" and the cards switch to toggling selection instead of '
            'navigating.',
        child: Builder(
          builder: (context) {
            final band = AriaBreakpoint.of(context);
            return GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: band.gridColumns,
              crossAxisSpacing: AriaSpace.s5,
              mainAxisSpacing: AriaSpace.s5,
              // The library grid's own ratio — tablet-floor tiles need a
              // taller cell because the text block under the art does not
              // shrink with the tile.
              childAspectRatio: band == AriaBreakpoint.tablet ? 0.67 : 0.72,
              children: [
                for (final album in fixtureAlbums)
                  AlbumGridCard(
                    albumId: album.id,
                    title: album.title,
                    artistName: album.albumArtist,
                    tracks: album.tracks,
                    hasArt: album.hasArt,
                  ),
              ],
            );
          },
        ),
      ),
      const Section(
        title: 'SelectionBar',
        note: 'Mounted by the shell above the transport while multi-select is '
            'active. Enter it from a card menu above, then the bulk verbs '
            'apply to everything gathered across views.',
        child: SelectionBar(),
      ),
    ],
  );
}

Widget unownedAlbumCardStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'UnownedAlbumCard',
        note: 'For albums the library does not have — New Releases, Listen '
            'Later, discography ghosts. Deliberately not AlbumCard: there is '
            'no local albumId to fetch art by and no /album/:id to route to. '
            'Covers load through the server proxy, then the raw CDN URL, then '
            'a vinyl placeholder.',
        child: Wrap(
          spacing: AriaSpace.s5,
          runSpacing: AriaSpace.s5,
          children: [
            for (final r in fixtureUnowned)
              Variant(
                width: 190,
                label: r.cover.isEmpty ? 'no cover — placeholder' : r.title,
                child: UnownedAlbumCard(
                  artist: r.artist,
                  title: r.title,
                  subtitle: r.subtitle,
                  cover: r.cover.isEmpty ? null : r.cover,
                  menuItems: (_) => [
                    AriaMenuItem('Save for later', () {},
                        icon: PhosphorIconsRegular.clock),
                  ],
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

// ------------------------------------------------------------ artist avatar

Widget artistAvatarStory(BuildContext context) {
  final size = context.knobs.double
      .slider(label: 'size', initialValue: 96, min: 24, max: 200);
  final known = context.knobs
      .boolean(label: 'portrait available', initialValue: true);
  final name = context.knobs.string(label: 'name', initialValue: 'Miles Davis');

  return StoryPage(
    children: [
      Section(
        title: 'ArtistAvatar',
        note: 'Portrait via the LAN proxy first, then the raw CDN URL, then '
            'initials on a tinted disc. Borderless like covers — the grey disc '
            'alone carries the fallback, and it is hidden once a portrait '
            'loads over it.',
        child: ArtistAvatar(
          // An unknown name has no portrait on the server, so the chain falls
          // through to initials — which is the state worth being able to see.
          name: known ? name : 'Nobody At All',
          size: size,
        ),
      ),
      Section(
        title: 'Sizes',
        child: Wrap(
          spacing: AriaSpace.s4,
          runSpacing: AriaSpace.s4,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            for (final s in [32.0, 48.0, 64.0, 96.0])
              ArtistAvatar(name: 'Bill Evans Trio', size: s),
          ],
        ),
      ),
      Section(
        title: 'In a row',
        child: Wrap(
          spacing: AriaSpace.s5,
          runSpacing: AriaSpace.s5,
          children: [
            for (final artist in fixtureArtists)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ArtistAvatar(name: artist, size: 72),
                  const SizedBox(height: AriaSpace.s2),
                  SizedBox(
                    width: 84,
                    child: Text(
                      artist,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    ],
  );
}

// -------------------------------------------------------------- format badge

Widget formatBadgeStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'FormatBadge',
        note: 'Lossless renders in full-strength greyscale because lossless is '
            'the norm; only lossy gets flagged. Hi-res (>16-bit or >48kHz) is '
            'weighted slightly heavier. Empty input renders nothing at all, '
            'not a placeholder.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Variant(
              label: 'hi-res lossless — 24/192, heavier weight',
              child: FormatBadge(
                format: hiResTrack.format,
                bitsPerSample: hiResTrack.bitsPerSample,
                sampleRate: hiResTrack.sampleRate,
                lossless: hiResTrack.lossless,
              ),
            ),
            Variant(
              label: 'redbook lossless — 16/44.1',
              child: FormatBadge(
                format: losslessTrack.format,
                bitsPerSample: losslessTrack.bitsPerSample,
                sampleRate: losslessTrack.sampleRate,
                lossless: true,
              ),
            ),
            Variant(
              label: 'lossy — dim, no bit depth',
              child: FormatBadge(
                format: lossyTrack.format,
                bitsPerSample: lossyTrack.bitsPerSample,
                sampleRate: lossyTrack.sampleRate,
              ),
            ),
            const Variant(
              label: 'unknown format — renders nothing',
              child: FormatBadge(),
            ),
          ],
        ),
      ),
    ],
  );
}

// ----------------------------------------------------------------- track row

Widget trackRowStory(BuildContext context) {
  final isCurrent =
      context.knobs.boolean(label: 'is current', initialValue: false);
  final downloaded =
      context.knobs.boolean(label: 'downloaded', initialValue: false);
  final showNumber =
      context.knobs.boolean(label: 'show number', initialValue: true);
  final track = context.knobs.object.dropdown(
    label: 'track',
    options: fixtureTracks,
    labelBuilder: (t) => t.title ?? '—',
  );

  return StoryPage(
    children: [
      Section(
        title: 'TrackRow',
        note: 'Number column, title with optional dim subtitle, format badge, '
            'tabular duration. The current track goes accent across every '
            'column and swaps its number for a play marker.',
        child: TrackRow(
          number: showNumber ? track.trackNo : null,
          title: track.title ?? '',
          subtitle: track.artist,
          duration: track.duration,
          format: track.format,
          bitsPerSample: track.bitsPerSample,
          sampleRate: track.sampleRate,
          lossless: track.lossless,
          downloaded: downloaded,
          isCurrent: isCurrent,
          onTap: () {},
        ),
      ),
      Section(
        title: 'A full album',
        note: 'Track 1 is shown as the current row.',
        child: Column(
          children: [
            for (final (i, t) in albumById('a-kind-of-blue').tracks.indexed)
              TrackRow(
                number: t.trackNo,
                title: t.title ?? '',
                subtitle: t.artist,
                duration: t.duration,
                format: t.format,
                bitsPerSample: t.bitsPerSample,
                sampleRate: t.sampleRate,
                lossless: t.lossless,
                isCurrent: i == 0,
                downloaded: i == 1,
                onTap: () {},
                onSecondary: (pos) => showAriaContextMenu(context, pos, [
                  AriaMenuItem('Play now', () {},
                      icon: PhosphorIconsRegular.play),
                  AriaMenuItem('Add to queue', () {},
                      icon: PhosphorIconsRegular.listPlus),
                ]),
              ),
          ],
        ),
      ),
      Section(
        title: 'Edge cases',
        child: Column(
          children: [
            TrackRow(
              title: 'Goldberg Variations, BWV 988: Variatio 25 a 2 Clav. — '
                  'Adagio, the long one that has to ellipsize',
              subtitle: 'Glenn Gould · Johann Sebastian Bach',
              number: 26,
              duration: 382,
              format: 'FLAC',
              bitsPerSample: 24,
              sampleRate: 96000,
              lossless: true,
              onTap: () {},
            ),
            TrackRow(
              title: 'No number, no subtitle, no duration',
              onTap: () {},
            ),
          ],
        ),
      ),
    ],
  );
}

/// The two provider-backed buttons that ride alongside a track.
Widget trackActionStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'FavouriteButton',
        note: 'A per-track flag of its own — unrelated to playlists and tags. '
            'Toggling is optimistic; the server call reconciles behind it, and '
            'a failure reverts. Tap it, the heart fills.',
        child: Row(
          children: [
            for (final t in fixtureTracks.take(4)) ...[
              FavouriteButton(trackId: t.id),
              const SizedBox(width: AriaSpace.s2),
            ],
          ],
        ),
      ),
      Section(
        title: 'TrackMenuButton',
        note: 'Opens the full track menu anchored under itself.',
        child: Row(
          children: [
            for (final t in fixtureTracks.take(3))
              TrackMenuButton(track: t),
          ],
        ),
      ),
    ],
  );
}

// ------------------------------------------------------------------ filters

Widget filterBarStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'FilterPill',
        note: 'Selected is a state, so it takes a soft accent tint and an '
            'accent edge; unselected sits on lineStrong because it has no '
            'shadow to help it.',
        child: Wrap(
          spacing: AriaSpace.s2,
          runSpacing: AriaSpace.s2,
          children: [
            FilterPill(label: 'All', selected: true, onTap: () {}),
            FilterPill(label: 'Albums', onTap: () {}),
            FilterPill(label: 'EPs', onTap: () {}),
            FilterPill(label: 'Live', count: 3, onTap: () {}),
            FilterPill(label: 'Filters', count: 2, selected: true, onTap: () {}),
          ],
        ),
      ),
      Section(
        title: 'FilterBar',
        note: 'Scrolls horizontally when it overflows; the trailing slot stays '
            'pinned.',
        child: const _FilterBarDemo(),
      ),
    ],
  );
}

/// Stateful so the pills actually toggle — a filter bar that cannot be
/// operated does not show what a filter bar does.
class _FilterBarDemo extends StatefulWidget {
  const _FilterBarDemo();

  @override
  State<_FilterBarDemo> createState() => _FilterBarDemoState();
}

class _FilterBarDemoState extends State<_FilterBarDemo> {
  String _selected = 'All';

  @override
  Widget build(BuildContext context) {
    const options = ['All', 'Album', 'EP', 'Single', 'Compilation', 'Live'];
    return FilterBar(
      trailing: TextButton(onPressed: () {}, child: const Text('Sort')),
      children: [
        for (final o in options)
          FilterPill(
            label: o,
            selected: _selected == o,
            onTap: () => setState(() => _selected = o),
          ),
      ],
    );
  }
}

Widget multiSelectStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'MultiSelectField',
        note: 'Shared by the library Tracks filter and the smart-playlist '
            'editor. The option list appears while the search box has focus '
            '(capped at 200 hits — searching is how you narrow down), and the '
            'AND/OR combinator appears only once two values are picked.',
        child: const _MultiSelectDemo(),
      ),
    ],
  );
}

class _MultiSelectDemo extends StatelessWidget {
  const _MultiSelectDemo();

  // The widget mutates this in place; the enclosing form owns it in the app.
  static final _genre = MultiSelectState(vals: ['Jazz']);
  static final _artist = MultiSelectState();

  @override
  Widget build(BuildContext context) {
    final artists = {
      for (final t in fixtureTracks) t.albumArtist ?? t.artist ?? '',
    }..remove('');
    final genres = {for (final t in fixtureTracks) ...t.genres};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MultiSelectField(
          label: 'Genre',
          options: genres.toList()..sort(),
          state: _genre,
        ),
        const SizedBox(height: AriaSpace.s6),
        MultiSelectField(
          label: 'Primary artist',
          options: artists.toList()..sort(),
          state: _artist,
        ),
      ],
    );
  }
}

// ------------------------------------------------------------- empty states

Widget emptyStateStory(BuildContext context) {
  final message = context.knobs.string(
    label: 'message',
    initialValue: 'Nothing here yet.',
  );
  final withIcon = context.knobs.boolean(label: 'icon', initialValue: true);
  final withAction = context.knobs.boolean(label: 'action', initialValue: true);

  return StoryPage(
    children: [
      Section(
        title: 'EmptyState',
        note: 'Centred dim message with an optional icon and one call to '
            'action. Used wherever a list can legitimately be empty.',
        child: SizedBox(
          height: 320,
          child: EmptyState(
            message: message,
            icon: withIcon ? PhosphorIconsThin.vinylRecord : null,
            action: withAction
                ? FilledButton(onPressed: () {}, child: const Text('Scan library'))
                : null,
          ),
        ),
      ),
      Section(
        title: 'In place',
        child: Column(
          children: [
            SizedBox(
              height: 240,
              child: EmptyState(
                message: 'No albums match these filters.',
                icon: PhosphorIconsThin.magnifyingGlass,
              ),
            ),
            const SizedBox(height: AriaSpace.s6),
            const SizedBox(
              height: 200,
              child: EmptyState(message: 'Your queue is empty.'),
            ),
          ],
        ),
      ),
    ],
  );
}

// -------------------------------------------------------------------- shelf

Widget shelfStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'Shelf',
        note: 'Horizontal scroller with a section header and paging arrows. '
            'Cards are sized from the band-fixed column count so a shelf card '
            'and a grid card come out the same width; flicks snap to a card '
            'edge rather than settling mid-card.',
        child: Shelf(
          title: 'Recently added',
          height: 236,
          itemCount: fixtureAlbums.length,
          onSeeAll: () {},
          itemBuilder: (context, i) {
            final album = fixtureAlbums[i];
            return AlbumCard(
              title: album.title,
              subtitle: album.albumArtist,
              artUrl: album.hasArt ? artUrlFor(album.id) : null,
              onTap: () {},
            );
          },
        ),
      ),
      Section(
        title: 'Person shelf',
        note: 'Denser: more full cards on mobile, one extra column elsewhere, '
            'because avatar discs need less width than covers.',
        child: Shelf(
          title: 'Artists',
          height: 168,
          itemCount: fixtureArtists.length,
          mobileColumns: 4,
          extraColumns: 1,
          itemBuilder: (context, i) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ArtistAvatar(name: fixtureArtists[i], size: 96),
              const SizedBox(height: AriaSpace.s2),
              Text(
                fixtureArtists[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

// ------------------------------------------------------- menus, sheets, bars

Widget contextMenuStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'showAriaContextMenu',
        note: 'Right-click or long-press, opened at the pointer. Destructive '
            'entries take the error colour for both icon and label.',
        child: Builder(
          builder: (context) => Wrap(
            spacing: AriaSpace.s3,
            children: [
              FilledButton(
                onPressed: () {
                  final box = context.findRenderObject()! as RenderBox;
                  showAriaContextMenu(
                    context,
                    box.localToGlobal(const Offset(0, 44)),
                    [
                      AriaMenuItem('Play now', () {},
                          icon: PhosphorIconsRegular.play),
                      AriaMenuItem('Play next', () {},
                          icon: PhosphorIconsRegular.listPlus),
                      AriaMenuItem('Add to queue', () {},
                          icon: PhosphorIconsRegular.queue),
                      AriaMenuItem('Tag…', () {},
                          icon: PhosphorIconsRegular.tag),
                      AriaMenuItem('Remove', () {},
                          icon: PhosphorIconsRegular.trash, destructive: true),
                    ],
                  );
                },
                child: const Text('Open menu'),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

/// The tag sheets, split out from the menu above: they are their own
/// components, and a catalogue that hides them behind a "menus" page is a
/// catalogue you cannot find them in.
Widget tagPickerStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'showTagPicker',
        note: 'Reads live provider data — it lists the fixture tags, and '
            'creating one really POSTs to the stub server.',
        child: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showTagPicker(
              context,
              kind: 'album',
              key: 'a-kind-of-blue',
            ),
            child: const Text('Tag an album'),
          ),
        ),
      ),
      Section(
        title: 'showBulkTagMenu',
        note: 'Same sheet over a mixed selection: a checkbox is tri-state '
            'when only some of the items carry the tag.',
        child: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showBulkTagMenu(
              context,
              items: const [
                TagItem(kind: 'album', key: 'a-kind-of-blue'),
                TagItem(kind: 'track', key: 'vanguard-1'),
              ],
            ),
            child: const Text('Tag two items'),
          ),
        ),
      ),
    ],
  );
}

Widget playlistSheetStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'showAddToPlaylistMenu',
        note: 'Lists the fixture playlists; the smart one is not offered, '
            'because its membership is a query and not a list.',
        child: Builder(
          builder: (context) => FilledButton(
            onPressed: () =>
                showAddToPlaylistMenu(context, tracks: fixtureTracks),
            child: const Text('Add 8 tracks'),
          ),
        ),
      ),
    ],
  );
}

Widget nameDialogStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'promptName',
        note: 'One text field, Cancel and a Save that ignores an empty '
            'field. Resolves to the trimmed name, or null on cancel.',
        child: Builder(
          builder: (context) => Wrap(
            spacing: AriaSpace.s3,
            children: [
              FilledButton(
                onPressed: () => promptName(
                  context,
                  title: 'New playlist',
                  placeholder: 'Playlist name',
                ),
                child: const Text('Empty'),
              ),
              FilledButton(
                onPressed: () => promptName(
                  context,
                  title: 'Rename playlist',
                  placeholder: 'Playlist name',
                  initial: 'Morning',
                ),
                child: const Text('Prefilled'),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

/// Selection is app-wide state, so this page drives the real notifier — the
/// highlight, the bar and its counter all come from one source.
Widget selectionStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'SelectionHighlight',
        note: 'Accent border and tint painted as a FOREGROUND decoration, so '
            'wrapping a card in it never shifts layout. Tap the cards below to '
            'toggle them in and out of the selection.',
        child: Consumer(
          builder: (context, ref, _) {
            final selection = ref.watch(selectionProvider);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AriaSpace.s5,
                  runSpacing: AriaSpace.s5,
                  children: [
                    for (final album in fixtureAlbums)
                      SizedBox(
                        width: 170,
                        child: GestureDetector(
                          onTap: () => ref
                              .read(selectionProvider.notifier)
                              .toggle(SelectionItem(
                                kind: 'album',
                                key: album.id,
                                tracks: album.tracks,
                              )),
                          child: SelectionHighlight(
                            kind: 'album',
                            itemKey: album.id,
                            child: AlbumCard(
                              title: album.title,
                              subtitle: album.albumArtist,
                              artUrl:
                                  album.hasArt ? artUrlFor(album.id) : null,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AriaSpace.s5),
                Text(
                  selection.active
                      ? '${selection.items.length} selected · '
                          '${selection.tracks.length} tracks'
                      : 'not in select mode — tap a card',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            );
          },
        ),
      ),
      const Section(
        title: 'SelectionBar',
        note: 'Hidden entirely until selection is active.',
        child: SelectionBar(),
      ),
    ],
  );
}

// --------------------------------------------------- theme-level components

/// Buttons, inputs and chrome that come from ThemeData rather than a widget
/// in lib/widgets — the catalogue is incomplete without them, since they are
/// what the app actually renders for a button or a text field.
Widget controlStory(BuildContext context) {
  final c = AriaColors.of(context);
  return StoryPage(
    children: [
      Section(
        title: 'Buttons',
        note: 'Primary actions carry the accent as a stadium pill at weight '
            '600 — the legacy "play all" shape. Everything else is a text '
            'button.',
        child: Wrap(
          spacing: AriaSpace.s3,
          runSpacing: AriaSpace.s3,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton(onPressed: () {}, child: const Text('Play all')),
            const FilledButton(onPressed: null, child: Text('Disabled')),
            TextButton(onPressed: () {}, child: const Text('Text button')),
            const TextButton(onPressed: null, child: Text('Disabled')),
            OutlinedButton(onPressed: () {}, child: const Text('Outlined')),
            IconButton(
              onPressed: () {},
              icon: const Icon(PhosphorIconsRegular.play),
            ),
          ],
        ),
      ),
      Section(
        title: 'Inputs',
        note: 'Borders sit on lineStrong (3.3:1 — the WCAG minimum for a UI '
            'component edge) and go accent at 2px on focus.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const TextField(
              decoration: InputDecoration(hintText: 'Search the library'),
            ),
            const SizedBox(height: AriaSpace.s4),
            const TextField(
              decoration: InputDecoration(
                hintText: 'With an error',
                errorText: 'Could not reach the server',
              ),
            ),
            const SizedBox(height: AriaSpace.s4),
            Row(
              children: [
                DropdownButton<String>(
                  value: 'any',
                  onChanged: (_) {},
                  items: const [
                    DropdownMenuItem(value: 'any', child: Text('match any (OR)')),
                    DropdownMenuItem(value: 'all', child: Text('match all (AND)')),
                  ],
                ),
                const SizedBox(width: AriaSpace.s5),
                Switch(value: true, onChanged: (_) {}),
                Checkbox(value: true, onChanged: (_) {}),
              ],
            ),
            const SizedBox(height: AriaSpace.s4),
            Wrap(
              spacing: AriaSpace.s2,
              children: [
                for (final t in ['Jazz', 'Classical', 'Live'])
                  InputChip(label: Text(t), onDeleted: () {}),
              ],
            ),
          ],
        ),
      ),
      Section(
        title: 'Toast',
        note: 'A top-anchored, fully opaque SnackBar — it rides at the top so '
            'it clears the floating transport at the bottom. Neutral notices '
            'on charcoal, errors on the accent.',
        child: Builder(
          builder: (context) => Wrap(
            spacing: AriaSpace.s3,
            children: [
              FilledButton(
                onPressed: () => Toaster.of(context)
                    .show('Added 3 tracks to "Morning"'),
                child: const Text('Notice'),
              ),
              FilledButton(
                onPressed: () => Toaster.of(context)
                    .show('Could not reach the server.', error: true),
                child: const Text('Error'),
              ),
            ],
          ),
        ),
      ),
      Section(
        title: 'Navigation',
        note: 'Selected takes an accent-tinted pill with accent icon and '
            'label; the rail is flat on the canvas and set off only by its '
            'edge divider.',
        child: SizedBox(
          height: 260,
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: c.lineStrong)),
                ),
                child: NavigationRail(
                  selectedIndex: 1,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (_) {},
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(PhosphorIconsThin.house),
                      selectedIcon: Icon(PhosphorIconsFill.house),
                      label: Text('Home'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(PhosphorIconsThin.vinylRecord),
                      selectedIcon: Icon(PhosphorIconsFill.vinylRecord),
                      label: Text('Library'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(PhosphorIconsThin.chartBar),
                      selectedIcon: Icon(PhosphorIconsFill.chartBar),
                      label: Text('Stats'),
                    ),
                  ],
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    ],
  );
}

// ------------------------------------------------------------------ shelves

/// The two unowned-album shelves. Both read the stub server, and both render
/// nothing at all when it has no rows — which is the behaviour, not a gap.
Widget listenLaterShelfStory(BuildContext context) {
  return StoryPage(
    children: [
      const Section(
        title: 'ListenLaterShelf',
        note: 'Saved-for-later albums, capped at 20. Each card carries a '
            'Remove entry in its context menu, which really DELETEs against '
            'the stub.',
        child: ListenLaterShelf(),
      ),
    ],
  );
}

Widget newReleasesShelfStory(BuildContext context) {
  return StoryPage(
    children: [
      const Section(
        title: 'NewReleasesShelf',
        note: 'Recent releases by library artists that the library does not '
            'have. Empty server response means no shelf, not an empty shelf.',
        child: NewReleasesShelf(),
      ),
      Section(
        title: 'NewReleaseCard',
        note: 'One card. The sub-line is assembled from artist, release '
            'month, type (omitted for a plain album) and "Not in library".',
        child: Wrap(
          spacing: AriaSpace.s5,
          runSpacing: AriaSpace.s5,
          children: [
            for (final item in fixtureNewReleases)
              Variant(
                width: 190,
                label: item.cover == null ? 'no cover' : item.type,
                child: NewReleaseCard(item: item),
              ),
          ],
        ),
      ),
    ],
  );
}

// ------------------------------------------------------------- wrappers

/// [ArtistTile] adds nothing visual — it is the artist context menu and the
/// selection payload wrapped round whatever you give it. Shown over both the
/// things the app wraps in it.
Widget artistTileStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ArtistTile',
        note: 'Right-click either tile: the menu plays, queues and tags every '
            'track by that artist. tracksOf is a callback, so the track list '
            'is only assembled when the menu opens.',
        child: Wrap(
          spacing: AriaSpace.s6,
          runSpacing: AriaSpace.s5,
          children: [
            for (final name in ['Miles Davis', 'Glenn Gould'])
              Variant(
                label: name,
                child: ArtistTile(
                  name: name,
                  tracksOf: () => [
                    for (final t in fixtureTracks)
                      if (t.artist == name) t,
                  ],
                  child: ArtistAvatar(name: name, size: 96),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

/// The fallback chain behind every avatar: try each URL in turn, and show the
/// fallback widget once the list runs out.
Widget chainImageStory(BuildContext context) {
  return StoryPage(
    children: [
      Section(
        title: 'ChainImage',
        note: 'The LAN portrait proxy first, then the raw CDN URL, then '
            'initials — a 404 from the proxy advances the chain rather than '
            'showing a broken image.',
        child: Wrap(
          spacing: AriaSpace.s6,
          children: [
            Variant(
              label: 'first URL resolves',
              child: SizedBox.square(
                dimension: 96,
                child: ChainImage(
                  urls: [storybookClient.peopleImgUrl('Miles Davis')],
                  fallback: const ColoredBox(color: Color(0x22000000)),
                  cacheWidth: 192,
                ),
              ),
            ),
            Variant(
              label: 'first fails, second resolves',
              child: SizedBox.square(
                dimension: 96,
                child: ChainImage(
                  urls: [
                    'http://127.0.0.1:1/nope.png',
                    storybookClient.peopleImgUrl('Bill Evans Trio'),
                  ],
                  fallback: const ColoredBox(color: Color(0x22000000)),
                  cacheWidth: 192,
                ),
              ),
            ),
            Variant(
              label: 'chain exhausted',
              child: SizedBox.square(
                dimension: 96,
                child: ChainImage(
                  urls: const ['http://127.0.0.1:1/nope.png'],
                  fallback: const ArtistAvatar(name: 'Ella Fitzgerald'),
                  cacheWidth: 192,
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final componentEntries = <Entry>[
  Entry(
    folder: 'Art',
    component: 'ArtImage',
    useCase: 'Cover & fallback',
    key: 'art-image',
    builder: artImageStory,
  ),
  Entry(
    folder: 'Art',
    component: 'ArtistAvatar',
    useCase: 'Portrait & initials',
    key: 'artist-avatar',
    builder: artistAvatarStory,
  ),
  Entry(
    folder: 'Art',
    component: 'ChainImage',
    useCase: 'Fallback chain',
    key: 'chain-image',
    builder: chainImageStory,
  ),
  Entry(
    folder: 'Cards',
    component: 'AlbumCard',
    useCase: 'States',
    key: 'album-card',
    builder: albumCardStory,
  ),
  Entry(
    folder: 'Cards',
    component: 'AlbumGridCard',
    useCase: 'Wired grid',
    key: 'album-grid-card',
    builder: albumGridCardStory,
  ),
  Entry(
    folder: 'Cards',
    component: 'UnownedAlbumCard',
    useCase: 'Not in library',
    key: 'unowned-album-card',
    builder: unownedAlbumCardStory,
  ),
  Entry(
    folder: 'Cards',
    component: 'ArtistTile',
    useCase: 'Menu wrapper',
    key: 'artist-tile',
    builder: artistTileStory,
  ),
  Entry(
    folder: 'Lists',
    component: 'TrackRow',
    useCase: 'States',
    key: 'track-row',
    builder: trackRowStory,
  ),
  Entry(
    folder: 'Lists',
    component: 'FormatBadge',
    useCase: 'Lossless, hi-res, lossy',
    key: 'format-badge',
    builder: formatBadgeStory,
  ),
  Entry(
    folder: 'Lists',
    component: 'Shelf',
    useCase: 'Horizontal',
    key: 'shelf',
    builder: shelfStory,
  ),
  Entry(
    folder: 'Lists',
    component: 'ListenLaterShelf',
    useCase: 'Saved albums',
    key: 'listen-later-shelf',
    builder: listenLaterShelfStory,
  ),
  Entry(
    folder: 'Lists',
    component: 'NewReleasesShelf',
    useCase: 'Shelf & card',
    key: 'new-releases-shelf',
    builder: newReleasesShelfStory,
  ),
  Entry(
    folder: 'Controls',
    component: 'Theme controls',
    useCase: 'Buttons, inputs, toast, nav',
    key: 'controls',
    builder: controlStory,
  ),
  Entry(
    folder: 'Controls',
    component: 'FilterBar',
    useCase: 'Pills',
    key: 'filter-bar',
    builder: filterBarStory,
  ),
  Entry(
    folder: 'Controls',
    component: 'MultiSelectField',
    useCase: 'Search & chips',
    key: 'multi-select',
    builder: multiSelectStory,
  ),
  Entry(
    folder: 'Controls',
    component: 'Track actions',
    useCase: 'Favourite & menu',
    key: 'track-actions',
    builder: trackActionStory,
  ),
  Entry(
    folder: 'Overlays & states',
    component: 'Context menu',
    useCase: 'Menu at the pointer',
    key: 'context-menu',
    builder: contextMenuStory,
  ),
  Entry(
    folder: 'Overlays & states',
    component: 'Tag picker',
    useCase: 'Single & bulk',
    key: 'tag-picker',
    builder: tagPickerStory,
  ),
  Entry(
    folder: 'Overlays & states',
    component: 'Playlist sheet',
    useCase: 'Add to playlist',
    key: 'playlist-sheet',
    builder: playlistSheetStory,
  ),
  Entry(
    folder: 'Overlays & states',
    component: 'Name dialog',
    useCase: 'New & rename',
    key: 'name-dialog',
    builder: nameDialogStory,
  ),
  Entry(
    folder: 'Overlays & states',
    component: 'Selection',
    useCase: 'Highlight & bar',
    key: 'selection',
    builder: selectionStory,
  ),
  Entry(
    folder: 'Overlays & states',
    component: 'EmptyState',
    useCase: 'Message, icon, action',
    key: 'empty-state',
    builder: emptyStateStory,
  ),
];
