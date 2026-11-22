import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'models/app_config.dart';
import 'pages/home_shell.dart';
import 'pages/login_page.dart';
import 'pages/splash_page.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';

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
  bool _introDone = false;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _reducedMotion = WidgetsBinding
        .instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    // Reduced motion shows a static lockup and leaves as soon as init is
    // ready: no timeline and no artificial floor.
    if (_reducedMotion) _introDone = true;
  }

  void _onIntroDone() {
    if (mounted) setState(() => _introDone = true);
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final bool splash = !state.ready || !_introDone;

    // The splash fades its own content out before calling _onIntroDone, so
    // this 160ms transition only hands the background over to the page. The
    // logo is never on screen while the sign-in page is appearing.
    return AnimatedSwitcher(
      duration: _reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 160),
      child: splash
          ? BrandSplash(
              key: const ValueKey<String>('splash'),
              ready: state.ready,
              animate: !_reducedMotion,
              onDone: _onIntroDone,
            )
          : state.session != null
              ? const HomeShell(key: ValueKey<String>('home'))
              : const LoginPage(key: ValueKey<String>('login')),
    );
  }
}
