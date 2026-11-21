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
      // Material 3 generates five surface-container steps from the seed, and
      // every un-migrated screen still asks for them. Left alone they carry a
      // hint of the accent and drift purple next to our neutral cards. Point
      // the whole ramp at the token values so old code lands on the same
      // palette instead of being repainted page by page.
      surfaceContainerLowest: p.bg,
      surfaceContainerLow: p.bgElevated,
      surfaceContainer: p.bgElevated,
      surfaceContainerHigh: p.surface,
      surfaceContainerHighest: p.surfaceRaised,
      outline: p.line,
      outlineVariant: p.line,
      // No tint-on-elevation: our layers already differ by value.
      surfaceTint: Colors.transparent,
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
        surfaceTintColor: Colors.transparent,
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
        backgroundColor: p.surfaceRaised,
        contentTextStyle: TextStyle(color: p.text, fontSize: 14),
        actionTextColor: scheme.primary,
        shape:
            RoundedRectangleBorder(borderRadius: AppTokens.brSm),
      ),
      // The second-tier screens (automation, modules, plugins) have not been
      // rebuilt yet. These defaults let them inherit the token look instead of
      // each carrying its own M3 leftovers.
      chipTheme: ChipThemeData(
        backgroundColor: p.surfaceRaised,
        selectedColor: scheme.primary.withValues(alpha: 0.16),
        side: BorderSide(color: p.line, width: 0.8),
        labelStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          color: p.textSecondary,
        ),
        secondaryLabelStyle: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
        shape: RoundedRectangleBorder(borderRadius: AppTokens.brPill),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        showCheckmark: false,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: p.text,
        unselectedLabelColor: p.textTertiary,
        indicatorColor: scheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: p.line,
        labelStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
        unselectedLabelStyle:
            const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> s) => s.contains(WidgetState.selected)
              ? scheme.onPrimary
              : p.textTertiary,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> s) => s.contains(WidgetState.selected)
              ? scheme.primary
              : p.lineStrong,
        ),
        trackOutlineColor: WidgetStateProperty.all<Color>(Colors.transparent),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(borderRadius: AppTokens.brMd),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: p.line,
        circularTrackColor: p.line,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        shape:
            RoundedRectangleBorder(borderRadius: AppTokens.brLg),
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
