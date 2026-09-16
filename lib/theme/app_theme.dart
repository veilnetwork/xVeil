import 'package:flutter/material.dart';

import '../domain/theme_spec.dart';
import 'contrast.dart';

/// Visual identity. Material 3, seeded from a deep veil-teal. Dark is the
/// default — calmer for a privacy tool and the expected look for the audience.
class AppTheme {
  static const _seed = Color(0xFF1E8A7B);

  static ThemeData light() => _build(Brightness.light, _seed);
  static ThemeData dark() => _build(Brightness.dark, _seed);

  /// The look a chosen theme asks for.
  ///
  /// EVERYTHING comes from the seed, which is the whole of the safety story:
  /// a theme travels between people, and one that could name colours directly
  /// could name the error colour — the one this app writes its warnings in.
  /// `ColorScheme.fromSeed` derives the roles with its own contrast rules, so
  /// a shared theme chooses the character of the interface and cannot choose
  /// whether a warning looks like one.
  static ThemeData of(ThemeSpec spec) => _build(
    spec.dark ? Brightness.dark : Brightness.light,
    spec.seed,
    background: spec.background,
  );

  static ThemeData _build(
    Brightness brightness,
    Color seed, {
    Color? background,
  }) {
    var scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    if (background != null) {
      // THE BACKGROUND IS HONOURED, THE FOREGROUNDS ARE REPAIRED.
      //
      // A theme may choose what everything is drawn on. It may not choose
      // whether a warning can be read on it — this app writes the sentences a
      // person cannot afford to miss in the error colour, and a background is
      // the one field that hides them without ever naming them.
      //
      // So the chosen colour goes in untouched and every colour that carries
      // TEXT is moved, as little as it can be, until it clears WCAG AA against
      // it. Against any colour there is, black or white reaches 4.58, so this
      // can always succeed and never has to refuse what somebody asked for.
      //
      // The PANELS come from the background too, not from the seed. A raised
      // surface — a message bubble, a card, a dialog — carries the same
      // `onSurface` text as the background does, so a panel left seeded is a
      // surface nothing was repaired against: a dark background under a light
      // seed gave white text on a pale bubble, and the safety story had a hole
      // in it the width of every message in the app.
      //
      // EVERY surface stays on ONE SIDE of the pivot where black and white
      // swap places (relative luminance ~0.179). That is the whole proof: on
      // the light side black clears 4.5 against all of them, on the dark side
      // white does, so one pair of text colours can be repaired once and be
      // right on every panel, bubble and chip the app draws. A family that
      // straddles the pivot has no such colour — a warning legible on the
      // background is invisible on the bubble, whatever it is moved to.
      final onLightSide = relativeLuminance(background) >= _pivotLuminance;
      Color onSide(Color c) => _towardSide(c, light: onLightSide);
      // Raised panels move the way Material moves them: away from the
      // background, then back onto the side if the step went too far.
      Color panel(double t) => onSide(
        Color.lerp(background, onLightSide ? Colors.black : Colors.white, t)!,
      );
      final low = panel(0.04);
      final mid = panel(0.07);
      final high = panel(0.10);
      final highest = panel(0.14);
      // The CONTAINER fills follow too — a message bubble, a chip, a warning
      // box. The app writes `onSurface` and `onSurfaceVariant` on those in
      // places (a timestamp inside a bubble, a label on a chip), so a
      // container left seeded is one more surface the repair never saw: a red
      // background gave a bubble at luminance 0.13 under a surface at 0.21,
      // and nothing readable existed for both.
      Color container(Color role) => onSide(Color.lerp(mid, role, 0.22)!);
      final primaryContainer = container(scheme.primary);
      final secondaryContainer = container(scheme.secondary);
      final tertiaryContainer = container(scheme.tertiary);
      final errorContainer = container(scheme.error);
      final surfaces = [
        background,
        low,
        mid,
        high,
        highest,
        primaryContainer,
        secondaryContainer,
        tertiaryContainer,
        errorContainer,
      ];
      final primary = legibleOnAll(scheme.primary, surfaces);
      final secondary = legibleOnAll(scheme.secondary, surfaces);
      final error = legibleOnAll(scheme.error, surfaces);
      scheme = scheme.copyWith(
        primaryContainer: primaryContainer,
        secondaryContainer: secondaryContainer,
        tertiaryContainer: tertiaryContainer,
        errorContainer: errorContainer,
        onPrimaryContainer: legibleOn(
          scheme.onPrimaryContainer,
          primaryContainer,
        ),
        onSecondaryContainer: legibleOn(
          scheme.onSecondaryContainer,
          secondaryContainer,
        ),
        onTertiaryContainer: legibleOn(
          scheme.onTertiaryContainer,
          tertiaryContainer,
        ),
        onErrorContainer: legibleOn(scheme.onErrorContainer, errorContainer),
        surface: background,
        surfaceContainerLowest: background,
        surfaceContainerLow: low,
        surfaceContainer: mid,
        surfaceContainerHigh: high,
        surfaceContainerHighest: highest,
        onSurface: legibleOnAll(scheme.onSurface, surfaces),
        onSurfaceVariant: legibleOnAll(scheme.onSurfaceVariant, surfaces),
        error: error,
        primary: primary,
        secondary: secondary,
        // A moved fill takes its label with it. `primary` is the background of
        // every filled button and `error` of every destructive one; repairing
        // one without the other is how a button ends up with a label that
        // cannot be read on it.
        onPrimary: legibleOn(scheme.onPrimary, primary),
        onSecondary: legibleOn(scheme.onSecondary, secondary),
        onError: legibleOn(scheme.onError, error),
      );
    }
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // Size.fromHeight uses an infinite width. That works in a bounded
          // form but makes every FilledButton impossible to lay out inside a
          // Row, including compact trailing actions on desktop.
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  /// Where black and white are equally readable: below it white wins, above it
  /// black does. Both reach about 4.58 exactly here, which is why a surface
  /// family that stays on one side can always be written on.
  static const double _pivotLuminance = 0.179;

  /// The luminance a surface must keep for BLACK text to clear WCAG AA on it
  /// ((L+0.05)/0.05 >= 4.5), and the one it must stay under for WHITE to.
  static const double _blackFloor = 0.175;
  static const double _whiteCeiling = 0.1833;

  /// [c], moved only if it has fallen off its side of the pivot.
  ///
  /// Hue and saturation are untouched; only lightness moves, and only as far
  /// as it must. A colour already on its side comes back unchanged, so a
  /// theme's panels look like what it asked for.
  static Color _towardSide(Color c, {required bool light}) {
    bool ok(Color x) => light
        ? relativeLuminance(x) >= _blackFloor
        : relativeLuminance(x) <= _whiteCeiling;
    if (ok(c)) return c;
    var hsl = HSLColor.fromColor(c);
    for (var i = 0; i < 100; i++) {
      final next = (hsl.lightness + (light ? 0.01 : -0.01)).clamp(0.0, 1.0);
      if (next == hsl.lightness) break;
      hsl = hsl.withLightness(next);
      if (ok(hsl.toColor())) return hsl.toColor();
    }
    // Unreachable for any real colour — white is above the floor and black is
    // below the ceiling — but a wrong answer here would be an unreadable app,
    // so it ends at the extreme that is certainly on the right side.
    return light ? Colors.white : Colors.black;
  }
}
