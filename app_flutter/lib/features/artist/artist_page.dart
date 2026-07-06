import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/filter_bar.dart';
import '../../widgets/tag_picker.dart';
import '../../widgets/track_actions.dart';
import 'artist_discography.dart';
import 'artist_info_tab.dart';
import 'artist_overview.dart';
import 'edit_artist_dialog.dart';
import 'providers.dart';
import 'reidentify_artist_dialog.dart';

/// The Roon experience: one page per person, with in-page tabs
/// (legacy renderPerson): Overview / Info (full bio) / Discography.
class ArtistPage extends ConsumerStatefulWidget {
  const ArtistPage({super.key, required this.name});

  final String name;

  @override
  ConsumerState<ArtistPage> createState() => _ArtistPageState();
}

const _tabs = [
  ('overview', 'Overview'),
  ('info', 'Info'),
  ('discography', 'Discography'),
];

class _ArtistPageState extends ConsumerState<ArtistPage> {
  String _tab = 'overview';

  void showFullBio() => setState(() => _tab = 'info');

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AriaSpace.s6),
          children: [
            if (context.canPop())
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => context.pop(),
                  child: Text('← Back', style: TextStyle(color: c.fgDim)),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.name,
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Builder(
                  builder: (bctx) => OutlinedButton.icon(
                    onPressed: () => _editMenu(bctx),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: AriaSpace.s3),
                // Legacy artistCtx: Play all / Add to queue / Tags / Select.
                Builder(
                  builder: (bctx) => IconButton(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () => _playMenu(bctx),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AriaSpace.s4),
            FilterBar(
              children: [
                for (final (id, label) in _tabs)
                  FilterPill(
                    label: label,
                    selected: _tab == id,
                    onTap: () => setState(() => _tab = id),
                  ),
              ],
            ),
            const SizedBox(height: AriaSpace.s5),
            switch (_tab) {
              'info' => ArtistInfoTab(name: widget.name),
              'discography' => ArtistDiscography(name: widget.name),
              _ => ArtistOverview(name: widget.name, onMoreBio: showFullBio),
            },
          ],
        ),
      ),
    );
  }

  static Offset _anchor(BuildContext buttonCtx) {
    final box = buttonCtx.findRenderObject() as RenderBox?;
    return box == null
        ? Offset.zero
        : box.localToGlobal(Offset(0, box.size.height));
  }

  /// Everything credited to this person (legacy artistCtx track gather).
  List<Track> _artistTracks() {
    final all = ref.read(artistTracksProvider).value ?? const <Track>[];
    return [
      for (final t in all)
        if (t.artist == widget.name || t.albumArtist == widget.name) t,
    ];
  }

  // Legacy editMenu for artists.
  void _editMenu(BuildContext buttonCtx) {
    showAriaContextMenu(buttonCtx, _anchor(buttonCtx), [
      AriaMenuItem(
        'Edit metadata…',
        () => showArtistEditor(context, ref, widget.name),
        icon: Icons.edit_outlined,
      ),
      AriaMenuItem(
        'Tags…',
        () => showTagPicker(context, kind: 'artist', key: widget.name),
        icon: Icons.sell_outlined,
      ),
      AriaMenuItem(
        'Re-identify…',
        () => showArtistReidentify(context, ref, widget.name),
        icon: Icons.sync,
      ),
    ]);
  }

  void _playMenu(BuildContext buttonCtx) {
    showAriaContextMenu(
      buttonCtx,
      _anchor(buttonCtx),
      artistMenuItems(context, ref, name: widget.name, tracks: _artistTracks()),
    );
  }
}
