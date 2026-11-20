import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'models/app_config.dart';
import 'pages/home_shell.dart';
import 'pages/login_page.dart';
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

class _Root extends StatelessWidget {
  const _Root({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    if (!state.ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final bool signedIn = state.session != null;
    if (!signedIn) {
      return const LoginPage();
    }
    return const HomeShell();
  }
}
