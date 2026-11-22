import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../widgets/brand_mark.dart';

/// Cold-start brand frame.
///
/// This replaces the bare progress spinner that used to sit here while the
/// config was read. It is not an extra wait: the splash and `AppState.init()`
/// start at the same moment, and the app leaves as soon as both are done. On a
/// fast device that means the animation is cut short; on a slow one it simply
/// sits still — either way it never adds time.
class BrandSplash extends StatefulWidget {
  const BrandSplash({Key? key, this.animate = true}) : super(key: key);

  final bool animate;

  @override
  State<BrandSplash> createState() => _BrandSplashState();
}

class _BrandSplashState extends State<BrandSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  late final Animation<double> _markFade = CurvedAnimation(
    parent: _c,
    curve: const Interval(0, 0.55, curve: Curves.easeOut),
  );
  late final Animation<double> _markScale = Tween<double>(begin: 0.94, end: 1)
      .animate(CurvedAnimation(
    parent: _c,
    curve: const Interval(0, 0.75, curve: Curves.easeOutCubic),
  ));
  late final Animation<double> _nameFade = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.30, 1, curve: Curves.easeOut),
  );
  /// The little mono line under the wordmark arrives last, so the splash ends
  /// on the product's voice rather than on a fading picture.
  late final Animation<double> _taglineFade = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.55, 1, curve: Curves.easeOut),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _c.forward();
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    return Material(
      // Without a Material ancestor, Text falls back to Flutter's debug
      // DefaultTextStyle (yellow double underline). The splash is the only
      // screen drawn outside a Scaffold, so it needs the canvas explicitly.
      type: MaterialType.canvas,
      color: p.bg,
      child: Center(
        child: FadeTransition(
          opacity: _markFade,
          child: ScaleTransition(
            scale: _markScale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // Same file as the launcher icon: the home screen and the
                // first frame of the app show one mark, not two.
                const AppIconTile(size: 84, radius: 0.26),
                const SizedBox(height: 20),
                FadeTransition(
                  opacity: _nameFade,
                  child: const BrandWordmark(size: 26),
                ),
                const SizedBox(height: 10),
                FadeTransition(
                  opacity: _taglineFade,
                  child: Text(
                    'TERMINAL AGENT',
                    style: TextStyle(
                      fontSize: 9,
                      fontFamily: 'monospace',
                      letterSpacing: 2.6,
                      color: p.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
