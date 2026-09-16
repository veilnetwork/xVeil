// Making a colour legible on another colour, and proving it.
//
// A theme may now choose its own background, which is the field that decides
// whether everything else can be read. Letting somebody pick it is only safe if
// the app can guarantee — not hope — that the text and the warnings stay
// visible on whatever they picked, including a background chosen precisely to
// hide them.
//
// The guarantee rests on one fact: against ANY colour, black or white reaches a
// contrast ratio of at least 4.58. The two are equal at relative luminance
// L where (L+0.05)/0.05 = 1.05/(L+0.05), i.e. L ≈ 0.179, and there both give
// ≈4.58. So a 4.5 target is always reachable, whatever the background, and
// [legibleOn] never has to give up and never has to refuse a colour.
//
// WCAG 2.1 contrast, as everything else that draws text does, so the numbers
// mean what a designer or an auditor expects them to mean.

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The ratio below which normal text stops being reliably readable (WCAG AA).
const double kMinTextContrast = 4.5;

/// WCAG relative luminance.
double relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

/// WCAG contrast ratio: 1.0 (identical) to 21.0 (black on white).
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// [wanted], moved only as far as it must be to be readable on [background].
///
/// Hue and saturation are kept for as long as they can be: a theme that asked
/// for an amber warning gets an amber warning, lightened or darkened until it
/// can be read. Only when the whole lightness range fails — a fully saturated
/// colour on a background of the same hue and lightness — does it fall back to
/// black or white, which the arithmetic above guarantees is enough.
///
/// Returns [wanted] unchanged when it already passes, so a theme that chose
/// well is not second-guessed.
Color legibleOn(
  Color wanted,
  Color background, {
  double minRatio = kMinTextContrast,
}) {
  if (contrastRatio(wanted, background) >= minRatio) return wanted;

  final hsl = HSLColor.fromColor(wanted);
  // Walk outward from the colour's own lightness, both ways at once, and take
  // the first step that passes. Outward rather than straight to the extreme so
  // the result is the CLOSEST readable version of what was asked for.
  for (var step = 1; step <= 100; step++) {
    final delta = step / 100;
    for (final candidate in [
      if (hsl.lightness + delta <= 1.0)
        hsl.withLightness(hsl.lightness + delta).toColor(),
      if (hsl.lightness - delta >= 0.0)
        hsl.withLightness(hsl.lightness - delta).toColor(),
    ]) {
      if (contrastRatio(candidate, background) >= minRatio) return candidate;
    }
  }

  // The floor, and it cannot fail: max(black, white) is ≥ 4.58 against every
  // colour there is.
  return contrastRatio(Colors.black, background) >=
          contrastRatio(Colors.white, background)
      ? Colors.black
      : Colors.white;
}

/// [wanted], moved until it is readable on EVERY one of [backgrounds].
///
/// One foreground has to survive several surfaces: this app draws text on the
/// background a theme chose AND on the slightly-raised panels above it — a
/// message bubble, a card, a dialog. Repairing against only one of them leaves
/// the others unproven, which is the same hole as not repairing at all, just
/// harder to see.
///
/// The whole list is checked rather than its extremes, because contrast is not
/// monotonic in the background's luminance: a foreground can read on both ends
/// of a range and vanish in the middle of it.
Color legibleOnAll(
  Color wanted,
  List<Color> backgrounds, {
  double minRatio = kMinTextContrast,
}) {
  bool passes(Color c) =>
      backgrounds.every((bg) => contrastRatio(c, bg) >= minRatio);
  if (passes(wanted)) return wanted;

  final hsl = HSLColor.fromColor(wanted);
  for (var step = 1; step <= 100; step++) {
    final delta = step / 100;
    for (final candidate in [
      if (hsl.lightness + delta <= 1.0)
        hsl.withLightness(hsl.lightness + delta).toColor(),
      if (hsl.lightness - delta >= 0.0)
        hsl.withLightness(hsl.lightness - delta).toColor(),
    ]) {
      if (passes(candidate)) return candidate;
    }
  }

  // The floor. Whichever of black and white reads best across the whole set —
  // and the panels are built to step AWAY from it (see `AppTheme`), so the one
  // that clears the background clears everything raised above it.
  double worst(Color c) => backgrounds
      .map((bg) => contrastRatio(c, bg))
      .reduce((a, b) => a < b ? a : b);
  return worst(Colors.black) >= worst(Colors.white)
      ? Colors.black
      : Colors.white;
}
