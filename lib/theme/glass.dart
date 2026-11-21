import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Carries the active glass quality down the tree.
///
/// The important rule this enforces: only *fixed* surfaces (bars, dock,
/// sheets, floating buttons) may use [GlassQuality.full]. Cards inside a
/// scrolling list must stay on `flat` or `soft`, because every backdrop filter
/// is an offscreen pass and twenty of them in a ListView is how you turn a
/// 60fps phone into a 30fps phone.
class GlassScope extends InheritedWidget {
  const GlassScope({
    Key? key,
    required this.quality,
    required this.reduceMotion,
    required Widget child,
  }) : super(key: key, child: child);

  final GlassQuality quality;

  /// Mirrors `MediaQuery.disableAnimations`: when the user has asked the
  /// system for less motion, presses snap instead of springing.
  final bool reduceMotion;

  static GlassQuality qualityOf(BuildContext context) {
    final GlassScope? scope =
        context.dependOnInheritedWidgetOfExactType<GlassScope>();
    return scope?.quality ?? GlassQuality.soft;
  }

  static bool reduceMotionOf(BuildContext context) {
    final GlassScope? scope =
        context.dependOnInheritedWidgetOfExactType<GlassScope>();
    return scope?.reduceMotion ?? false;
  }

  @override
  bool updateShouldNotify(GlassScope old) =>
      old.quality != quality || old.reduceMotion != reduceMotion;
}

/// A translucent pane that refracts whatever is behind it.
///
/// Five layers, bottom to top: refraction (backdrop filter), tint, hairline
/// edge, specular sheen, content. Drop a layer and it stops reading as glass:
/// without the edge it is a sticker, without the sheen it is a grey box.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    Key? key,
    required this.child,
    this.radius = AppTokens.rLg,
    this.padding,
    this.quality,
    this.tintOpacity,
    this.blur = 14,
    this.sheen = true,
    this.shadow = true,
    this.border = true,
    this.blurBackground = true,
    this.clipBehavior = Clip.antiAlias,
  }) : super(key: key);

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;

  /// Overrides [GlassScope] for this surface only. Use `flat` inside lists.
  final GlassQuality? quality;

  /// Multiplies the palette tint alpha. Dark glass needs to be denser to keep
  /// text legible; light glass can be almost clear.
  final double? tintOpacity;
  final double blur;
  final bool sheen;
  final bool shadow;
  final bool border;

  /// False when the parent already blurs (a bar that contains this surface).
  final bool blurBackground;
  final Clip clipBehavior;

  ui.ImageFilter? _filter(GlassQuality q) {
    if (!blurBackground || q == GlassQuality.flat || blur == 0) return null;
    final ui.ImageFilter soft = ui.ImageFilter.blur(
      sigmaX: blur * (q == GlassQuality.full ? 0.42 : 1.0),
      sigmaY: blur * (q == GlassQuality.full ? 0.42 : 1.0),
      tileMode: TileMode.clamp,
    );
    if (q != GlassQuality.full) return soft;
    // 6% magnification: the backdrop is sampled slightly larger than the pane,
    // which is what makes the layer behave like a lens instead of a fogged
    // sheet. Kept small on purpose — more looks like a bug on text behind it.
    final Float64List m = Matrix4.diagonal3Values(1.06, 1.06, 1).storage;
    return ui.ImageFilter.compose(
      outer: soft,
      inner: ui.ImageFilter.matrix(m, filterQuality: FilterQuality.low),
    );
  }

  @override
  Widget build(BuildContext context) {
    final GlassQuality q = quality ?? GlassScope.qualityOf(context);
    final AppPalette p = AppPalette.of(context);
    final BorderRadius r = BorderRadius.circular(radius);
    // Dark glass is 6–8% white: dense enough to lift off a near-black
    // background, thin enough that the light pools still read through it.
    final double alpha =
        (tintOpacity ?? (p.isDark ? 0.075 : 0.56)).clamp(0.0, 1.0);

    Widget body = Container(
      decoration: BoxDecoration(
        color: p.glassTint.withValues(alpha: alpha),
        borderRadius: r,
        border: border
            ? Border.all(
                color: p.glassStroke,
                width: 0.8,
              )
            : null,
      ),
      clipBehavior: Clip.none,
      child: Stack(
        children: <Widget>[
          if (sheen)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: r,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[
                        p.glassHighlight,
                        p.glassHighlight.withValues(alpha: 0),
                      ],
                      stops: const <double>[0.0, 0.62],
                    ),
                  ),
                ),
              ),
            ),
          if (padding != null)
            Padding(padding: padding!, child: child)
          else
            child,
        ],
      ),
    );

    final ui.ImageFilter? filter = _filter(q);
    if (filter != null) {
      body = ClipRRect(
        borderRadius: r,
        clipBehavior: clipBehavior,
        child: BackdropFilter(filter: filter, child: body),
      );
    }

    if (shadow) {
      body = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: r,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: p.isDark ? 0.40 : 0.12),
              blurRadius: 22,
              spreadRadius: -8,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: body,
      );
    }
    return body;
  }
}

/// The flat counterpart for content that must never blur: message bubbles,
/// list cards, anything repeated inside a scroll view.
class SolidCard extends StatelessWidget {
  const SolidCard({
    Key? key,
    required this.child,
    this.radius = AppTokens.rLg,
    this.padding,
    this.color,
    this.border = true,
    this.onTap,
  }) : super(key: key);

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final bool border;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final BorderRadius r = BorderRadius.circular(radius);
    final Widget box = Container(
      decoration: BoxDecoration(
        color: color ?? p.surface,
        borderRadius: r,
        border: border ? Border.all(color: p.line, width: 0.8) : null,
      ),
      padding: padding,
      child: child,
    );
    if (onTap == null) return box;
    return PressScale(
      radius: radius,
      child: Material(
        color: Colors.transparent,
        borderRadius: r,
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          child: box,
        ),
      ),
    );
  }
}

/// Press feedback: grows slightly on hold, springs back on release.
///
/// Uses [Listener] rather than [GestureDetector] so it never competes with the
/// button underneath for the gesture arena.
class PressScale extends StatefulWidget {
  const PressScale({
    Key? key,
    required this.child,
    this.scale = AppTokens.pressScale,
    this.radius = AppTokens.rLg,
    this.enabled = true,
  }) : super(key: key);

  final Widget child;
  final double scale;
  final double radius;
  final bool enabled;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  void _set(bool v) {
    if (!widget.enabled || _down == v) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final bool reduced = GlassScope.reduceMotionOf(context);
    final bool animate = widget.enabled && !reduced;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: animate && _down ? widget.scale : 1.0,
        duration: _down ? AppTokens.instant : AppTokens.base,
        curve: _down ? AppTokens.press : AppTokens.spring,
        alignment: Alignment.center,
        child: widget.child,
      ),
    );
  }
}

/// Background: one calm base coat plus two barely-visible light pools.
///
/// The pools exist so the glass has something to bend. They are 4–6% alpha on
/// purpose — a saturated gradient behind tinted glass is the single most
/// recognisable "AI screenshot" tell.
class LiquidBackground extends StatefulWidget {
  const LiquidBackground({
    Key? key,
    required this.child,
    this.drift = true,
  }) : super(key: key);

  final Widget child;

  /// 28-second drift. Costs one transform per frame on a single layer.
  final bool drift;

  @override
  State<LiquidBackground> createState() => _LiquidBackgroundState();
}

class _LiquidBackgroundState extends State<LiquidBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 28),
  );

  @override
  void initState() {
    super.initState();
    if (widget.drift) _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool reduced = GlassScope.reduceMotionOf(context);
    final bool animate = widget.drift && !reduced;

    return DecoratedBox(
      decoration: BoxDecoration(color: p.bg),
      child: RepaintBoundary(
        child: Stack(
          children: <Widget>[
            Positioned(
              left: -120,
              top: -90,
              child: _Pool(
                size: 320,
                color: cs.primary.withValues(alpha: p.isDark ? 0.17 : 0.09),
                animation: animate ? _c : null,
                dx: 26,
                dy: 18,
              ),
            ),
            Positioned(
              right: -140,
              bottom: 40,
              child: _Pool(
                size: 360,
                color: (p.isDark ? const Color(0xFF2F5A78) : const Color(0xFF9FB6C9))
                    .withValues(alpha: p.isDark ? 0.20 : 0.16),
                animation: animate ? _c : null,
                dx: -22,
                dy: -16,
                mirror: true,
              ),
            ),
            Positioned.fill(child: widget.child),
          ],
        ),
      ),
    );
  }
}

class _Pool extends StatelessWidget {
  const _Pool({
    required this.size,
    required this.color,
    required this.animation,
    required this.dx,
    required this.dy,
    this.mirror = false,
  });

  final double size;
  final Color color;
  final Animation<double>? animation;
  final double dx;
  final double dy;
  final bool mirror;

  @override
  Widget build(BuildContext context) {
    final Widget pool = ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: <Color>[color, color.withValues(alpha: 0)],
            stops: const <double>[0.0, 1.0],
          ),
        ),
      ),
    );
    if (animation == null) return pool;
    return AnimatedBuilder(
      animation: animation!,
      builder: (BuildContext ctx, Widget? child) {
        final double t = Curves.easeInOut.transform(animation!.value);
        final double f = mirror ? 1 - t : t;
        return Transform.translate(
          offset: Offset(dx * (f - 0.5), dy * (f - 0.5)),
          child: child,
        );
      },
      child: pool,
    );
  }
}
