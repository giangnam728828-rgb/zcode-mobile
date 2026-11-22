import 'package:flutter/material.dart';

import '../theme/glass.dart';
import '../theme/tokens.dart';

class DockItem {
  const DockItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// Floating bottom navigation, one glass pane with a liquid selection pill.
///
/// Five destinations: Chat, Desktop remote, Files, Shell, Settings. The remote
/// tab earns its slot next to Chat (总方案 P0-5) — it is a daily surface, and
/// automation still lives inside Settings where configuration belongs.
class AppDock extends StatelessWidget {
  const AppDock({
    Key? key,
    required this.items,
    required this.index,
    required this.onSelect,
    this.quality,
  }) : super(key: key);

  static const double height = 58;

  final List<DockItem> items;
  final int index;
  final ValueChanged<int> onSelect;
  final GlassQuality? quality;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;

    return GlassSurface(
      radius: 26,
      quality: quality ?? GlassQuality.full,
      tintOpacity: p.isDark ? 0.10 : 0.58,
      blur: 18,
      padding: const EdgeInsets.all(5),
      child: SizedBox(
        height: height - 10,
        child: LayoutBuilder(
          builder: (BuildContext ctx, BoxConstraints c) {
            final double w = c.maxWidth / items.length;
            return Stack(
              children: <Widget>[
                AnimatedPositioned(
                  duration: AppTokens.base,
                  curve: AppTokens.spring,
                  left: index * w + 2,
                  width: w - 4,
                  top: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: p.isDark ? 0.22 : 0.14),
                      borderRadius: BorderRadius.circular(21),
                      border: Border.all(
                        color: cs.primary.withValues(alpha: 0.20),
                        width: 0.8,
                      ),
                    ),
                  ),
                ),
                Row(
                  children: List<Widget>.generate(items.length, (int i) {
                    final DockItem it = items[i];
                    final bool on = i == index;
                    return Expanded(
                      child: PressScale(
                        radius: 21,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onSelect(i),
                          child: Semantics(
                            selected: on,
                            button: true,
                            label: it.label,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                AnimatedSwitcher(
                                  duration: AppTokens.fast,
                                  child: Icon(
                                    on ? it.activeIcon : it.icon,
                                    key: ValueKey<bool>(on),
                                    size: 20,
                                    color: on
                                        ? cs.primary
                                        : p.textSecondary
                                            .withValues(alpha: 0.85),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                AnimatedDefaultTextStyle(
                                  duration: AppTokens.fast,
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    height: 1.1,
                                    fontWeight:
                                        on ? FontWeight.w600 : FontWeight.w500,
                                    color: on ? cs.primary : p.textTertiary,
                                  ),
                                  child: Text(it.label),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
