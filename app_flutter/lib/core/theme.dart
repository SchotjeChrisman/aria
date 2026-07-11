import 'package:flutter/material.dart';

/// Aria light theme, ported from the legacy visual language (app/ui/style.css):
/// pinkish-red state accent, neutral greyscale surfaces, 4px spacing base,
/// 6/10/16/pill radii, quiet dim text, tabular numerals for times.
class AriaColors extends ThemeExtension<AriaColors> {
  const AriaColors({
    required this.bg,
    required this.bgRaised,
    required this.bgHover,
    required this.line,
    required this.lineStrong,
    required this.fg,
    required this.fgDim,
    required this.accent,
    required this.lossless,
    required this.lossy,
  });

  final Color bg;
  final Color bgRaised;
  final Color bgHover;
  final Color line;
  final Color lineStrong;
  final Color fg;
  final Color fgDim;
  final Color accent;

  /// Lossless renders in full-strength greyscale (it's the norm); lossy is
  /// green (used by the signal path to flag a lossy source).
  final Color lossless;
  final Color lossy;

  static const light = AriaColors(
    bg: Color(0xFFFAFAFB),
    bgRaised: Color(0xFFFFFFFF),
    bgHover: Color(0xFFECECEE),
    line: Color(0xFFE5E5E8),
    // 3.3:1 against white — WCAG UI-component minimum for input borders
    lineStrong: Color(0xFF8D8D96),
    fg: Color(0xFF1B1B1E),
    fgDim: Color(0xFF6A6A72),
    // Pinkish red, deepened to 4.7:1 on white so state text stays readable.
    // Accent marks STATES only (current/selected/active/focus/live);
    // everything else is greyscale.
    accent: Color(0xFFD13B58),
    // greyscale: lossless is the norm, only lossy gets flagged (green)
    lossless: Color(0xFF1B1B1E),
    lossy: Color(0xFF15803D),
  );

  /// Theme lookup with a safe fallback so pure widgets render (and test)
  /// without a fully configured MaterialApp.
  static AriaColors of(BuildContext context) =>
      Theme.of(context).extension<AriaColors>() ?? light;

  @override
  AriaColors copyWith() => this;

  @override
  AriaColors lerp(ThemeExtension<AriaColors>? other, double t) {
    if (other is! AriaColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AriaColors(
      bg: l(bg, other.bg),
      bgRaised: l(bgRaised, other.bgRaised),
      bgHover: l(bgHover, other.bgHover),
      line: l(line, other.line),
      lineStrong: l(lineStrong, other.lineStrong),
      fg: l(fg, other.fg),
      fgDim: l(fgDim, other.fgDim),
      accent: l(accent, other.accent),
      lossless: l(lossless, other.lossless),
      lossy: l(lossy, other.lossy),
    );
  }
}

/// Window size bands (Material 3 canonical cuts). Layouts morph only at
/// band switches and scale proportionally within a band — every width
/// check in the app routes through this so phones of different sizes get
/// the same layout structure.
enum AriaBreakpoint {
  mobile,
  tablet,
  desktop;

  static AriaBreakpoint of(BuildContext context) =>
      fromWidth(MediaQuery.sizeOf(context).width);

  static AriaBreakpoint fromWidth(double width) => width < 600
      ? mobile
      : width < 1240
          ? tablet
          : desktop;

  /// Grid columns for card grids (albums, artists, genres…). Fixed per band
  /// so a 360px and a 428px phone render the identical layout, tiles just
  /// scale.
  int get gridColumns => switch (this) {
        mobile => 2,
        tablet => 4,
        desktop => 6,
      };

  /// Max width the page content is centered within on wide layouts, so rows
  /// don't stretch edge-to-edge and read like a blown-up phone. Below this
  /// width the content just fills the window.
  static const double maxContentWidth = 1200;
}

/// Horizontal inset that centers page content within
/// [AriaBreakpoint.maxContentWidth]. The shell knows the content-area width and
/// provides it here; each scroll view folds it into its own horizontal padding.
/// That keeps the scrollable full-width (the mouse wheel works over the
/// margins) while the visible content stays centered and capped — the cap lives
/// inside the scroll, not around it.
class ContentInset extends InheritedWidget {
  const ContentInset({super.key, required this.inset, required super.child});

  final double inset;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ContentInset>()?.inset ?? 0;

  @override
  bool updateShouldNotify(ContentInset old) => old.inset != inset;
}

/// Page padding that also centers content within [AriaBreakpoint.maxContentWidth].
/// Drop-in for the scroll-root paddings: [EdgeInsets.all(s6)] becomes
/// `ariaPagePadding(context)`; `fromLTRB(s6, 0, s6, s6)` becomes
/// `ariaPagePadding(context, top: 0)`.
EdgeInsets ariaPagePadding(
  BuildContext context, {
  double horizontal = AriaSpace.s6,
  double top = AriaSpace.s6,
  double bottom = AriaSpace.s6,
}) {
  final h = horizontal + ContentInset.of(context);
  return EdgeInsets.only(left: h, right: h, top: top, bottom: bottom);
}

/// Spacing scale — 4px base, same steps as the legacy --sp-* vars.
abstract final class AriaSpace {
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s8 = 32;
  static const double s10 = 40;
  static const double s12 = 48;
}

/// Radii — legacy --r-sm / --r-md / --r-lg / --r-pill.
abstract final class AriaRadius {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 16;
  static const double pill = 999;
}

abstract final class AriaTheme {
  static ThemeData light() {
    const c = AriaColors.light;
    final base = ThemeData(
      brightness: Brightness.light,
      useMaterial3: true,
      colorScheme: ColorScheme.light(
        primary: c.accent,
        onPrimary: Colors.white,
        secondary: c.accent,
        surface: c.bg,
        onSurface: c.fg,
        surfaceContainerHighest: c.bgHover,
        surfaceContainer: c.bgRaised,
        outline: c.lineStrong,
        outlineVariant: c.line,
        error: const Color(0xFFDC2626),
      ),
      scaffoldBackgroundColor: c.bg,
      splashFactory: InkSparkle.splashFactory,
    );

    // Legacy type feel: 14px body, quiet weights, 26px/600 tight-tracked h1.
    final text = base.textTheme.copyWith(
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: c.fg),
      bodySmall: TextStyle(fontSize: 12.5, height: 1.45, color: c.fgDim),
      // Explicit colors required: M3 geometry styles are inherit:false, so a
      // color-less replacement paints in the engine default (white).
      titleLarge: TextStyle(
        fontSize: 26,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
        color: c.fg,
      ),
      titleMedium: TextStyle(
        fontSize: 15,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: c.fg,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: c.fgDim,
      ),
    );

    return base.copyWith(
      textTheme: text,
      extensions: const [c],
      dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
      cardTheme: CardThemeData(
        color: c.bgRaised,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AriaRadius.md),
          side: BorderSide(color: c.line),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.bgRaised,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AriaRadius.md),
          side: BorderSide(color: c.line),
        ),
        textStyle: text.bodyMedium,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.bgRaised,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AriaRadius.sm),
          borderSide: BorderSide(color: c.lineStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AriaRadius.sm),
          borderSide: BorderSide(color: c.lineStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AriaRadius.sm),
          borderSide: BorderSide(color: c.accent, width: 2),
        ),
        hintStyle: TextStyle(color: c.fgDim),
      ),
      filledButtonTheme: FilledButtonThemeData(
        // legacy .play-all pill, 600 weight — primary actions carry the accent
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          shape: const StadiumBorder(),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: c.bgRaised,
        // selected = state → accent-tinted pill, accent icon/label
        indicatorColor: c.accent.withValues(alpha: 0.12),
        selectedIconTheme: IconThemeData(color: c.accent),
        unselectedIconTheme: IconThemeData(color: c.fgDim),
        selectedLabelTextStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: c.accent,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: c.fgDim,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.bgRaised,
        indicatorColor: c.accent.withValues(alpha: 0.12),
        height: 64,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? c.accent : c.fgDim,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: states.contains(WidgetState.selected) ? c.accent : c.fgDim,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.bgHover,
        contentTextStyle: text.bodyMedium,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AriaRadius.md),
        ),
      ),
    );
  }
}
