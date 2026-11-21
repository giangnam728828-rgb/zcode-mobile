import 'package:flutter/material.dart';

import '../theme/glass.dart';
import '../theme/tokens.dart';

/// Shared top bar: a real glass pane that the transcript/breadcrumb scrolls
/// under, so the backdrop visibly bends at the seam.
///
/// Two modes:
/// * `embedded` (inside [RootShell]) — no back button, refractive glass.
/// * pushed route — same type scale, but a solid coat so the previous page
///   does not bleed through while the route transition is still settling.
class GlassHeader extends StatelessWidget {
  const GlassHeader({
    Key? key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const <Widget>[],
    this.embedded = true,
    this.border = true,
  }) : super(key: key);

  final String title;

  /// Small line under the title: path, cwd, model, count. Kept monospace by
  /// the caller when it is a filesystem path.
  final Widget? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final bool embedded;

  /// Bottom hairline. Off when the header sits directly on another glass bar.
  final bool border;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);

    final Widget bar = Padding(
      padding: EdgeInsets.fromLTRB(leading == null ? 18 : 4, 4, 6, 6),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: <Widget>[
            if (leading != null) leading!,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 17,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                      color: p.text,
                    ),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 2),
                    DefaultTextStyle.merge(
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.35,
                        color: p.textTertiary,
                      ),
                      child: subtitle!,
                    ),
                  ],
                ],
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );

    if (!embedded) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: p.bg,
          border: border
              ? Border(bottom: BorderSide(color: p.line, width: 0.8))
              : null,
        ),
        child: bar,
      );
    }

    return GlassSurface(
      radius: 0,
      blur: 18,
      quality: GlassQuality.full,
      shadow: false,
      border: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: border
              ? Border(bottom: BorderSide(color: p.line, width: 0.8))
              : null,
        ),
        child: bar,
      ),
    );
  }
}

/// Compact header action. Material's default 48dp box wastes the horizontal
/// space a phone barely has; this keeps the 40dp visual while tapping to 48.
class HeaderAction extends StatelessWidget {
  const HeaderAction({
    Key? key,
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.tint,
  }) : super(key: key);

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    return IconButton(
      icon: Icon(icon, size: 19.5, color: tint ?? p.textSecondary),
      tooltip: tooltip,
      onPressed: onTap,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(
        width: AppTokens.tapTarget,
        height: AppTokens.tapTarget,
      ),
    );
  }
}

/// Overflow menu with the same look as the rest of the header.
class HeaderMenu extends StatelessWidget {
  const HeaderMenu({
    Key? key,
    required this.tooltip,
    required this.items,
  }) : super(key: key);

  final String tooltip;

  /// `(icon, label, onTap)` triples. `onTap == null` renders the entry
  /// disabled instead of dropping it, so the menu does not jump in height.
  final List<HeaderMenuItem> items;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    return PopupMenuButton<int>(
      tooltip: tooltip,
      icon: Icon(Icons.more_horiz_rounded, size: 20, color: p.textSecondary),
      padding: EdgeInsets.zero,
      onSelected: (int i) => items[i].onTap?.call(),
      itemBuilder: (BuildContext ctx) => <PopupMenuEntry<int>>[
        for (int i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            value: i,
            enabled: items[i].onTap != null,
            height: 44,
            child: Row(
              children: <Widget>[
                Icon(
                  items[i].icon,
                  size: 17,
                  color: items[i].onTap == null
                      ? p.textTertiary.withValues(alpha: 0.5)
                      : p.textSecondary,
                ),
                const SizedBox(width: 10),
                Text(
                  items[i].label,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: items[i].onTap == null
                        ? p.textTertiary.withValues(alpha: 0.6)
                        : p.text,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class HeaderMenuItem {
  const HeaderMenuItem(this.icon, this.label, this.onTap);

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
}
