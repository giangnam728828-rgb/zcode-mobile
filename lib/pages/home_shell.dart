import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'automation_page.dart';
import 'chat_page.dart';
import 'sessions_drawer.dart';

/// Adaptive shell: drawer + single pane on phones, permanent sidebar beside a
/// centred transcript on tablets, foldables and the web build.
class HomeShell extends StatefulWidget {
  const HomeShell({Key? key}) : super(key: key);

  static const double breakpoint = 780;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The permission screen and the file manager both send us to the
    // background; on return the workspace may now be readable.
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<AppState>().refreshDeviceState();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final S s = S.of(state.config?.language);
    // A launcher shortcut asks for a page; the shell owns the navigator.
    if (state.pendingRoute != null) {
      final String? route = state.takeRoute();
      if (route == 'automation') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const AutomationPage()),
          );
        });
      }
    }
    final double width = MediaQuery.of(context).size.width;
    final bool wide = width >= HomeShell.breakpoint;

    if (wide) {
      final double sideWidth = math.min(320, width * 0.30);
      return Scaffold(
        body: Row(
          children: <Widget>[
            SizedBox(
              width: sideWidth,
              child: SessionsPanel(s: s, showSettings: true),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: Theme.of(context).dividerTheme.color,
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: ChatPage(s: s, wide: true),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      key: _scaffold,
      drawer: Drawer(
        width: math.min(320, width * 0.86),
        shape: const RoundedRectangleBorder(),
        child: SessionsPanel(
          s: s,
          onPicked: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ChatPage(
        s: s,
        wide: false,
        onOpenSessions: () => _scaffold.currentState?.openDrawer(),
      ),
    );
  }
}
