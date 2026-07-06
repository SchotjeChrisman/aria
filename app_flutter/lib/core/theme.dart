import 'package:flutter/material.dart';

/// Aria dark theme, ported from the legacy visual language (app/ui/style.css):
/// same purple accent, 4px spacing base, 6/10/16/pill radii, quiet dim text,
/// tabular numerals for times — hues shifted onto a dark surface stack.
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

  /// Legacy pairs: lossless shares the accent purple, lossy is green
  /// (used by the signal path to flag a lossy source).
  final Color lossless;
  final Color lossy;

  static const dark = AriaColors(
    bg: Color(0xFF141318),
    bgRaised: Color(0xFF1C1A22),
    bgHover: Color(0xFF2A2733),
    line: Color(0xFF2E2B38),
    lineStrong: Color(0xFF565060),
    fg: Color(0xFFE9E7EF),
    fgDim: Color(0xFFA19DAD),
    // legacy accent #6d3fd2, lifted for contrast on dark surfaces
    accent: Color(0xFF9A7BFF),
    lossless: Color(0xFF9A7BFF),
    lossy: Color(0xFF4ADE80),
  );

  /// Theme lookup with a safe fallback so pure widgets render (and test)
  /// without a fully configured MaterialApp.
  static AriaColors of(BuildContext context) =>
      Theme.of(context).extension<AriaColors>() ?? dark;

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
  static ThemeData dark() {
    const c = AriaColors.dark;
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.dark(
        primary: c.accent,
        onPrimary: Colors.white,
        secondary: c.accent,
        surface: c.bg,
        onSurface: c.fg,
        surfaceContainerHighest: c.bgHover,
        surfaceContainer: c.bgRaised,
        outline: c.lineStrong,
        outlineVariant: c.line,
        error: const Color(0xFFF87171),
      ),
      scaffoldBackgroundColor: c.bg,
      splashFactory: InkSparkle.splashFactory,
    );

    // Legacy type feel: 14px body, quiet weights, 26px/600 tight-tracked h1.
    final text = base.textTheme.copyWith(
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: c.fg),
      bodySmall: TextStyle(fontSize: 12.5, height: 1.45, color: c.fgDim),
      titleLarge: const TextStyle(
        fontSize: 26,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.4,
      ),
      titleMedium: const TextStyle(
        fontSize: 15,
        height: 1.4,
        fontWeight: FontWeight.w600,
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
        // legacy .play-all: accent pill, 600 weight
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
        indicatorColor: c.bgHover,
        selectedIconTheme: IconThemeData(color: c.fg),
        unselectedIconTheme: IconThemeData(color: c.fgDim),
        selectedLabelTextStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: c.fg,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: c.fgDim,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.bgRaised,
        indicatorColor: c.bgHover,
        height: 64,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.fgDim),
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
