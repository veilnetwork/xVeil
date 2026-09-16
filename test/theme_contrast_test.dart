// A theme may choose its background. It may not choose to hide the warnings.
//
// This is the test the whole "bring your own background" feature rests on. The
// app writes what a person cannot afford to miss in the error colour — "this
// password opens a container that is already here", "the words restore a
// DIFFERENT identity", "compaction drops what you do not name" — and a
// background is the one field that can make those unreadable without ever
// naming them.
//
// So the property is checked against backgrounds chosen to break it, not
// against pretty ones: every colour the format can express, the error colour
// itself, and the two extremes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/theme_spec.dart';
import 'package:xveil/theme/app_theme.dart';
import 'package:xveil/theme/contrast.dart';

/// Backgrounds a hostile theme would actually try.
Iterable<Color> adversarialBackgrounds() sync* {
  // The extremes, where one of black/white is useless.
  yield const Color(0xFF000000);
  yield const Color(0xFFFFFFFF);
  // Mid grey: the worst case for BOTH black and white, where the best
  // achievable ratio is about 4.58 and nothing else clears 4.5.
  yield const Color(0xFF777777);
  yield const Color(0xFF808080);
  // Saturated primaries and the reds an error colour lives among — a red
  // background is the obvious way to hide a red warning.
  for (final c in [
    0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00, 0xFF00FFFF, 0xFFFF00FF,
    0xFFB3261E, 0xFFFFB4AB, 0xFF8C1D18, 0xFFDC362E,
  ]) {
    yield Color(c);
  }
  // And a spread across the whole cube, so this is not a list of cases
  // somebody thought of.
  for (var r = 0; r < 256; r += 51) {
    for (var g = 0; g < 256; g += 51) {
      for (var b = 0; b < 256; b += 51) {
        yield Color(0xFF000000 | (r << 16) | (g << 8) | b);
      }
    }
  }
}

void main() {
  group('the arithmetic the guarantee rests on', () {
    test('black or white always reaches 4.5 against anything', () {
      for (final bg in adversarialBackgrounds()) {
        final best = [
          contrastRatio(Colors.black, bg),
          contrastRatio(Colors.white, bg),
        ].reduce((a, b) => a > b ? a : b);
        expect(
          best,
          greaterThanOrEqualTo(kMinTextContrast),
          reason:
              'no legible foreground exists for '
              '#${bg.toARGB32().toRadixString(16)} — the floor is not a floor',
        );
      }
    });

    test('a colour that already reads is left alone', () {
      // A theme that chose well must not be second-guessed into something else.
      const bg = Color(0xFF101010);
      const fg = Color(0xFFFFCC00);
      expect(legibleOn(fg, bg), fg);
    });

    test('a colour that does not read is moved, and keeps its hue', () {
      const bg = Color(0xFF8C1D18);
      const fg = Color(0xFF8C1D18); // itself: ratio 1.0
      final fixed = legibleOn(fg, bg);
      expect(contrastRatio(fixed, bg), greaterThanOrEqualTo(kMinTextContrast));
      expect(
        HSLColor.fromColor(fixed).hue,
        closeTo(HSLColor.fromColor(fg).hue, 1.0),
        reason: 'an amber warning should stay amber, only readable',
      );
    });
  });

  group('no background can hide a warning', () {
    test('the error colour stays readable on every background there is', () {
      for (final bg in adversarialBackgrounds()) {
        final theme = AppTheme.of(
          ThemeSpec(
            id: 'x',
            name: 'x',
            seed: const Color(0xFF1E8A7B),
            dark: relativeLuminance(bg) < 0.2,
            background: bg,
          ),
        );
        final scheme = theme.colorScheme;
        expect(
          contrastRatio(scheme.error, scheme.surface),
          greaterThanOrEqualTo(kMinTextContrast),
          reason:
              'a warning is unreadable on background '
              '#${bg.toARGB32().toRadixString(16)}',
        );
        expect(
          contrastRatio(scheme.onSurface, scheme.surface),
          greaterThanOrEqualTo(kMinTextContrast),
          reason:
              'ordinary text is unreadable on background '
              '#${bg.toARGB32().toRadixString(16)}',
        );
      }
    });

    test('every surface the app raises is a surface text was proved on', () {
      // A bubble, a card and a dialog are not the background — they are drawn
      // on top of it — and they carry the SAME onSurface text. Repairing
      // against the background alone left those unproven, which is how a dark
      // theme under a light seed got white text on a pale bubble.
      for (final bg in adversarialBackgrounds()) {
        final scheme = AppTheme.of(
          ThemeSpec(
            id: 'x',
            name: 'x',
            seed: const Color(0xFF1E8A7B),
            dark: relativeLuminance(bg) < 0.2,
            background: bg,
          ),
        ).colorScheme;
        final surfaces = {
          'surface': scheme.surface,
          'lowest': scheme.surfaceContainerLowest,
          'low': scheme.surfaceContainerLow,
          'container': scheme.surfaceContainer,
          'high': scheme.surfaceContainerHigh,
          'highest': scheme.surfaceContainerHighest,
          'bubble': scheme.primaryContainer,
          'chip': scheme.secondaryContainer,
          'tertiary box': scheme.tertiaryContainer,
          'warning box': scheme.errorContainer,
        };
        for (final entry in surfaces.entries) {
          for (final fg in {
            'text': scheme.onSurface,
            'secondary text': scheme.onSurfaceVariant,
            'warning': scheme.error,
            // Not a border in this app: hints, timestamps and icons are drawn
            // in it on a dozen screens (report27 X30).
            'outline': scheme.outline,
            'outline variant': scheme.outlineVariant,
          }.entries) {
            expect(
              contrastRatio(fg.value, entry.value),
              greaterThanOrEqualTo(kMinTextContrast),
              reason:
                  '${fg.key} is unreadable on ${entry.key} for background '
                  '#${bg.toARGB32().toRadixString(16)}',
            );
          }
        }
      }
    });

    test('a button that moved keeps a label that can be read on it', () {
      // `primary` is the fill of every filled button and `error` of every
      // destructive one. Moving a fill without its label is how a button ends
      // up saying nothing legible — including the one that deletes things.
      for (final bg in adversarialBackgrounds()) {
        final scheme = AppTheme.of(
          ThemeSpec(
            id: 'x',
            name: 'x',
            seed: const Color(0xFF1E8A7B),
            dark: relativeLuminance(bg) < 0.2,
            background: bg,
          ),
        ).colorScheme;
        for (final pair in [
          (scheme.onPrimary, scheme.primary, 'primary'),
          (scheme.onSecondary, scheme.secondary, 'secondary'),
          (scheme.onError, scheme.error, 'error'),
          (scheme.onPrimaryContainer, scheme.primaryContainer, 'bubble'),
          (scheme.onSecondaryContainer, scheme.secondaryContainer, 'chip'),
          (scheme.onErrorContainer, scheme.errorContainer, 'warning box'),
        ]) {
          expect(
            contrastRatio(pair.$1, pair.$2),
            greaterThanOrEqualTo(kMinTextContrast),
            reason:
                'a ${pair.$3} button is unlabelled for background '
                '#${bg.toARGB32().toRadixString(16)}',
          );
        }
      }
    });

    test('the background a theme asked for is the background it gets', () {
      // The repair must touch the FOREGROUNDS. A feature that quietly replaced
      // the chosen background would be safe and pointless.
      for (final bg in [
        const Color(0xFF221133),
        const Color(0xFFEFEFEF),
        const Color(0xFF777777),
      ]) {
        final theme = AppTheme.of(
          ThemeSpec(
            id: 'x',
            name: 'x',
            seed: const Color(0xFF1E8A7B),
            dark: true,
            background: bg,
          ),
        );
        expect(theme.colorScheme.surface.toARGB32(), bg.toARGB32());
        expect(theme.scaffoldBackgroundColor.toARGB32(), bg.toARGB32());
      }
    });

    test('a theme with no background of its own is untouched', () {
      // The seven built-ins and every theme made before this existed: their
      // surface still comes from the seed, exactly as it did.
      final plain = AppTheme.of(kDefaultTheme);
      final seeded = ColorScheme.fromSeed(
        seedColor: kDefaultTheme.seed,
        brightness: Brightness.dark,
      );
      expect(plain.colorScheme.surface.toARGB32(), seeded.surface.toARGB32());
      expect(plain.colorScheme.error.toARGB32(), seeded.error.toARGB32());
      expect(
        plain.colorScheme.surfaceContainerHighest.toARGB32(),
        seeded.surfaceContainerHighest.toARGB32(),
        reason: 'the panels of a seeded theme are still Material\'s own',
      );
    });
  });

  group('the background travels with the theme', () {
    test('it survives being shared and read back', () {
      const spec = ThemeSpec(
        id: 'mine',
        name: 'Night',
        seed: Color(0xFF7B4A8A),
        dark: true,
        background: Color(0xFF120A18),
      );
      expect(ThemeSpec.parse(spec.toText()), spec);
    });

    test('a theme without one still reads, and stays without one', () {
      const spec = ThemeSpec(
        id: 'mine',
        name: 'Plain',
        seed: Color(0xFF7B4A8A),
        dark: true,
      );
      final back = ThemeSpec.parse(spec.toText());
      expect(back, spec);
      expect(back!.background, isNull);
    });

    test('a background cannot arrive translucent', () {
      final spec = ThemeSpec.fromJson({'c': 'ff8800', 'b': '00112233'});
      expect(spec!.background!.a, 1.0);
    });
  });
}
