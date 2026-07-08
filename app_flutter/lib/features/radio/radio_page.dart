import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../widgets/empty_state.dart';
import 'radio_providers.dart';

class RadioPage extends ConsumerStatefulWidget {
  const RadioPage({super.key});

  @override
  ConsumerState<RadioPage> createState() => _RadioPageState();
}

class _RadioPageState extends ConsumerState<RadioPage> {
  bool _adding = false;

  @override
  Widget build(BuildContext context) {
    final stations = ref.watch(radioStationsProvider);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AriaSpace.s6),
          children: [
            Text('Radio', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AriaSpace.s4),
            if (!_adding)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: () => setState(() => _adding = true),
                  child: const Text('＋ Add station'),
                ),
              )
            else
              _StationForm(onDone: () => setState(() => _adding = false)),
            const SizedBox(height: AriaSpace.s5),
            switch (stations) {
              AsyncError() => const EmptyState(
                message: 'Radio unavailable.',
                icon: Icons.radio,
              ),
              AsyncData(:final value) when value.isEmpty => const EmptyState(
                message: 'No stations.',
                icon: Icons.radio,
              ),
              AsyncData(:final value) => _StationGroups(stations: value),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ],
        ),
      ),
    );
  }
}

class _StationGroups extends StatelessWidget {
  const _StationGroups({required this.stations});

  final List<RadioStation> stations;

  @override
  Widget build(BuildContext context) {
    // Legacy renderRadio grouping: by genre, alphabetical, genre-less
    // ("Custom") stations always last.
    final groups = <String, List<RadioStation>>{};
    for (final st in stations) {
      final g = (st.genre == null || st.genre!.isEmpty) ? 'Custom' : st.genre!;
      (groups[g] ??= []).add(st);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        final ca = a == 'Custom' ? 1 : 0;
        final cb = b == 'Custom' ? 1 : 0;
        return ca != cb ? ca - cb : a.compareTo(b);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final g in keys) ...[
          Text(g, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AriaSpace.s3),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              // Station cards were 260px-wide Wrap chips — meaningfully wider
              // than album tiles, so they get their own fixed per-band counts
              // instead of gridColumns.
              crossAxisCount: switch (AriaBreakpoint.of(context)) {
                AriaBreakpoint.mobile => 1,
                AriaBreakpoint.tablet => 2,
                AriaBreakpoint.desktop => 4,
              },
              mainAxisSpacing: AriaSpace.s3,
              crossAxisSpacing: AriaSpace.s3,
              mainAxisExtent: 80,
            ),
            itemCount: groups[g]!.length,
            itemBuilder: (context, i) => _RadioCard(station: groups[g]![i]),
          ),
          const SizedBox(height: AriaSpace.s6),
        ],
      ],
    );
  }
}

class _RadioCard extends ConsumerWidget {
  const _RadioCard({required this.station});

  final RadioStation station;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = AriaColors.of(context);
    final isCurrent = ref.watch(radioPlaybackProvider)?.id == station.id;
    // Legacy: the stream codec is opaque; FLAC in the URL is the honest tell.
    final flac = station.url.toLowerCase().contains('flac');

    return InkWell(
      onTap: () => ref.read(radioPlaybackProvider.notifier).play(station),
      borderRadius: BorderRadius.circular(AriaRadius.md),
      child: Container(
        padding: const EdgeInsets.all(AriaSpace.s4),
        decoration: BoxDecoration(
          color: c.bgRaised,
          borderRadius: BorderRadius.circular(AriaRadius.md),
          border: Border.all(color: isCurrent ? c.accent : c.line),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    station.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      color: isCurrent ? c.accent : c.fg,
                    ),
                  ),
                  Text(
                    '${station.builtin ? 'Built-in' : 'Custom'}'
                    '${flac ? ' · FLAC' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.play_arrow, color: c.fg),
              tooltip: 'Play station',
              onPressed: () =>
                  ref.read(radioPlaybackProvider.notifier).play(station),
            ),
            if (!station.builtin)
              IconButton(
                icon: Icon(Icons.close, size: 18, color: c.fgDim),
                tooltip: 'Remove station',
                onPressed: () => _confirmDelete(context, ref),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove station "${station.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(radioActionsProvider).delete(station.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not remove station.')),
        );
      }
    }
  }
}

/// Legacy stationForm: name + URL + optional genre, Enter submits.
class _StationForm extends ConsumerStatefulWidget {
  const _StationForm({required this.onDone});

  final VoidCallback onDone;

  @override
  ConsumerState<_StationForm> createState() => _StationFormState();
}

class _StationFormState extends ConsumerState<_StationForm> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _genre = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _genre.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (name.isEmpty) return;
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(radioActionsProvider)
          .add(name: name, url: url, genre: _genre.text.trim());
      widget.onDone();
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not add station.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AriaSpace.s2,
      runSpacing: AriaSpace.s2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 200,
          child: TextField(
            controller: _name,
            autofocus: true,
            maxLength: 60,
            decoration: const InputDecoration(
              hintText: 'Station name',
              counterText: '',
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
        SizedBox(
          width: 280,
          child: TextField(
            controller: _url,
            decoration: const InputDecoration(hintText: 'https://stream…'),
            onSubmitted: (_) => _submit(),
          ),
        ),
        SizedBox(
          width: 160,
          child: TextField(
            controller: _genre,
            maxLength: 40,
            decoration: const InputDecoration(
              hintText: 'Genre (optional)',
              counterText: '',
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: const Text('Add'),
        ),
        TextButton(onPressed: widget.onDone, child: const Text('Cancel')),
      ],
    );
  }
}
