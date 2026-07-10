import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/thumbnail.dart';

void main() {
  test('isImageFileName recognizes common image extensions', () {
    for (final ok in [
      'photo.jpg',
      'IMG.JPEG',
      'a.png',
      'meme.gif',
      'x.webp',
      'scan.BMP',
    ]) {
      expect(isImageFileName(ok), isTrue, reason: ok);
    }
  });

  test('isImageFileName rejects non-images and null', () {
    for (final no in ['doc.pdf', 'clip.mp4', 'archive.zip', 'noext', '']) {
      expect(isImageFileName(no), isFalse, reason: no);
    }
    expect(isImageFileName(null), isFalse);
  });
}
