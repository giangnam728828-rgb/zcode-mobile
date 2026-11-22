import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../theme/tokens.dart';

/// Watches real frame timings right after launch and steps the glass down when
/// this device cannot hold the frame budget.
///
/// The rule from the design doc: keep `full` only on hardware that earns it.
/// Sampling starts on the first frame, ignores a short warm-up (first frames
/// pay for font loading and shader compilation and would condemn every phone),
/// then judges windows of [window] frames. One bad window drops one tier; a
/// second bad window drops to `flat`. It never climbs back up on its own — a
/// device that stuttered once will stutter again the moment a long list appears,
/// and oscillating quality is worse than a stable lower tier.
///
/// This is deliberately dependency-free: `FrameTiming` comes from the engine.
class GlassProbe extends ChangeNotifier {
  GlassProbe({
    GlassQuality start = GlassQuality.soft,
    this.warmup = 24,
    this.window = 120,
    this.budgetMs = 22.0,
    this.longFrameMs = 40.0,
    this.maxLongFrames = 2,
  }) : _quality = start;

  /// Frames skipped before measuring. 24 frames is ~0.4s at 60Hz.
  final int warmup;

  /// Frames per judgement window (~2s at 60Hz).
  final int window;

  /// p90 above this means the device is not holding ~45fps.
  final double budgetMs;

  /// A single frame this slow is a visible hitch.
  final double longFrameMs;

  /// How many hitches in one window tip the verdict.
  final int maxLongFrames;

  GlassQuality _quality;
  final List<double> _spans = <double>[];
  int _seen = 0;
  bool _running = false;
  bool _settled = false;
  TimingsCallback? _callback;

  GlassQuality get quality => _quality;

  /// True once it has measured everything it intends to.
  bool get settled => _settled;

  /// Tests drive frames through [addSample] instead of a real engine, so
  /// [start] is only called by the shell.
  bool get running => _running;

  void start() {
    if (_running) return;
    _running = true;
    // Debug builds run 3–5x slower than release; measuring them would drop
    // every developer to `flat` for no reason. Web reports synthetic timings
    // from `performance.now()` under swiftshader, equally meaningless.
    if (kIsWeb || !(kReleaseMode || kProfileMode)) {
      _settled = true;
      return;
    }
    _callback = _onTimings;
    SchedulerBinding.instance.addTimingsCallback(_callback!);
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      addSample(t.totalSpan.inMicroseconds / 1000.0);
      if (_settled) return;
    }
  }

  /// Feeds one frame. Public so tests can simulate a device without an engine.
  void addSample(double frameMs) {
    if (_settled) return;
    if (_seen++ < warmup) return;
    _spans.add(frameMs);
    if (_spans.length >= window) _judge();
  }

  void _judge() {
    final List<double> sample = List<double>.of(_spans);
    _spans.clear();
    if (!overBudget(
      sample,
      budgetMs: budgetMs,
      longFrameMs: longFrameMs,
      maxLongFrames: maxLongFrames,
    )) {
      _settle();
      return;
    }
    final GlassQuality? next = _quality.below;
    if (next == null) {
      _settle();
      return;
    }
    _quality = next;
    notifyListeners();
    // flat is the floor; no point burning another window on it.
    if (_quality == GlassQuality.flat) _settle();
  }

  void _settle() {
    _settled = true;
    if (_callback != null) {
      SchedulerBinding.instance.removeTimingsCallback(_callback!);
      _callback = null;
    }
  }

  /// Stops sampling without changing the verdict.
  void cancel() {
    _settled = true;
    if (_callback != null) {
      SchedulerBinding.instance.removeTimingsCallback(_callback!);
      _callback = null;
    }
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

  /// Pure verdict used by [_judge] and by tests.
  ///
  /// Fails when the 90th percentile sits above [budgetMs], or when at least
  /// [maxLongFrames] frames went past [longFrameMs]. The percentile catches a
  /// phone that is uniformly slow; the hitch count catches one that is mostly
  /// fine but stalls while scrolling.
  static bool overBudget(
    List<double> spans, {
    double budgetMs = 22.0,
    double longFrameMs = 40.0,
    int maxLongFrames = 2,
  }) {
    if (spans.isEmpty) return false;
    int long = 0;
    for (final double s in spans) {
      if (s > longFrameMs) long++;
    }
    if (long >= maxLongFrames) return true;
    return percentile(spans, 0.90) > budgetMs;
  }

  /// Nearest-rank percentile. Copies nothing when the input is already sorted,
  /// which it never is here — but the arrays are 120 doubles, so it can.
  static double percentile(List<double> values, double p) {
    if (values.isEmpty) return 0;
    final List<double> sorted = List<double>.of(values)..sort();
    final int rank = (p * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }
}
