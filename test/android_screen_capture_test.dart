import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_screen_capture.dart';

void main() {
  test('decodes the strict width/height + I420 platform frame', () {
    final bytes = Uint8List(8 + 8 + 2 + 2);
    final header = ByteData.sublistView(bytes);
    header.setUint32(0, 4);
    header.setUint32(4, 2);
    bytes.setRange(8, bytes.length, List<int>.generate(12, (i) => i));

    final frame = decodeAndroidScreenFrame(bytes);
    expect(frame, isNotNull);
    expect((frame!.width, frame.height), (4, 2));
    expect(frame.y, orderedEquals([0, 1, 2, 3, 4, 5, 6, 7]));
    expect(frame.u, orderedEquals([8, 9]));
    expect(frame.v, orderedEquals([10, 11]));
  });

  test('rejects malformed or unreasonable platform frames', () {
    expect(decodeAndroidScreenFrame(Uint8List(7)), isNull);

    final wrongLength = Uint8List(12);
    final header = ByteData.sublistView(wrongLength);
    header.setUint32(0, 4);
    header.setUint32(4, 2);
    expect(decodeAndroidScreenFrame(wrongLength), isNull);

    final oversized = Uint8List(8);
    final oversizedHeader = ByteData.sublistView(oversized);
    oversizedHeader.setUint32(0, 4096);
    oversizedHeader.setUint32(4, 4096);
    expect(decodeAndroidScreenFrame(oversized), isNull);
  });
}
