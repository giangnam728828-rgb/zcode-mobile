import 'package:flutter/material.dart';

import '../theme/glass.dart';
import '../theme/tokens.dart';
import 'glass_header.dart';

/// Shared frame for the second-tier screens (automation, modules, plugins,
/// workspace picker).
///
/// These are pushed routes, so they get the solid header coat rather than the
/// refractive one: a glass bar over a page that is still sliding in reads as a
/// smear. The backdrop still carries the light pools so the page does not look
/// like a different app from the four dock tabs.
class PageShell extends StatelessWidget {
  const PageShell({
    Key? key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions = const <Widget>[],
    this.subHeader,
    this.bottomBar,
    this.floating,
    this.showBack = true,
    this.drift = false,
  }) : super(key: key);

  final String title;
  final Widget? subtitle;
  final List<Widget> actions;

  /// Sits directly under the header: a TabBar, a filter row.
  final Widget? subHeader;
  final Widget child;

  /// Pinned above the bottom inset (the workspace picker's confirm button).
  final Widget? bottomBar;

  /// Floating action, already laid out; the shell only positions it.
  final Widget? floating;

  final bool showBack;

  /// The light pools are static by default — a 28-second drift on a settings
  /// sub-page costs frames for motion nobody asked to see.
  final bool drift;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final MediaQueryData mq = MediaQuery.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidBackground(
        drift: drift,
        child: Column(
          children: <Widget>[
            GlassHeader(
              title: title,
              subtitle: subtitle,
              embedded: false,
              leading: showBack
                  ? HeaderAction(
                      icon: Icons.arrow_back_rounded,
                      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                      onTap: () => Navigator.of(context).maybePop(),
                    )
                  : null,
              actions: actions,
            ),
            if (subHeader != null) subHeader!,
            Expanded(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(child: child),
                  if (floating != null)
                    Positioned(
                      right: AppTokens.gutter,
                      bottom: AppTokens.gutter + mq.padding.bottom,
                      child: floating!,
                    ),
                ],
              ),
            ),
            if (bottomBar != null)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: p.bg,
                  border: Border(top: BorderSide(color: p.line, width: 0.8)),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppTokens.gutter,
                      10,
                      AppTokens.gutter,
                      10,
                    ),
                    child: bottomBar!,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
