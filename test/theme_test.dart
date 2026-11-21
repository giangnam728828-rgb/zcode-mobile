import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_mobile/theme/tokens.dart';

double _luminance(Color c) => c.computeLuminance();

void main() {
  group('design tokens', () {
    test('radii increase monotonically so the scale stays usable', () {
      const List<double> r = <double>[
        AppTokens.rXs,
        AppTokens.rSm,
        AppTokens.rMd,
        AppTokens.rLg,
        AppTokens.rXl,
      ];
      for (int i = 1; i < r.length; i++) {
        expect(r[i], greaterThan(r[i - 1]));
      }
    });

    test('motion durations are ordered fast < base < slow', () {
      expect(AppTokens.fast.inMilliseconds,
          lessThan(AppTokens.base.inMilliseconds));
      expect(AppTokens.base.inMilliseconds,
          lessThan(AppTokens.slow.inMilliseconds));
    });

    test('press scale grows without shoving neighbours', () {
      expect(AppTokens.pressScale, greaterThan(1.0));
      expect(AppTokens.pressScale, lessThanOrEqualTo(1.06));
    });
  });

  group('palette', () {
    test('dark surfaces are lighter than the backdrop', () {
      expect(_luminance(AppPalette.dark.surface),
          greaterThan(_luminance(AppPalette.dark.bg)));
      expect(_luminance(AppPalette.dark.surfaceRaised),
          greaterThan(_luminance(AppPalette.dark.surface)));
    });

    test('light surfaces are brighter than the backdrop', () {
      expect(_luminance(AppPalette.light.surface),
          greaterThan(_luminance(AppPalette.light.bg)));
    });

    test('body text clears 4.5:1 against its surface', () {
      double contrast(Color a, Color b) {
        final double la = _luminance(a) + 0.05;
        final double lb = _luminance(b) + 0.05;
        return la > lb ? la / lb : lb / la;
      }

      expect(contrast(AppPalette.dark.text, AppPalette.dark.surface),
          greaterThan(4.5));
      expect(contrast(AppPalette.light.text, AppPalette.light.surface),
          greaterThan(4.5));
      // Secondary text is the one that usually fails; keep it at 4.5 too.
      expect(contrast(AppPalette.dark.textSecondary, AppPalette.dark.surface),
          greaterThan(4.5));
      expect(contrast(AppPalette.light.textSecondary, AppPalette.light.surface),
          greaterThan(4.5));
    });
  });

  group('glass quality', () {
    test('unknown ids fall back to soft', () {
      expect(GlassQuality.parse('full'), GlassQuality.full);
      expect(GlassQuality.parse('flat'), GlassQuality.flat);
      expect(GlassQuality.parse('nonsense'), GlassQuality.soft);
      expect(GlassQuality.parse(null), GlassQuality.soft);
    });

    test('round-trips through the config string', () {
      for (final GlassQuality q in GlassQuality.values) {
        expect(GlassQuality.parse(q.id), q);
      }
    });
  });
}
