import 'package:aria_api/aria_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/player_providers.dart';
import '../../core/theme.dart';
import 'eq_screen.dart' show opraProvider;

/// OPRA drill-down: Brands -> Headphones -> Curves. Selecting a curve sets the
/// headphone layer and pops back to the entry screen; the ★ trailing on a curve
/// toggles it as a favourite.

/// Inline status row for the OPRA fetch, shared by all three screens.
Widget _status(AsyncValue<Object?> opra, String loadingMsg) => opra.when(
  data: (_) => const SizedBox.shrink(),
  loading: () => ListTile(
    leading: const SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
    title: Text(loadingMsg),
  ),
  error: (e, _) => ListTile(
    leading: const Icon(Icons.error_outline),
    title: Text('Could not load the OPRA database: $e'),
  ),
);

/// OPRA vendor strings for the big brands, pinned to the top of the empty-query
/// Brands list (exact strings, all verified present in the feed).
const _pinnedBrands = [
  'Sennheiser',
  'Sony',
  'Beyerdynamic',
  'Audio-Technica',
  'HIFIMAN',
  'AKG',
  'Apple',
  'Bose',
  'Beats',
  'JBL',
  'Audeze',
  'Focal',
  'ZMF',
];

/// A searchable ListView scaffold; [builder] rebuilds rows from the query. When
/// [pinned] is set, its rows show above a divider on the empty query only.
class _SearchList extends StatefulWidget {
  const _SearchList({
    required this.title,
    required this.hint,
    required this.builder,
    this.pinned,
  });

  final String title;
  final String hint;
  final List<Widget> Function(String query) builder;
  final List<Widget> Function()? pinned;

  @override
  State<_SearchList> createState() => _SearchListState();
}

class _SearchListState extends State<_SearchList> {
  String _query = '';

  static const _maxRows = 50;

  @override
  Widget build(BuildContext context) {
    final rows = widget.builder(_query);
    final capped = rows.length > _maxRows
        ? [
            ...rows.take(_maxRows),
            ListTile(
              enabled: false,
              title: Text(
                '＋${rows.length - _maxRows} more — refine your search',
                style: TextStyle(color: Theme.of(context).disabledColor),
              ),
            ),
          ]
        : rows;
    final showPinned = _query.isEmpty && widget.pinned != null;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AriaSpace.s4),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: widget.hint,
              ),
              onChanged: (v) => setState(() => _query = v.toLowerCase()),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: transportFloatInset),
              children: [
                if (showPinned) ...[...widget.pinned!(), const Divider()],
                ...capped,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Brands: distinct sorted vendors.
class EqBrandsScreen extends ConsumerWidget {
  const EqBrandsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opra = ref.watch(opraProvider);
    final vendors = opra.whenOrNull(
      data: (products) =>
          {for (final p in products) p.vendor}.toList()..sort(),
    );
    ListTile brandTile(String v) => ListTile(
          title: Text(v),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => EqHeadphonesScreen(vendor: v),
            ),
          ),
        );
    return _SearchList(
      title: 'Choose brand',
      hint: 'Search brands…',
      pinned: vendors == null
          ? null
          : () => [
                for (final v in _pinnedBrands)
                  if (vendors.contains(v)) brandTile(v),
              ],
      builder: (query) => vendors == null
          ? [_status(opra, 'Loading the OPRA database…')]
          : [
              for (final v in vendors)
                if (v.toLowerCase().contains(query)) brandTile(v),
            ],
    );
  }
}

/// Headphones for a vendor. A single-EQ product applies immediately and skips
/// the Curves screen.
class EqHeadphonesScreen extends ConsumerWidget {
  const EqHeadphonesScreen({required this.vendor, super.key});

  final String vendor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opra = ref.watch(opraProvider);
    final products = opra.whenOrNull(
      data: (all) => [for (final p in all) if (p.vendor == vendor) p]
        ..sort((a, b) => a.product.compareTo(b.product)),
    );
    return _SearchList(
      title: vendor,
      hint: 'Search headphones…',
      builder: (query) => products == null
          ? [_status(opra, 'Loading the OPRA database…')]
          : [
              for (final p in products)
                if (p.product.toLowerCase().contains(query))
                  ListTile(
                    title: Text(p.product),
                    subtitle: Text(
                      p.eqs.length == 1
                          ? (p.eqs.single.author ?? '')
                          : '${p.eqs.length} EQs',
                    ),
                    trailing: p.eqs.length == 1
                        ? null
                        : const Icon(Icons.chevron_right),
                    onTap: () {
                      if (p.eqs.length == 1) {
                        _applyCurve(context, ref, p, p.eqs.single);
                      } else {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => EqCurvesScreen(product: p),
                          ),
                        );
                      }
                    },
                  ),
            ],
    );
  }
}

/// Curves of one product, by author. Tap applies; ★ toggles favourite.
class EqCurvesScreen extends ConsumerWidget {
  const EqCurvesScreen({required this.product, super.key});

  final OpraProduct product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favourites = ref.watch(favouriteEqProvider);
    return _SearchList(
      title: product.product,
      hint: 'Search authors…',
      builder: (query) => [
        for (final e in product.eqs)
          if ((e.author ?? 'unknown').toLowerCase().contains(query))
            Builder(
              builder: (context) {
                final name = _curveName(product, e);
                final fav = favourites.any((f) => f.name == name);
                return ListTile(
                  title: Text(e.author ?? 'unknown'),
                  subtitle: e.details == null ? null : Text(e.details!),
                  trailing: IconButton(
                    icon: Icon(fav ? Icons.star : Icons.star_border),
                    onPressed: () => ref
                        .read(favouriteEqProvider.notifier)
                        .toggle(_named(product, e)),
                  ),
                  onTap: () => _applyCurve(context, ref, product, e),
                );
              },
            ),
      ],
    );
  }
}

String _curveName(OpraProduct p, EqProfile e) =>
    '${p.vendor} ${p.product} · ${e.author ?? 'unknown'}'
    '${e.details == null ? '' : ' (${e.details})'}';

EqProfile _named(OpraProduct p, EqProfile e) => EqProfile(
  name: _curveName(p, e),
  details: e.details,
  gainDb: e.gainDb,
  bands: e.bands,
);

/// RouteSettings name of the Brands route, so leaf screens can pop the whole
/// drill-down back to the entry screen without popping past the router shell.
const _brandsRoute = 'eq-brands';

/// Push the drill-down from the entry screen. Named so [_applyCurve] can unwind
/// exactly to here.
void pushEqBrands(BuildContext context) => Navigator.push(
  context,
  MaterialPageRoute(
    settings: const RouteSettings(name: _brandsRoute),
    builder: (_) => const EqBrandsScreen(),
  ),
);

/// Set the headphone layer to [e] and pop the drill-down back to the entry.
void _applyCurve(
  BuildContext context,
  WidgetRef ref,
  OpraProduct p,
  EqProfile e,
) {
  ref.read(eqProvider.notifier).selectHeadphone(_named(p, e));
  // popUntil stops ON the predicate-matching route, so pop it too first.
  Navigator.popUntil(context, (r) => r.settings.name == _brandsRoute);
  Navigator.pop(context);
}
