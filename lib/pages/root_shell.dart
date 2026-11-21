import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../state/dock_visibility.dart';
import '../theme/glass.dart';
import '../theme/tokens.dart';
import '../widgets/app_dock.dart';
import 'chat_page.dart';
import 'files_page.dart';
import 'sessions_drawer.dart';
import 'settings_page.dart';
import 'terminal_page.dart';

/// Phone shell: four destinations behind one floating glass dock.
///
/// Pages are kept alive in an [IndexedStack] so switching tabs never loses a
/// half-typed message or a scroll position. Automation, modules and plugins are
/// deliberately **not** tabs — they live in Settings, which is where you go
/// when you are configuring rather than working.
class RootShell extends StatefulWidget {
  const RootShell({Key? key, required this.s, this.initialIndex = 0})
      : super(key: key);

  final S s;

  /// Used by the developer preview to screenshot a specific tab; the app itself
  /// always opens on the conversation.
  final int initialIndex;

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell>
    with SingleTickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: AppTokens.base,
    value: 1,
  );

  late int _index = widget.initialIndex.clamp(0, 3);

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    _fade.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final S s = widget.s;
    final MediaQueryData mq = MediaQuery.of(context);
    final bool keyboard = mq.viewInsets.bottom > 0;

    final double dockGap =
        keyboard ? 0 : AppDock.height + 26 + mq.padding.bottom;

    final List<Widget> pages = <Widget>[
      ChatPage(
        s: s,
        wide: false,
        embedded: true,
        onOpenSessions: () => _scaffold.currentState?.openDrawer(),
      ),
      const FilesPage(embedded: true),
      const TerminalPage(embedded: true),
      const SettingsPage(embedded: true),
    ];

    final List<DockItem> items = <DockItem>[
      DockItem(
        icon: Icons.chat_bubble_outline_rounded,
        activeIcon: Icons.chat_bubble_rounded,
        label: s.isEnglish ? 'Chat' : '对话',
      ),
      DockItem(
        icon: Icons.folder_outlined,
        activeIcon: Icons.folder_rounded,
        label: s.isEnglish ? 'Files' : '文件',
      ),
      DockItem(
        icon: Icons.terminal_outlined,
        activeIcon: Icons.terminal_rounded,
        label: s.isEnglish ? 'Shell' : '终端',
      ),
      DockItem(
        icon: Icons.tune_rounded,
        activeIcon: Icons.tune_rounded,
        label: s.isEnglish ? 'Settings' : '设置',
      ),
    ];

    return GlassScope(
      quality: GlassQuality.parse(state.config?.glassQuality),
      reduceMotion: mq.disableAnimations,
      child: Scaffold(
        key: _scaffold,
        backgroundColor: Colors.transparent,
        drawerScrimColor: Colors.black.withValues(alpha: 0.4),
        drawer: Drawer(
          width: mq.size.width * 0.86,
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: _SessionsDrawer(s: s),
        ),
        body: LiquidBackground(
          child: Stack(
            children: <Widget>[
              // Reserving the dock's height by shrinking the page area (rather
              // than padding inside each page) keeps every scroll view honest:
              // nothing can end up under the bar, and pages do not each need to
              // know the dock exists.
              Padding(
                padding: EdgeInsets.only(bottom: dockGap),
                child: FadeTransition(
                  opacity: CurvedAnimation(
                    parent: _fade,
                    curve: AppTokens.decelerate,
                  ),
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.012),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(
                      parent: _fade,
                      curve: AppTokens.emphasized,
                    )),
                    child: IndexedStack(index: _index, children: pages),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: mq.padding.bottom + 10,
                child: ValueListenableBuilder<bool>(
                  valueListenable: DockVisibility.tucked,
                  builder: (BuildContext ctx, bool tucked, Widget? _) {
                    final bool away = keyboard || tucked;
                    return IgnorePointer(
                      ignoring: away,
                      child: AnimatedSlide(
                        duration: AppTokens.base,
                        curve: AppTokens.emphasized,
                        // Tucked only drops 0.55 of its height: the bar leans
                        // out of the way instead of flying off, which makes it
                        // obvious it is still there.
                        offset: Offset(0, keyboard ? 1.4 : (tucked ? 0.55 : 0)),
                        child: AnimatedOpacity(
                          duration: keyboard ? AppTokens.fast : AppTokens.base,
                          opacity: away ? 0 : 1,
                          child: AppDock(
                            items: items,
                            index: _index,
                            onSelect: _select,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Drawer content wrapper. The sessions panel paints its own background; this
/// only rounds it and gives the drawer edge a soft cut.
class _SessionsDrawer extends StatelessWidget {
  const _SessionsDrawer({required this.s});

  final S s;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    return ClipRRect(
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(20)),
      child: ColoredBox(
        color: p.surface,
        child: SessionsPanel(
          s: s,
          onPicked: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}
