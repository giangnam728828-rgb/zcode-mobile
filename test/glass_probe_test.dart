import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_mobile/models/app_config.dart';
import 'package:zcode_mobile/state/glass_probe.dart';
import 'package:zcode_mobile/theme/tokens.dart';

void main() {
  group('frame math', () {
    test('percentile uses nearest rank', () {
      final List<double> v = <double>[10, 20, 30, 40, 50, 60, 70, 80, 90, 100];
      expect(GlassProbe.percentile(v, 0.90), 90);
      expect(GlassProbe.percentile(v, 0.50), 50);
      expect(GlassProbe.percentile(v, 1.0), 100);
      expect(GlassProbe.percentile(<double>[], 0.9), 0);
    });

    test('a steady 60fps window is within budget', () {
      expect(
        GlassProbe.overBudget(List<double>.filled(120, 16.7)),
        isFalse,
      );
    });

    test('a uniformly slow window trips the p90 rule', () {
      expect(
        GlassProbe.overBudget(List<double>.filled(120, 26.0)),
        isTrue,
      );
    });

    test('two hitches trip the long-frame rule even when p90 looks fine', () {
      final List<double> spans = List<double>.filled(120, 16.0);
      spans[10] = 52.0;
      spans[80] = 44.0;
      expect(GlassProbe.overBudget(spans), isTrue);
    });

    test('one hitch alone is tolerated', () {
      final List<double> spans = List<double>.filled(120, 16.0);
      spans[10] = 52.0;
      expect(GlassProbe.overBudget(spans), isFalse);
    });
  });

  group('probe ladder', () {
    GlassProbe probe(GlassQuality start, {int window = 10}) => GlassProbe(
          start: start,
          warmup: 0,
          window: window,
        );

    void feed(GlassProbe p, int frames, double ms) {
      for (int i = 0; i < frames; i++) {
        p.addSample(ms);
      }
    }

    test('drops soft to flat in one bad window and stops', () {
      final GlassProbe p = probe(GlassQuality.soft);
      feed(p, 10, 30);
      expect(p.quality, GlassQuality.flat);
      expect(p.settled, isTrue);
    });

    test('full takes two windows: full -> soft -> flat', () {
      final GlassProbe p = probe(GlassQuality.full);
      feed(p, 10, 30);
      expect(p.quality, GlassQuality.soft);
      expect(p.settled, isFalse);
      feed(p, 10, 30);
      expect(p.quality, GlassQuality.flat);
      expect(p.settled, isTrue);
    });

    test('a healthy window settles without moving', () {
      final GlassProbe p = probe(GlassQuality.soft);
      feed(p, 10, 16.5);
      expect(p.quality, GlassQuality.soft);
      expect(p.settled, isTrue);
    });

    test('warm-up frames are ignored so launch jank does not condemn a device', () {
      final GlassProbe p = GlassProbe(
        start: GlassQuality.soft,
        warmup: 5,
        window: 10,
      );
      feed(p, 5, 60); // shader compilation, font loading
      expect(p.quality, GlassQuality.soft);
      feed(p, 10, 16.5);
      expect(p.quality, GlassQuality.soft);
      expect(p.settled, isTrue);
    });

    test('never climbs back up after a bad window', () {
      final GlassProbe p = probe(GlassQuality.full);
      feed(p, 10, 30);
      expect(p.quality, GlassQuality.soft);
      feed(p, 10, 16.5);
      expect(p.quality, GlassQuality.soft);
    });

    test('a probe started at flat settles without moving', () {
      final GlassProbe p = probe(GlassQuality.flat);
      feed(p, 20, 60);
      expect(p.quality, GlassQuality.flat);
      expect(p.settled, isTrue);
    });
  });

  group('glass preference', () {
    test('auto resolves through the measured tier', () {
      expect(GlassQuality.isAuto('auto'), isTrue);
      expect(GlassQuality.isAuto('soft'), isFalse);
      expect(GlassQuality.isAuto(null), isFalse, reason: 'null is "unknown", not "auto"');
      expect(
        GlassQuality.resolve('auto', autoTier: GlassQuality.flat),
        GlassQuality.flat,
      );
      expect(GlassQuality.resolve('full'), GlassQuality.full);
    });

    test('the ladder is one-way and stops at flat', () {
      expect(GlassQuality.full.below, GlassQuality.soft);
      expect(GlassQuality.soft.below, GlassQuality.flat);
      expect(GlassQuality.flat.below, isNull);
    });
  });

  group('config carries the auto state', () {
    test('a fresh config starts on auto', () {
      expect(AppConfig.empty.glassQuality, 'auto');
      expect(AppConfig.empty.glassAutoTier, 'soft');
      expect(AppConfig.empty.glassAutoHinted, isFalse);
    });

    test('round-trips the measured tier', () {
      final AppConfig c = AppConfig.empty.copyWith(
        glassQuality: 'auto',
        glassAutoTier: 'flat',
        glassAutoHinted: true,
      );
      final AppConfig back = AppConfig.decode(c.encode());
      expect(back.glassQuality, 'auto');
      expect(back.glassAutoTier, 'flat');
      expect(back.glassAutoHinted, isTrue);
    });

    test('a pre-3.8 config is handed to the probe', () {
      final AppConfig old = AppConfig.decode(
        '{"provider":"bigmodel","baseUrl":"https://x","apiKey":"k",'
        '"model":"m","systemPrompt":"p","maxTokens":4096,'
        '"glassQuality":"soft"}',
      );
      expect(old.glassQuality, 'auto');
      expect(old.glassAutoTier, 'soft');
      expect(old.glassAutoHinted, isFalse);
    });

    test('an explicit lock survives the round-trip', () {
      final AppConfig locked = AppConfig.empty.copyWith(
        glassQuality: 'flat',
        glassAutoHinted: false,
      );
      expect(AppConfig.decode(locked.encode()).glassQuality, 'flat');
    });
  });
}
