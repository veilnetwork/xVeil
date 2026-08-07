import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/chat/blurred_thumb.dart';

// The placeholder under a downloading photo or video note is a micro-thumb —
// 32 px on its long side at best, 16 at worst — blown up into a 260 px bubble.
// It has to read as a BLUR. It used to read as "soapy with squares", because
// the blur was a fixed 2.5 sigma while every source pixel was landing as a
// block of 8 to 16 px: enough blur to lose the detail, not enough to lose the
// grid.

void main() {
  test('the blur covers the pixel block at every rung of the thumb ladder', () {
    // A Gaussian noticeably narrower than the block leaves the grid visible;
    // this is the property that was broken, so it is the one asserted.
    for (final thumb in [32, 24, 16]) {
      final block = 260 / thumb;
      final sigma = thumbBlurSigma(thumbWidth: thumb, boxWidth: 260);
      expect(
        sigma,
        greaterThan(block / 2),
        reason: 'a $thumb px thumb blows up to ${block.toStringAsFixed(1)} px '
            'blocks; sigma $sigma would leave them visible',
      );
    }
  });

  test('the worst rung is blurred harder than the best one', () {
    // The ladder falls to 16 px for noisy images, which is where the blocks
    // are biggest and the old constant was furthest off.
    expect(
      thumbBlurSigma(thumbWidth: 16, boxWidth: 260),
      greaterThan(thumbBlurSigma(thumbWidth: 32, boxWidth: 260)),
    );
  });

  test('shapes survive: the blur stays under a whole block', () {
    // Blurring by a full block or more turns the preview into a colour wash.
    // Showing an outline is the entire reason a thumb travels in the message.
    for (final thumb in [32, 24, 16]) {
      final block = 260 / thumb;
      expect(thumbBlurSigma(thumbWidth: thumb, boxWidth: 260), lessThan(block));
    }
  });

  test('a thumb close to its box keeps the old softening', () {
    // Barely upscaled, the proportional sigma would be tiny and the
    // placeholder would pass for the finished image.
    expect(thumbBlurSigma(thumbWidth: 240, boxWidth: 260), 2.5);
  });

  test('a thumb of unknown size falls back rather than dividing by zero', () {
    // The decoder answers a frame late; until then the widget asks with 0.
    expect(thumbBlurSigma(thumbWidth: 0, boxWidth: 260), 2.5);
    expect(thumbBlurSigma(thumbWidth: 32, boxWidth: 0), 2.5);
  });
}
