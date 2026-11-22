import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'models/app_config.dart';
import 'pages/home_shell.dart';
import 'pages/login_page.dart';
import 'pages/splash_page.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

void main() {
  runApp(const ZCodeApp());
}

class ZCodeApp extends StatelessWidget {
  const ZCodeApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>(
      create: (_) => AppState()..init(),
      child: Consumer<AppState>(
        builder: (BuildContext context, AppState state, Widget? _) {
          final AppConfig? c = state.config;
          final Accent accent = Accent.byId(c?.accentId);
          final double scale = c?.fontScale ?? 1.0;
          return MaterialApp(
            title: 'ZCode',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.build(accent.seed, Brightness.light, scale),
            darkTheme: AppTheme.build(accent.seed, Brightness.dark, scale),
            themeMode: AppTheme.modeOf(c?.themeMode ?? 'system'),
            // Setup and settings pages have no AppBar, so the bars are tinted
            // here for every route rather than only on scaffolded screens.
            builder: (BuildContext ctx, Widget? child) {
              final bool dark =
                  Theme.of(ctx).brightness == Brightness.dark;
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: AppTheme.systemUi(dark),
                child: child ?? const SizedBox.shrink(),
              );
            },
            home: const _Root(),
          );
        },
      ),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root({Key? key}) : super(key: key);

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  /// Floor for the splash, not a delay before it: `AppState.init()` runs in
  /// parallel, so the app leaves at whichever finishes last.
  static const Duration _floor = Duration(milliseconds: 520);

  bool _floorElapsed = false;
  bool _reducedMotion = false;
  Timer? _floorTimer;

  @override
  void initState() {
    super.initState();
    _reducedMotion = WidgetsBinding
        .instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    if (_reducedMotion) {
      _floorElapsed = true;
    } else {
      _floorTimer = Timer(_floor, () {
        if (mounted) setState(() => _floorElapsed = true);
      });
    }
  }

  @override
  void dispose() {
    _floorTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final bool splash = !state.ready || !_floorElapsed;
    return AnimatedSwitcher(
      duration: _reducedMotion ? Duration.zero : AppTokens.base,
      child: splash
          ? BrandSplash(
              key: const ValueKey<String>('splash'),
              animate: !_reducedMotion,
            )
          : state.session != null
              ? const HomeShell(key: ValueKey<String>('home'))
              : const LoginPage(key: ValueKey<String>('login')),
    );
  }
}
