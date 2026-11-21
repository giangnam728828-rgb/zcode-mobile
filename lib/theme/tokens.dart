import 'package:flutter/material.dart';

/// One source of truth for spacing, radii, motion and colour.
///
/// Before this file the app had 120 hand-written border radii (2 through 22)
/// and 65 hard-coded colours, which is why every page looked slightly
/// different. Everything below is a scale, not a suggestion: if a widget needs
/// a value that is not here, the scale is wrong, not the widget.
class AppTokens {
  const AppTokens._();

  // ── Spacing: 4pt grid ────────────────────────────────────────────────
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s8 = 32;
  static const double s10 = 40;

  /// Page gutter. Every scrollable body uses this, so text lines up across
  /// pages when you swipe between them.
  static const double gutter = 16;

  /// Minimum row height for anything tappable. 48 > 44 because Android
  /// thumbs are less precise than the platform guidance assumes.
  static const double tapTarget = 48;

  // ── Radii: six steps, no more ────────────────────────────────────────
  static const double rXs = 8;
  static const double rSm = 12;
  static const double rMd = 16;
  static const double rLg = 20;
  static const double rXl = 26;

  static BorderRadius get brXs => BorderRadius.circular(rXs);
  static BorderRadius get brSm => BorderRadius.circular(rSm);
  static BorderRadius get brMd => BorderRadius.circular(rMd);
  static BorderRadius get brLg => BorderRadius.circular(rLg);
  static BorderRadius get brXl => BorderRadius.circular(rXl);
  static BorderRadius get brPill => BorderRadius.circular(999);

  // ── Motion ───────────────────────────────────────────────────────────
  static const Duration instant = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration base = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 380);

  /// Enter/leave. Decelerating, no overshoot: content should arrive, not bounce.
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve decelerate = Cubic(0.05, 0.7, 0.1, 1.0);

  /// Only for things that physically spring back: press release, dock pill.
  static const Curve spring = Cubic(0.16, 1.0, 0.3, 1.0);

  /// Press-in is fast and flat; the release carries the character.
  static const Curve press = Cubic(0.4, 0.0, 0.6, 1.0);

  /// Scale applied while a control is held. The spec asks for 1.02–1.06
  /// ("press to grow"); 1.03 is the value that reads as intentional rather
  /// than as a layout glitch on a 390dp-wide phone.
  static const double pressScale = 1.03;
}

/// Semantic colours, resolved per brightness.
///
/// Deliberately neutral: the background is a near-flat slate, not a purple
/// gradient. Glass needs something calm behind it; a saturated wallpaper plus
/// tinted glass is what makes an app look machine-generated.
@immutable
class AppPalette {
  const AppPalette({
    required this.brightness,
    required this.bg,
    required this.bgElevated,
    required this.surface,
    required this.surfaceRaised,
    required this.line,
    required this.lineStrong,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.glassTint,
    required this.glassStroke,
    required this.glassHighlight,
    required this.accentWash,
  });

  final Brightness brightness;

  /// Behind everything.
  final Color bg;
  final Color bgElevated;

  /// Solid content surfaces: message bubbles, list rows, sheets.
  final Color surface;
  final Color surfaceRaised;

  final Color line;
  final Color lineStrong;

  final Color text;
  final Color textSecondary;
  final Color textTertiary;

  /// Fill painted inside a glass layer, on top of the refracted backdrop.
  /// Fully opaque: the alpha is supplied per surface, so a pane can be 6% white
  /// in dark mode and 55% in light without two separate tokens.
  final Color glassTint;

  /// 1px inner hairline that gives the glass an edge.
  final Color glassStroke;

  /// Specular sheen across the top third.
  final Color glassHighlight;

  /// Very low-alpha accent used for selection and focus rings.
  final Color accentWash;

  bool get isDark => brightness == Brightness.dark;

  /// Exposed as plain constants too: `AppPalette.dark.bg` is a field read, not
  /// a constant expression, so it cannot be used to initialise `const` fields.
  static const Color lightBg = Color(0xFFE9ECF1);

  /// Dark backdrop sits one step above pure black on purpose: on OLED a
  /// #0A0C10 field reads as a hole, and the light pools behind the glass have
  /// nothing to tint. At #101419 the layers above it can step in ~4% increments
  /// and still show a visible edge, which is what the hairline borders need.
  static const Color darkBg = Color(0xFF101419);

  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    bg: darkBg,
    bgElevated: Color(0xFF141920),
    surface: Color(0xFF1A2028),
    surfaceRaised: Color(0xFF212832),
    line: Color(0xFF2C333D),
    lineStrong: Color(0xFF39414D),
    text: Color(0xFFE9ECF0),
    textSecondary: Color(0xFFA9B0BB),
    textTertiary: Color(0xFF737B87),
    glassTint: Color(0xFFFFFFFF),
    glassStroke: Color(0x2AFFFFFF),
    glassHighlight: Color(0x17FFFFFF),
    accentWash: Color(0x1F7AA2FF),
  );

  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    bg: lightBg,
    bgElevated: Color(0xFFF3F5F8),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFBFCFD),
    line: Color(0xFFE2E5EA),
    lineStrong: Color(0xFFCED3DB),
    text: Color(0xFF14171C),
    textSecondary: Color(0xFF5A626D),
    textTertiary: Color(0xFF8A939F),
    glassTint: Color(0xFFFFFFFF),
    glassStroke: Color(0x8CFFFFFF),
    glassHighlight: Color(0xCCFFFFFF),
    accentWash: Color(0x147AA2FF),
  );

  static AppPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// How much of the expensive path to take.
///
/// `soft` is the default: one blur pass on a handful of fixed surfaces. `full`
/// adds the magnification pass that makes glass read as a lens rather than as
/// frosted plastic — it costs an extra offscreen pass, so it is opt-in. `flat`
/// drops the backdrop filter entirely for devices that cannot hold 60fps.
enum GlassQuality {
  /// No backdrop filter. Translucent fill + hairline. Cheapest.
  flat,

  /// Blur + desaturate-correct. What most screens will use.
  soft,

  /// Blur + magnification + colour lift. Fixed surfaces only.
  full;

  static GlassQuality parse(String? id) {
    switch (id) {
      case 'flat':
        return GlassQuality.flat;
      case 'full':
        return GlassQuality.full;
      default:
        return GlassQuality.soft;
    }
  }

  String get id => name;

  String get label {
    switch (this) {
      case GlassQuality.flat:
        return '关闭';
      case GlassQuality.soft:
        return '标准';
      case GlassQuality.full:
        return '强折射';
    }
  }
}
