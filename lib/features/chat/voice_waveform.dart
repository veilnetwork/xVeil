// Voice-message waveform (voice epic): a compact bar-graph of clip amplitudes,
// shared by the record indicator (live), the sent/received bubble, and the
// playback progress overlay. Pure paint — no state of its own.

import 'package:flutter/material.dart';

/// Paints [bars] (each 0..1) as rounded vertical bars. [progress] (0..1) splits
/// them into a "played" colour and an "unplayed" colour — pass 0 for a static
/// waveform (record indicator / undelivered bubble), or the playback fraction
/// for the progress overlay.
class VoiceWaveform extends StatelessWidget {
  const VoiceWaveform({
    super.key,
    required this.bars,
    required this.playedColor,
    required this.unplayedColor,
    this.progress = 0,
    this.barWidth = 3,
    this.gap = 2,
    this.minBarFraction = 0.08,
  });

  final List<double> bars;
  final Color playedColor;
  final Color unplayedColor;

  /// Fraction 0..1 of the clip already played — bars left of it use
  /// [playedColor], the rest [unplayedColor].
  final double progress;

  final double barWidth;
  final double gap;

  /// Shortest a bar can render as a fraction of the box height, so a silent
  /// window still shows a dot rather than nothing.
  final double minBarFraction;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _WaveformPainter(
        bars: bars,
        played: playedColor,
        unplayed: unplayedColor,
        progress: progress.clamp(0.0, 1.0),
        barWidth: barWidth,
        gap: gap,
        minBarFraction: minBarFraction,
      ),
      size: Size.infinite,
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.bars,
    required this.played,
    required this.unplayed,
    required this.progress,
    required this.barWidth,
    required this.gap,
    required this.minBarFraction,
  });

  final List<double> bars;
  final Color played;
  final Color unplayed;
  final double progress;
  final double barWidth;
  final double gap;
  final double minBarFraction;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty || size.width <= 0 || size.height <= 0) return;
    // Fit as many of the [bars] as the width allows, right-truncating — the
    // sender always sends a fixed count, so this only trims on a very narrow
    // box.
    final slot = barWidth + gap;
    final maxBars = ((size.width + gap) / slot).floor().clamp(1, bars.length);
    final step = bars.length / maxBars;
    final playedCount = (progress * maxBars).round();
    final paint = Paint()..style = PaintingStyle.fill;
    final radius = Radius.circular(barWidth / 2);
    for (var i = 0; i < maxBars; i++) {
      final srcIdx = (i * step).floor().clamp(0, bars.length - 1);
      final h =
          (bars[srcIdx].clamp(0.0, 1.0) * (1 - minBarFraction) +
              minBarFraction) *
          size.height;
      final x = i * slot;
      final top = (size.height - h) / 2;
      paint.color = i < playedCount ? played : unplayed;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, top, barWidth, h), radius),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.bars != bars ||
      old.played != played ||
      old.unplayed != unplayed;
}
