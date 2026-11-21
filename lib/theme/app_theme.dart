import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_config.dart';
import 'tokens.dart';

/// Builds both themes from one accent seed. Material 3 with a restrained
/// surface palette: near-black in dark mode, warm grey in light mode.
class AppTheme {
  static const Color _lightBg = AppPalette.lightBg;
  static const Color _darkBg = AppPalette.darkBg;

  /// Keeps the Android status/navigation bars flush with the app background
  /// instead of letting the platform paint a mismatched band above the UI.
  static SystemUiOverlayStyle systemUi(bool dark) {
    final Color bar = dark ? _darkBg : _lightBg;
    return SystemUiOverlayStyle(
      statusBarColor: bar,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: bar,
      systemNavigationBarIconBrightness:
          dark ? Brightness.light : Brightness.dark,
      systemNavigationBarDividerColor: bar,
    );
  }

  static ThemeData build(int seed, Brightness brightness, double fontScale) {
    final bool dark = brightness == Brightness.dark;
    final AppPalette p = dark ? AppPalette.dark : AppPalette.light;
    // One seed, everything else neutral. Tinting the whole surface scale would
    // put colour under the glass, which is exactly the look we are avoiding.
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: Color(seed),
      brightness: brightness,
    ).copyWith(
      background: p.bg,
      surface: p.surface,
      onSurface: p.text,
    );

    final ThemeData base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.standard,
    );

    TextStyle? scaled(TextStyle? s) {
      if (s == null) return null;
      final double size = s.fontSize ?? 14;
      return s.copyWith(fontSize: size * fontScale, height: (s.height ?? 1.35));
    }

    final TextTheme text = base.textTheme.copyWith(
      titleLarge: scaled(base.textTheme.titleLarge)?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      titleMedium: scaled(base.textTheme.titleMedium)?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: scaled(base.textTheme.bodyLarge),
      bodyMedium: scaled(base.textTheme.bodyMedium),
      bodySmall: scaled(base.textTheme.bodySmall),
      labelLarge: scaled(base.textTheme.labelLarge),
    );

    return base.copyWith(
      textTheme: text,
      primaryTextTheme: text,
      appBarTheme: AppBarTheme(
        elevation: 0,
        systemOverlayStyle: systemUi(dark),
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        titleTextStyle: text.titleMedium?.copyWith(
          fontSize: 17 * fontScale,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      dividerTheme: DividerThemeData(
        space: 1,
        thickness: 1,
        color: p.line,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.rLg),
          side: BorderSide(color: p.line, width: 0.8),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surfaceRaised,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.rSm),
          borderSide: BorderSide(color: p.line, width: 0.8),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.rSm),
          borderSide: BorderSide(color: p.line, width: 0.8),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTokens.rSm),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        hintStyle: TextStyle(color: scheme.onSurface.withValues(alpha: 0.42)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor:
            dark ? const Color(0xFF232A33) : const Color(0xFF23272E),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }

  static ThemeMode modeOf(String id) {
    switch (id) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static Accent accentOf(AppConfig? c) => Accent.byId(c?.accentId);
}
