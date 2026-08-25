import 'dart:math' as math;

import 'package:aria/core/phosphor_icons.dart';
import 'package:aria/core/theme.dart';
import 'package:flutter/material.dart';

import 'catalogue.dart';

/// The token layer of lib/core/theme.dart, rendered.
///
/// Nothing here restates a value: every swatch, step and radius reads the same
/// constant the app reads, so a token edit shows up in the catalogue on hot
/// reload and a stale page is impossible.

// --------------------------------------------------------------- scaffolding

/// Vertically stacked sections on the app canvas, scrollable and padded.
class StoryPage extends StatelessWidget {
  const StoryPage({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    // Material rather than ColoredBox: several catalogued components are
    // ListTiles, and a ColoredBox between one and its nearest Material
    // ancestor hides its ink and asserts. The paint is identical.
    return Material(
      color: c.bg,
      child: ListView(
        padding: const EdgeInsets.all(AriaSpace.s6),
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0) const SizedBox(height: AriaSpace.s8),
            child,
          ],
        ],
      ),
    );
  }
}

class Section extends StatelessWidget {
  const Section({super.key, required this.title, this.note, required this.child});

  final String title;

  /// The rule the section documents — why the token exists, not what it is.
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: t.titleLarge),
        if (note != null) ...[
          const SizedBox(height: AriaSpace.s2),
          Text(note!, style: t.bodySmall),
        ],
        const SizedBox(height: AriaSpace.s5),
        child,
      ],
    );
  }
}

// ------------------------------------------------------------------- colours

/// WCAG 2.x relative luminance.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// Contrast ratio between two opaque colours, 1.0–21.0.
double contrastRatio(Color a, Color b) {
  final (la, lb) = (_luminance(a), _luminance(b));
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

String _hex(Color c) {
  String channel(double v) =>
      (v * 255).round().toRadixString(16).toUpperCase().padLeft(2, '0');
  return '#${channel(c.r)}${channel(c.g)}${channel(c.b)}';
}

/// One token: chip, name, hex, and its measured contrast on the canvas.
///
/// The ratio is computed, not transcribed — theme.dart's comments claim 3.3:1
/// for lineStrong and 4.7:1 for accent, and a swatch that recomputes them is
/// the only version that stays honest when a colour is nudged.
class Swatch extends StatelessWidget {
  const Swatch({
    super.key,
    required this.name,
    required this.color,
    required this.note,
    this.against,
  });

  final String name;
  final Color color;
  final String note;

  /// Background to measure against; defaults to the canvas.
  final Color? against;

  @override
  Widget build(BuildContext context) {
    final c = AriaColors.of(context);
    final bg = against ?? c.bg;
    final ratio = contrastRatio(color, bg);
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AriaSpace.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(AriaRadius.sm),
              border: Border.all(color: c.line),
            ),
          ),
          const SizedBox(width: AriaSpace.s4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(name, style: t.titleMedium),
                    const SizedBox(width: AriaSpace.s2),
                    Text(
                      _hex(color),
                      style: t.bodySmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: AriaSpace.s2),
                    Text(
                      '${ratio.toStringAsFixed(1)}:1',
                      style: t.bodySmall?.copyWith(
                        // Below 3:1 nothing in this palette is legal as a
                        // UI edge, let alone as text — flag it in accent.
                        color: ratio >= 3 ? c.fgDim : c.accent,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                Text(note, style: t.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget colourStory(BuildContext context) {
  final c = AriaColors.of(context);
  return StoryPage(
    children: [
      Section(
        title: 'Colour',
        note: 'Accent marks STATES only — current, selected, active, focus, '
            'live. Everything else is greyscale. Ratios are measured against '
            'the canvas at build time.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Swatch(
              name: 'bg',
              color: c.bg,
              note: 'Pure-white canvas. Surfaces separate by border + shadow, '
                  'never by a fill delta.',
            ),
            Swatch(
              name: 'bgRaised',
              color: c.bgRaised,
              note: 'Inline surfaces — cards, chrome bars. White on white '
                  'under this theme; ariaSurface() carries the separation.',
            ),
            Swatch(
              name: 'bgFloat',
              color: c.bgFloat,
              note: 'Menus, dialogs, sheets. Split from bgRaised so floats can '
                  'diverge later without touching every call site.',
            ),
            Swatch(
              name: 'bgHover',
              color: c.bgHover,
              note: 'Hover and pressed fill.',
            ),
            Swatch(
              name: 'line',
              color: c.line,
              note: 'Quiet hairline. Paired with surfaceShadow on cards, where '
                  'the shadow does the separating.',
            ),
            Swatch(
              name: 'lineStrong',
              color: c.lineStrong,
              note: 'The load-bearing separator: input borders, rail edges, '
                  'chrome tops — anywhere a divider is the SOLE separator.',
            ),
            Swatch(name: 'fg', color: c.fg, note: 'Body text.'),
            Swatch(
              name: 'fgDim',
              color: c.fgDim,
              note: 'Secondary text, inactive icons, metadata.',
            ),
            Swatch(
              name: 'accent',
              color: c.accent,
              note: 'State only. Deepened until state text stays readable on '
                  'white.',
            ),
            Swatch(
              name: 'lossless',
              color: c.lossless,
              note: 'Lossless is the norm, so it renders in plain greyscale.',
            ),
            Swatch(
              name: 'lossy',
              color: c.lossy,
              note: 'The exception that gets flagged — signal path, format '
                  'badge.',
            ),
          ],
        ),
      ),
      Section(
        title: 'Accent as state',
        note: 'The same component, unstated and stated. If accent appears on '
            'anything that is not a state, it is a bug.',
        child: Wrap(
          spacing: AriaSpace.s3,
          runSpacing: AriaSpace.s3,
          children: [
            for (final selected in [false, true])
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? c.accent.withValues(alpha: 0.10)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AriaRadius.pill),
                  border: Border.all(
                    color: selected ? c.accent : c.lineStrong,
                  ),
                ),
                child: Text(
                  selected ? 'selected' : 'default',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: selected ? c.accent : c.fgDim,
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

// ------------------------------------------------------------------- spacing

const _spaceSteps = <(String, double)>[
  ('s1', AriaSpace.s1),
  ('s2', AriaSpace.s2),
  ('s3', AriaSpace.s3),
  ('s4', AriaSpace.s4),
  ('s5', AriaSpace.s5),
  ('s6', AriaSpace.s6),
  ('s8', AriaSpace.s8),
  ('s10', AriaSpace.s10),
  ('s12', AriaSpace.s12),
];

Widget spacingStory(BuildContext context) {
  final c = AriaColors.of(context);
  final t = Theme.of(context).textTheme;
  return StoryPage(
    children: [
      Section(
        title: 'Spacing',
        note: '4px base. The step names are the legacy --sp-* vars; the gaps '
            'in the sequence (no s7, s9, s11) are deliberate.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (name, value) in _spaceSteps)
              Padding(
                padding: const EdgeInsets.only(bottom: AriaSpace.s2),
                child: Row(
                  children: [
                    SizedBox(width: 40, child: Text(name, style: t.titleMedium)),
                    SizedBox(
                      width: 48,
                      child: Text(
                        '${value.toInt()}',
                        style: t.bodySmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Container(width: value, height: 20, color: c.accent),
                  ],
                ),
              ),
          ],
        ),
      ),
      Section(
        title: 'Radius',
        note: 'sm on inputs and small chips, md on cards and menus, lg on '
            'large surfaces, pill on anything stadium-shaped.',
        child: Wrap(
          spacing: AriaSpace.s4,
          runSpacing: AriaSpace.s4,
          children: [
            for (final (name, r) in const <(String, double)>[
              ('sm', AriaRadius.sm),
              ('md', AriaRadius.md),
              ('lg', AriaRadius.lg),
              ('pill', AriaRadius.pill),
            ])
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 96,
                    height: 64,
                    decoration: BoxDecoration(
                      color: c.bgHover,
                      borderRadius: BorderRadius.circular(r),
                      border: Border.all(color: c.lineStrong),
                    ),
                  ),
                  const SizedBox(height: AriaSpace.s2),
                  Text('$name · ${r.toInt()}', style: t.bodySmall),
                ],
              ),
          ],
        ),
      ),
    ],
  );
}

// ------------------------------------------------------------------ surfaces

Widget surfaceStory(BuildContext context) {
  final c = AriaColors.of(context);
  final t = Theme.of(context).textTheme;

  Widget demo(String label, String note, BoxDecoration decoration) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 88,
            decoration: decoration,
            alignment: Alignment.center,
            child: Text(label, style: t.titleMedium),
          ),
          const SizedBox(height: AriaSpace.s2),
          Text(note, style: t.bodySmall),
          const SizedBox(height: AriaSpace.s5),
        ],
      );

  return StoryPage(
    children: [
      Section(
        title: 'Surfaces',
        note: 'On a white canvas a surface cannot separate itself by fill. '
            'ariaSurface() spends a quiet hairline plus one soft shadow; '
            'lineStrong is reserved for separators that have no shadow to '
            'help them.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            demo(
              'ariaSurface()',
              'The standard inline surface — cards, chrome. Shadow carries the '
                  'separation, so the border stays quiet.',
              ariaSurface(c),
            ),
            demo(
              'ariaSurface(border: accent)',
              'Same surface in a state — the current album, a live item.',
              ariaSurface(c, border: c.accent),
            ),
            demo(
              'lineStrong, no shadow',
              'A sole separator: rail edge, chrome top, input border. Heavy '
                  'enough to work alone, too heavy for every card.',
              BoxDecoration(
                color: c.bgRaised,
                borderRadius: BorderRadius.circular(AriaRadius.md),
                border: Border.all(color: c.lineStrong),
              ),
            ),
            demo(
              'art tile — hairline only',
              'Dense grids skip the shadow so a wall of covers does not read '
                  'as noise.',
              BoxDecoration(
                color: c.bgRaised,
                borderRadius: BorderRadius.circular(AriaRadius.md),
                border: Border.all(color: c.line),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- typography

Widget typeStory(BuildContext context) {
  final t = Theme.of(context).textTheme;
  final c = AriaColors.of(context);

  Widget row(String name, String spec, TextStyle? style) => Padding(
        padding: const EdgeInsets.only(bottom: AriaSpace.s5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(name, style: t.labelMedium),
                const SizedBox(width: AriaSpace.s2),
                Text(spec, style: t.labelMedium?.copyWith(color: c.fgDim)),
              ],
            ),
            const SizedBox(height: AriaSpace.s1),
            Text('Sunday at the Village Vanguard', style: style),
          ],
        ),
      );

  return StoryPage(
    children: [
      Section(
        title: 'Type',
        note: 'Nunito variable font — Flutter drives the wght axis from '
            'fontWeight, so one file covers 400/500/600. Digits are tabular '
            'by default, which is why durations and track numbers line up.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row('titleLarge', '26 / 600 / -0.4', t.titleLarge),
            row('titleMedium', '15 / 600', t.titleMedium),
            row('bodyMedium', '14 / 400 / 1.5', t.bodyMedium),
            row('bodySmall', '12.5 / 400 / dim', t.bodySmall),
            row('labelMedium', '12 / 500 / dim', t.labelMedium),
          ],
        ),
      ),
      Section(
        title: 'Tabular figures',
        note: 'Every duration, track number and byte count sets '
            'FontFeature.tabularFigures() so columns do not shimmer as values '
            'change.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final s in ['9:05', '11:11', '4:38', '1:02:44'])
              Text(
                s,
                style: t.bodyMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

// --------------------------------------------------------------- breakpoints

Widget breakpointStory(BuildContext context) {
  final band = AriaBreakpoint.of(context);
  final width = MediaQuery.sizeOf(context).width;
  final c = AriaColors.of(context);
  final t = Theme.of(context).textTheme;

  return StoryPage(
    children: [
      Section(
        title: 'Breakpoints',
        note: 'Layouts morph only at band switches and scale proportionally '
            'within a band, so a 360px and a 428px phone render the identical '
            'structure. Resize the viewport addon to watch the band flip.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(AriaSpace.s4),
              decoration: ariaSurface(c, border: c.accent),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('current: ${band.name}', style: t.titleMedium),
                  Text(
                    '${width.round()}px wide · ${band.gridColumns} grid '
                    'columns · content capped at '
                    '${AriaBreakpoint.maxContentWidth.toInt()}px',
                    style: t.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AriaSpace.s5),
            for (final b in AriaBreakpoint.values)
              Padding(
                padding: const EdgeInsets.only(bottom: AriaSpace.s2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 80,
                      child: Text(
                        b.name,
                        style: b == band
                            ? t.titleMedium?.copyWith(color: c.accent)
                            : t.bodyMedium,
                      ),
                    ),
                    Text(
                      switch (b) {
                        AriaBreakpoint.mobile => '< 600px',
                        AriaBreakpoint.tablet => '600 – 1239px',
                        AriaBreakpoint.desktop => '>= 1240px',
                      },
                      style: t.bodySmall,
                    ),
                    const Spacer(),
                    Text('${b.gridColumns} cols', style: t.bodySmall),
                  ],
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

// --------------------------------------------------------------------- icons

/// The Phosphor set is bundled as three plain font families with an IconData
/// shim, because phosphor_flutter subclasses IconData — which is final as of
/// Flutter 3.44. Thin is the unselected navigation weight, Fill the selected
/// one, Regular everything else.
Widget iconStory(BuildContext context) {
  final c = AriaColors.of(context);
  final t = Theme.of(context).textTheme;

  const sample = <(String, IconData, IconData, IconData)>[
    ('play', PhosphorIconsThin.play, PhosphorIconsRegular.play,
        PhosphorIconsFill.play),
    ('heart', PhosphorIconsThin.heart, PhosphorIconsRegular.heart,
        PhosphorIconsFill.heart),
    ('vinylRecord', PhosphorIconsThin.vinylRecord,
        PhosphorIconsRegular.vinylRecord, PhosphorIconsFill.vinylRecord),
    ('chartBar', PhosphorIconsThin.chartBar, PhosphorIconsRegular.chartBar,
        PhosphorIconsFill.chartBar),
    ('magnifyingGlass', PhosphorIconsThin.magnifyingGlass,
        PhosphorIconsRegular.magnifyingGlass,
        PhosphorIconsFill.magnifyingGlass),
  ];

  return StoryPage(
    children: [
      Section(
        title: 'Icons',
        note: 'Phosphor, bundled as three font families. Navigation uses Thin '
            'unselected and Fill selected; everything else is Regular.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(width: 160),
                for (final w in ['Thin', 'Regular', 'Fill'])
                  SizedBox(width: 72, child: Text(w, style: t.labelMedium)),
              ],
            ),
            const SizedBox(height: AriaSpace.s3),
            for (final (name, thin, regular, fill) in sample)
              Padding(
                padding: const EdgeInsets.only(bottom: AriaSpace.s3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 160,
                      child: Text(name, style: t.bodyMedium),
                    ),
                    for (final icon in [thin, regular, fill])
                      SizedBox(
                        width: 72,
                        child: Icon(icon, size: 24, color: c.fg),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

// ---------------------------------------------------------------- catalogue

final foundationEntries = <Entry>[
  Entry(
    component: 'Colour',
    useCase: 'Tokens',
    key: 'foundations-colour',
    builder: colourStory,
  ),
  Entry(
    component: 'Spacing & radius',
    useCase: 'Scale',
    key: 'foundations-spacing',
    builder: spacingStory,
  ),
  Entry(
    component: 'Surfaces',
    useCase: 'ariaSurface',
    key: 'foundations-surfaces',
    builder: surfaceStory,
  ),
  Entry(
    component: 'Type',
    useCase: 'Ramp',
    key: 'foundations-type',
    builder: typeStory,
  ),
  Entry(
    component: 'Breakpoints',
    useCase: 'Bands',
    key: 'foundations-breakpoints',
    builder: breakpointStory,
  ),
  Entry(
    component: 'Icons',
    useCase: 'Phosphor weights',
    key: 'foundations-icons',
    builder: iconStory,
  ),
];
