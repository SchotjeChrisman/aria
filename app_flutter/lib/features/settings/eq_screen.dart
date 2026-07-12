import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';
import 'eq_browse.dart';

/// OPRA database, fetched once per app run (the server caches it for a week).
final opraProvider = FutureProvider<List<OpraProduct>>(
  (ref) => ref.watch(apiClientProvider).eqOpra(),
);

/// Headphone EQ entry: master switch, two layers (headphone + custom), a
/// favourites shortcut, the OPRA drill-down, and the custom-preset editor.
class EqScreen extends ConsumerStatefulWidget {
  const EqScreen({super.key});

  @override
  ConsumerState<EqScreen> createState() => _EqScreenState();
}

class _EqScreenState extends ConsumerState<EqScreen> {
  Future<void> _editCustom({EqProfile? preset, int? index}) async {
    final edited = await showDialog<EqProfile>(
      context: context,
      builder: (_) => _CustomEqDialog(preset: preset),
    );
    if (edited == null) return;
    final presets = List.of(ref.read(customEqPresetsProvider));
    if (index == null) {
      presets.add(edited);
    } else {
      presets[index] = edited;
    }
    ref.read(customEqPresetsProvider.notifier).set(presets);
    // Editing the preset in the custom slot updates it in place (matched on its
    // previous name, so a rename still re-points the slot) — the master enabled
    // switch stays as the user left it.
    if (index != null) {
      ref.read(eqProvider.notifier).updateCustom(preset?.name ?? '', edited);
    }
  }

  @override
  Widget build(BuildContext context) {
    final eq = ref.watch(eqProvider);
    final custom = ref.watch(customEqPresetsProvider);
    final favourites = ref.watch(favouriteEqProvider);
    final theme = Theme.of(context);

    Widget header(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(
        AriaSpace.s4,
        AriaSpace.s4,
        AriaSpace.s4,
        AriaSpace.s2,
      ),
      child: Text(title, style: theme.textTheme.titleMedium),
    );

    // A layer slot row: current pick or 'None' with a clear (×) trailing.
    Widget slot(String label, EqProfile? p, void Function() clear) => ListTile(
      title: Text('$label: ${p?.name ?? 'None'}'),
      trailing: p == null
          ? null
          : IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Clear',
              onPressed: clear,
            ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Headphone EQ')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: transportFloatInset),
        children: [
          SwitchListTile(
            title: const Text('EQ enabled'),
            value: eq.enabled,
            // No layer to apply → nothing to switch on (matches playback_screen).
            onChanged: eq.headphone == null && eq.custom == null
                ? null
                : (v) => ref.read(eqProvider.notifier).setEnabled(v),
          ),
          const Divider(),
          slot(
            'Headphone',
            eq.headphone,
            () => ref.read(eqProvider.notifier).selectHeadphone(null),
          ),
          slot(
            'Custom EQ',
            eq.custom,
            () => ref.read(eqProvider.notifier).selectCustom(null),
          ),
          if (favourites.isNotEmpty) ...[
            header('★ Favourites'),
            for (final f in favourites)
              ListTile(
                title: Text(f.name ?? 'Favourite'),
                selected: eq.headphone?.name == f.name,
                onTap: () =>
                    ref.read(eqProvider.notifier).selectHeadphone(f),
                trailing: IconButton(
                  icon: const Icon(Icons.star),
                  tooltip: 'Un-favourite',
                  onPressed: () =>
                      ref.read(favouriteEqProvider.notifier).toggle(f),
                ),
              ),
          ],
          ListTile(
            leading: const Icon(Icons.headphones_outlined),
            title: const Text('Choose headphone'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => pushEqBrands(context),
          ),
          header('Custom EQ'),
          for (final (i, p) in custom.indexed)
            ListTile(
              title: Text(p.name ?? 'Custom'),
              subtitle: Text('${p.bands.length} bands'),
              selected: eq.custom?.name == p.name,
              onTap: () => ref.read(eqProvider.notifier).selectCustom(p),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => _editCustom(preset: p, index: i),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () {
                      // Deleting the preset in the custom slot clears it — the
                      // notifier doesn't watch this list, so do it here.
                      if (eq.custom?.name == p.name) {
                        ref.read(eqProvider.notifier).selectCustom(null);
                      }
                      ref
                          .read(customEqPresetsProvider.notifier)
                          .set(List.of(custom)..removeAt(i));
                    },
                  ),
                ],
              ),
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Add custom EQ'),
            onTap: _editCustom,
          ),
        ],
      ),
    );
  }
}

/// Plain custom-EQ editor: name, preamp, band rows.
class _CustomEqDialog extends StatefulWidget {
  const _CustomEqDialog({this.preset});

  final EqProfile? preset;

  @override
  State<_CustomEqDialog> createState() => _CustomEqDialogState();
}

class _BandEdit {
  _BandEdit(EqBand b)
    : type = b.type,
      freq = TextEditingController(text: '${b.frequency}'),
      gain = TextEditingController(text: '${b.gainDb}'),
      q = TextEditingController(text: '${b.q ?? 1.0}');

  String type;
  final TextEditingController freq;
  final TextEditingController gain;
  final TextEditingController q;

  void dispose() {
    freq.dispose();
    gain.dispose();
    q.dispose();
  }
}

class _CustomEqDialogState extends State<_CustomEqDialog> {
  static const _types = [
    'peak_dip',
    'low_shelf',
    'high_shelf',
    'low_pass',
    'high_pass',
    'band_pass',
    'band_stop',
  ];

  late final _name = TextEditingController(
    text: widget.preset?.name ?? 'Custom',
  );
  late final _preamp = TextEditingController(
    text: '${widget.preset?.gainDb ?? 0.0}',
  );
  late final List<_BandEdit> _bands = [
    for (final b in widget.preset?.bands ??
        const [EqBand(type: 'peak_dip', frequency: 1000)])
      _BandEdit(b),
  ];

  @override
  void dispose() {
    _name.dispose();
    _preamp.dispose();
    for (final b in _bands) {
      b.dispose();
    }
    super.dispose();
  }

  void _save() {
    final preamp = double.tryParse(_preamp.text) ?? 0;
    final bands = [
      for (final b in _bands)
        EqBand(
          type: b.type,
          frequency: double.tryParse(b.freq.text) ?? 1000,
          gainDb: double.tryParse(b.gain.text) ?? 0,
          q: double.tryParse(b.q.text) ?? 1,
        ),
    ];
    // mpv silently rejects out-of-range biquads — refuse to save them.
    final invalid = preamp.abs() > 24 ||
        bands.any(
          (b) =>
              b.frequency <= 0 ||
              b.frequency > 96000 ||
              (b.q ?? 1) < 0.1 ||
              b.gainDb.abs() > 30,
        );
    if (invalid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Invalid EQ: frequency 1–96000 Hz, Q ≥ 0.1, '
            'band gain ±30 dB, preamp ±24 dB.',
          ),
        ),
      );
      return;
    }
    Navigator.pop(
      context,
      EqProfile(
        name: _name.text.trim().isEmpty ? 'Custom' : _name.text.trim(),
        gainDb: preamp,
        bands: bands,
      ),
    );
  }

  Widget _num(TextEditingController c, String label) => Expanded(
    child: TextField(
      controller: c,
      decoration: InputDecoration(labelText: label),
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.preset == null ? 'New custom EQ' : 'Edit custom EQ'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: AriaSpace.s3),
              TextField(
                controller: _preamp,
                decoration: const InputDecoration(labelText: 'Preamp (dB)'),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
              ),
              const SizedBox(height: AriaSpace.s4),
              for (final (i, b) in _bands.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: AriaSpace.s3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      DropdownButton<String>(
                        value: b.type,
                        items: [
                          for (final t in _types)
                            DropdownMenuItem(value: t, child: Text(t)),
                        ],
                        onChanged: (t) =>
                            setState(() => b.type = t ?? b.type),
                      ),
                      const SizedBox(width: AriaSpace.s3),
                      _num(b.freq, 'Hz'),
                      const SizedBox(width: AriaSpace.s2),
                      _num(b.gain, 'dB'),
                      const SizedBox(width: AriaSpace.s2),
                      _num(b.q, 'Q'),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () =>
                            setState(() => _bands.removeAt(i).dispose()),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add band'),
                  onPressed: () => setState(
                    () => _bands.add(
                      _BandEdit(
                        const EqBand(type: 'peak_dip', frequency: 1000),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
