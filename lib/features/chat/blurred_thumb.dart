// The placeholder shown while a photo or video note is still downloading: the
// micro-thumb that travelled inside the message, blown up to fill the bubble.
//
// It has to look like a BLUR, not like a low-resolution image. Those read very
// differently: a blur says "this is still arriving", pixel blocks say "this is
// what you get".

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// How much to blur a [thumbWidth]-wide thumb blown up to [boxWidth].
///
/// The thumb is 32 px on its long side at best and 16 at worst (the generator
/// walks a 32/24/16 ladder until the PNG fits the advert's byte budget), and
/// the bubbles are 260 px wide. That is an 8x to 16x upscale, so every source
/// pixel lands as a block of that size. A FIXED sigma — it was 2.5 — is smaller
/// than the block it is meant to hide, which is why the preview came out soapy
/// AND square-edged at the same time: blurred enough to lose the detail,
/// not enough to lose the grid.
///
/// Sigma follows the upscale instead. [_blockShare] is deliberately below 1:
/// a Gaussian of about two thirds of a block erases the grid while the shapes
/// stay readable, which is the whole point of showing a preview at all.
double thumbBlurSigma({
  required int thumbWidth,
  required double boxWidth,
  double minimum = 2.5,
}) {
  if (thumbWidth <= 0 || boxWidth <= 0) return minimum;
  final block = boxWidth / thumbWidth;
  final sigma = block * _blockShare;
  // Never sharpen a thumb that is already close to the box: a big thumb still
  // wants the old softening so the placeholder does not pass for the real one.
  return sigma < minimum ? minimum : sigma;
}

const double _blockShare = 0.66;

/// The micro-thumb, upscaled to fill its box and blurred by enough to hide the
/// pixel grid at whatever upscale this particular thumb needs.
class BlurredThumb extends StatefulWidget {
  const BlurredThumb({
    super.key,
    required this.bytes,
    required this.boxWidth,
    this.fit = BoxFit.cover,
  });

  final Uint8List bytes;
  final double boxWidth;
  final BoxFit fit;

  @override
  State<BlurredThumb> createState() => _BlurredThumbState();
}

class _BlurredThumbState extends State<BlurredThumb> {
  int? _thumbWidth;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(BlurredThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) _measure();
  }

  /// The thumb's own width decides the blur, and only the decoder knows it.
  /// Until it answers, the old fixed sigma stands in — a frame of slightly
  /// crisp placeholder is better than a frame of nothing.
  Future<void> _measure() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      frame.image.dispose();
      codec.dispose();
      if (!mounted) return;
      setState(() => _thumbWidth = w);
    } catch (_) {
      // Undecodable thumb: the Image below will show its own error state.
    }
  }

  @override
  Widget build(BuildContext context) {
    final sigma = thumbBlurSigma(
      thumbWidth: _thumbWidth ?? 0,
      boxWidth: widget.boxWidth,
    );
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.decal,
      ),
      child: Image.memory(
        widget.bytes,
        fit: widget.fit,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
      ),
    );
  }
}
