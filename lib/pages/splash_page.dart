import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../widgets/brand_mark.dart';

/// Cold-start brand sequence.
///
/// It runs in parallel with `AppState.init()` and owns its own exit: the
/// terminal closes, the lockup fades, and only then does the root swap in the
/// real page. There is no cross-fade between the splash logo and the sign-in
/// page — that overlap is what made the old start look like two brand marks
/// sitting on top of each other.
///
/// Nothing here waits for the animation before reading config or restoring a
/// token. If initialisation finishes late, the sequence holds on its last brand
/// frame until [ready] turns true, then leaves.
class BrandSplash extends StatefulWidget {
  const BrandSplash({
    Key? key,
    required this.ready,
    this.animate = true,
    this.onDone,
    this.debugProgress,
  }) : super(key: key);

  /// True once config / token restore has finished. The exit is gated on this
  /// so the sequence never drops the user on a page that is not ready.
  final bool ready;

  /// False when the OS "reduce motion" setting is on: no timeline, no hold,
  /// just a static brand frame until [ready].
  final bool animate;

  /// Called after the exit finishes, once, by the splash itself.
  final VoidCallback? onDone;

  /// Visual-test hook: pins the intro to a fixed 0..1 progress instead of
  /// running it. Used only by the browser preview to capture deterministic
  /// frames; production always leaves it null.
  final double? debugProgress;

  @override
  State<BrandSplash> createState() => _BrandSplashState();
}

class _BrandSplashState extends State<BrandSplash>
    with TickerProviderStateMixin {
  /// Intro: icon -> wordmark -> terminal -> boot lines -> caret -> fold.
  static const Duration _introLength = Duration(milliseconds: 720);

  /// Exit: the lockup clears the screen before the next page appears.
  static const Duration _exitLength = Duration(milliseconds: 160);

  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: _introLength,
  );
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: _exitLength,
  );

  // Start at 0.22, not 0: the very first frame must already carry a trace of
  // the brand, otherwise the OS handover reads as a black/blank screen.
  late final Animation<double> _markFade = Tween<double>(begin: 0.22, end: 1)
      .animate(CurvedAnimation(
    parent: _intro,
    curve: const Interval(0, 0.15, curve: Curves.easeOut),
  ));
  late final Animation<double> _markScale = Tween<double>(begin: 0.93, end: 1)
      .animate(CurvedAnimation(
    parent: _intro,
    curve: const Interval(0, 0.18, curve: Curves.easeOutCubic),
  ));
  late final Animation<double> _nameReveal = CurvedAnimation(
    parent: _intro,
    curve: const Interval(0.10, 0.28, curve: AppTokens.emphasized),
  );
  late final Animation<double> _nameFade = CurvedAnimation(
    parent: _intro,
    curve: const Interval(0.10, 0.24, curve: Curves.easeOut),
  );
  late final Animation<double> _windowFade = CurvedAnimation(
    parent: _intro,
    curve: const Interval(0.24, 0.38, curve: Curves.easeOut),
  );
  late final Animation<double> _windowScale = Tween<double>(begin: 0.97, end: 1)
      .animate(CurvedAnimation(
    parent: _intro,
    curve: const Interval(0.24, 0.42, curve: Curves.easeOutCubic),
  ));
  late final Animation<double> _line1 = CurvedAnimation(
    parent: _intro,
    curve: const Interval(0.38, 0.50, curve: Curves.easeOut),
  );
  late final Animation<double> _line2 = CurvedAnimation(
    parent: _intro,
    curve: const Interval(0.46, 0.58, curve: Curves.easeOut),
  );
  late final Animation<double> _line3 = CurvedAnimation(
    parent: _intro,
    curve: const Interval(0.54, 0.66, curve: Curves.easeOut),
  );

  /// Two short blinks, then dark. Held with ConstantTween so the caret has
  /// real on/off phases instead of a sine-wave glow.
  late final Animation<double> _caret = TweenSequence<double>(
    <TweenSequenceItem<double>>[
      TweenSequenceItem(tween: ConstantTween<double>(1), weight: 4),
      TweenSequenceItem(tween: ConstantTween<double>(0), weight: 3),
      TweenSequenceItem(tween: ConstantTween<double>(1), weight: 4),
      TweenSequenceItem(tween: ConstantTween<double>(0), weight: 3),
    ],
  ).animate(CurvedAnimation(
    parent: _intro,
    curve: const Interval(0.66, 0.80),
  ));

  /// The terminal folds away; the lockup is what remains on screen.
  late final Animation<double> _fold = CurvedAnimation(
    parent: _intro,
    curve: const Interval(0.84, 1, curve: AppTokens.emphasized),
  );

  bool _doneCalled = false;

  @override
  void initState() {
    super.initState();
    _intro.addStatusListener(_onIntroStatus);
    _exit.addStatusListener(_onExitStatus);
    if (widget.debugProgress != null) {
      _intro.value = widget.debugProgress!.clamp(0.0, 1.0);
    } else if (widget.animate) {
      _intro.forward();
    } else {
      // Reduce motion: final static lockup, no timeline and no hold.
      _intro.value = 1;
    }
  }

  @override
  void didUpdateWidget(BrandSplash old) {
    super.didUpdateWidget(old);
    if (widget.ready && !old.ready) _maybeLeave();
  }

  void _onIntroStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _maybeLeave();
  }

  void _onExitStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_doneCalled) {
      _doneCalled = true;
      widget.onDone?.call();
    }
  }

  void _maybeLeave() {
    if (!widget.ready || !widget.animate || !mounted) return;
    if (_intro.status != AnimationStatus.completed) return;
    if (_exit.isAnimating || _exit.isCompleted) return;
    _exit.forward();
  }

  @override
  void dispose() {
    _intro.dispose();
    _exit.dispose();
    super.dispose();
  }

  /// Still values for reduce motion, where no controller is running.
  double _v(Animation<double> a, double still) =>
      widget.debugProgress != null || widget.animate ? a.value : still;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = AppPalette.of(context);
    final double width =
        (MediaQuery.sizeOf(context).width - 56).clamp(240.0, 324.0);

    return Material(
      // Splash is the only screen drawn outside a Scaffold. Without a canvas
      // Material, Text falls back to Flutter's debug style (double underline).
      type: MaterialType.canvas,
      color: p.bg,
      child: AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[_intro, _exit]),
        builder: (BuildContext context, Widget? _) {
          final double out =
              widget.debugProgress != null || widget.animate ? _exit.value : 0;
          final double folded = _v(_fold, 1);

          return Opacity(
            opacity: 1 - out,
            child: Transform.scale(
              scale: 1 + out * 0.012,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // ── brand lockup ────────────────────────────────────
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        Opacity(
                          opacity: _v(_markFade, 1),
                          child: Transform.scale(
                            scale: _v(_markScale, 1),
                            child: const AppIconTile(size: 38, radius: 0.26),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // A clipped width reveal reads as the word "unfolding";
                        // a plain fade would not carry the terminal feel.
                        SizedBox(
                          width: 86 * _v(_nameReveal, 1),
                          height: 30,
                          child: ClipRect(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Opacity(
                                opacity: _v(_nameFade, 1),
                                child: const BrandWordmark(size: 25),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    // ── terminal ────────────────────────────────────────
                    // Fixed height: lines appear inside it instead of pushing
                    // the lockup upward as they arrive.
                    Opacity(
                      opacity: _v(_windowFade, 0) * (1 - folded),
                      child: Transform.scale(
                        scale: _v(_windowScale, 1) * (1 - folded * 0.03),
                        child: SizedBox(
                          width: width,
                          height: 122,
                          child: _Terminal(
                            boot: _v(_line1, 1),
                            detail: _v(_line2, 1),
                            ready: _v(_line3, 1),
                            caret: _v(_caret, 1),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A real terminal window: title bar with three quiet lights, monospaced boot
/// lines and a block caret. Deliberately dark on both themes — the app
/// background behind it follows the theme, so there is no colour jump when it
/// folds away.
class _Terminal extends StatelessWidget {
  const _Terminal({
    Key? key,
    required this.boot,
    required this.detail,
    required this.ready,
    required this.caret,
  }) : super(key: key);

  final double boot;
  final double detail;
  final double ready;
  final double caret;

  @override
  Widget build(BuildContext context) {
    const Color shell = Color(0xFF0D131A);
    const Color bar = Color(0xFF121B24);
    const Color stroke = Color(0xFF293542);
    const Color text = Color(0xFFD8E0EA);
    const Color dim = Color(0xFF8493A4);
    const Color prompt = Color(0xFF5AD48A);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: shell,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: stroke, width: 1),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.34),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              height: 30,
              color: bar,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: <Widget>[
                  const _Light(Color(0xFFC96A6A)),
                  const _Light(Color(0xFFC7A45C)),
                  const _Light(Color(0xFF6EA67C)),
                  const Spacer(),
                  const Text(
                    'zcode — terminal',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontFamily: 'monospace',
                      letterSpacing: 0.2,
                      color: dim,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const Spacer(),
                  // Keep the three lights optically centred against the title.
                  const SizedBox(width: 27),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _BootLine(
                    opacity: boot,
                    child: const Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          TextSpan(
                            text: '\$ ',
                            style: TextStyle(color: prompt),
                          ),
                          TextSpan(text: 'zcode --boot'),
                        ],
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.35,
                        color: text,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  _BootLine(
                    opacity: detail,
                    child: const Text(
                      '  ZCode Mobile · workspace ready',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        height: 1.35,
                        color: dim,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  _BootLine(
                    opacity: ready,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Text(
                          '> ',
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: prompt,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const Text(
                          'ready',
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                            color: text,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Opacity(
                          opacity: caret,
                          child: Container(width: 7, height: 13, color: prompt),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Light extends StatelessWidget {
  const _Light(this.color, {Key? key}) : super(key: key);

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

class _BootLine extends StatelessWidget {
  const _BootLine({Key? key, required this.opacity, required this.child})
      : super(key: key);

  final double opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double a = opacity.clamp(0.0, 1.0);
    return Opacity(
      opacity: a,
      child: Transform.translate(
        offset: Offset(0, (1 - a) * 3),
        child: child,
      ),
    );
  }
}
