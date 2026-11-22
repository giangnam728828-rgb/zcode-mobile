import 'package:flutter/material.dart';

/// The launcher icon, rendered as a widget.
///
/// The app now has a single piece of brand art (`assets/brand/app_icon.png`).
/// The splash and the sign-in header both show that same file instead of
/// redrawing a simplified glyph, so the icon on the home screen and the mark
/// inside the app can never drift apart.
class AppIconTile extends StatelessWidget {
  const AppIconTile({
    Key? key,
    this.size = 28,
    this.radius = 0.24,
    this.border = true,
  }) : super(key: key);

  final double size;

  /// Corner radius as a fraction of [size]; 0.24 matches the launcher mask.
  final double radius;

  /// Hairline edge. Without it the art melts into a light background.
  final bool border;

  @override
  Widget build(BuildContext context) {
    final BorderRadius br = BorderRadius.circular(size * radius);
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: br,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Image.asset(
              'assets/brand/app_icon.png',
              fit: BoxFit.cover,
              // The art is line-heavy; medium filtering keeps the edges clean
              // when the tile is drawn at 26dp on a 3x screen.
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              // A missing or undecodable file must not take the first frame
              // down; fall back to the product's own prompt mark.
              errorBuilder: (BuildContext _, Object? __, StackTrace? ___) =>
                  const ColoredBox(
                color: Color(0xFF8FC7EA),
                child: Center(
                  child: Text(
                    '>_',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            if (border)
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: br,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.22),
                    width: 0.8,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Wordmark. Kept apart from [AppIconTile] so a wide layout can put them side
/// by side and a narrow one can stack them.
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({
    Key? key,
    this.size = 28,
    this.align = TextAlign.center,
    this.color,
  }) : super(key: key);

  final double size;
  final TextAlign align;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Text(
      'ZCode',
      textAlign: align,
      style: TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w700,
        height: 1.1,
        // Tight tracking on a short word reads as a wordmark, not as a
        // sentence that happens to be bold.
        letterSpacing: size * -0.02,
        color: color ?? cs.onSurface,
        decoration: TextDecoration.none,
      ),
    );
  }
}
