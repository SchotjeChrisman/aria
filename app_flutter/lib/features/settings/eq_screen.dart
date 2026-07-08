import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/connection.dart';
import '../../core/player_providers.dart';
import '../../core/theme.dart';

/// OPRA database, fetched once per app run (the server caches it for a week).
final opraProvider = FutureProvider<List<OpraProduct>>(
  (ref) => ref.watch(apiClientProvider).eqOpra(),
);

/// Headphone EQ picker: OPRA (Roon Labs) product list + user custom presets.
class EqScreen extends ConsumerStatefulWidget {
  const EqScreen({super.key});

  @override
  ConsumerState<EqScreen> createState() => _EqScreenState();
}

class _EqScreenState extends ConsumerState<EqScreen> {
  String _query = '';

  void _select(EqProfile eq, String name) {
    ref
        .read(eqProvider.notifier)
        .select(EqProfile(name: name, gainDb: eq.gainDb, bands: eq.bands));
  }

  /// Single EQ selects directly; several offer an author picker.
  Future<void> _pick(OpraProduct p) async {
    final name = '${p.vendor} ${p.product}';
    if (p.eqs.length == 1) {
      _select(p.eqs.single, '$name · ${p.eqs.single.author}');
      return;
    }
    final eq = await showDialog<EqProfile>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(name),
        children: [
          for (final e in p.eqs)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, e),
              child: Text(e.author ?? 'unknown'),
            ),
        ],
      ),
    );
    if (eq != null) _select(eq, '$name · ${eq.author}');
  }

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
    // Editing the active preset re-applies it live.
    if (index != null &&
        ref.read(eqProvider).profile?.name == preset?.name) {
      ref.read(eqProvider.notifier).select(edited);
    }
  }

  @override
  Widget build(BuildContext context) {
    final eq = ref.watch(eqProvider);
    final custom = ref.watch(customEqPresetsProvider);
    final opra = ref.watch(opraProvider);
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

    // Everything above the OPRA product list is a fixed widget prefix; the
    // (possibly thousands of) products render lazily behind it.
    final head = <Widget>[
      ListTile(
        title: const Text('Off'),
        selected: eq.profile == null,
        onTap: () => ref.read(eqProvider.notifier).select(null),
      ),
      header('Custom'),
      for (final (i, p) in custom.indexed)
        ListTile(
          title: Text(p.name ?? 'Custom'),
          subtitle: Text('${p.bands.length} bands'),
          selected: eq.profile?.name == p.name,
          onTap: () => ref.read(eqProvider.notifier).select(p),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: () => _editCustom(preset: p, index: i),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => ref
                    .read(customEqPresetsProvider.notifier)
                    .set(List.of(custom)..removeAt(i)),
              ),
            ],
          ),
        ),
      ListTile(
        leading: const Icon(Icons.add),
        title: const Text('Add custom EQ'),
        onTap: _editCustom,
      ),
      header('Opra by Roon'),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Headphone EQ')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AriaSpace.s4),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search headphones…',
              ),
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
            ),
          ),
          Expanded(
            child: opra.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) =>
                  Center(child: Text('Could not load the OPRA database: $e')),
              data: (products) {
                final filtered = [
                  for (final p in products)
                    if ('${p.vendor} ${p.product}'.toLowerCase().contains(
                      _query,
                    ))
                      p,
                ];
                return ListView.builder(
                  itemCount: head.length + filtered.length,
                  itemBuilder: (context, i) {
                    if (i < head.length) return head[i];
                    final p = filtered[i - head.length];
                    final name = '${p.vendor} ${p.product}';
                    return ListTile(
                      title: Text(name),
                      subtitle: Text(
                        p.eqs.length == 1
                            ? (p.eqs.single.author ?? '')
                            : '${p.eqs.length} EQs',
                      ),
                      selected: eq.profile?.name?.startsWith('$name ·') ??
                          false,
                      onTap: () => _pick(p),
                    );
                  },
                );
              },
            ),
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
    Navigator.pop(
      context,
      EqProfile(
        name: _name.text.trim().isEmpty ? 'Custom' : _name.text.trim(),
        gainDb: double.tryParse(_preamp.text) ?? 0,
        bands: [
          for (final b in _bands)
            EqBand(
              type: b.type,
              frequency: double.tryParse(b.freq.text) ?? 1000,
              gainDb: double.tryParse(b.gain.text) ?? 0,
              q: double.tryParse(b.q.text) ?? 1,
            ),
        ],
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
