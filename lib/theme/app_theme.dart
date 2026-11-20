import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_config.dart';

/// Builds both themes from one accent seed. Material 3 with a restrained
/// surface palette: near-black in dark mode, warm grey in light mode.
class AppTheme {
  static const Color _lightBg = Color(0xFFF5F6F8);
  static const Color _darkBg = Color(0xFF0C0E12);

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
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: Color(seed),
      brightness: brightness,
    ).copyWith(
      background: dark ? _darkBg : _lightBg,
      surface: dark ? const Color(0xFF12151A) : Colors.white,
    );

    final ThemeData base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: dark ? _darkBg : _lightBg,
      canvasColor: dark ? _darkBg : _lightBg,
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
        color: dark ? const Color(0xFF1E232B) : const Color(0xFFE9ECF1),
      ),
      cardTheme: CardTheme(
        elevation: 0,
        color: scheme.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: dark ? const Color(0xFF1E232B) : const Color(0xFFE9ECF1),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF161A20) : Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: dark ? const Color(0xFF242A33) : const Color(0xFFE1E5EC),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: dark ? const Color(0xFF242A33) : const Color(0xFFE1E5EC),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        hintStyle: TextStyle(color: scheme.onSurface.withOpacity(0.42)),
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
        backgroundColor: dark ? const Color(0xFF12151A) : Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: dark ? const Color(0xFF14181E) : Colors.white,
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
