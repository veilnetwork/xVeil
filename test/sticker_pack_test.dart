import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/sticker_message.dart';

void main() {
  test('pack container round-trips name + images', () {
    final imgs = [
      Uint8List.fromList([1, 2, 3, 4]),
      Uint8List.fromList([9, 8, 7]),
    ];
    final blob = encodeStickerPack('My Pack', imgs);
    final back = decodeStickerPack(blob)!;
    expect(back.name, 'My Pack');
    expect(back.images.length, 2);
    expect(back.images[0], [1, 2, 3, 4]);
    expect(back.images[1], [9, 8, 7]);
  });

  test('empty-name and empty-list packs are still valid', () {
    final blob = encodeStickerPack('', const []);
    final back = decodeStickerPack(blob)!;
    expect(back.name, '');
    expect(back.images, isEmpty);
  });

  test('malformed blobs decode to null, never throw', () {
    expect(decodeStickerPack(Uint8List(0)), isNull);
    expect(decodeStickerPack(Uint8List.fromList([1, 2, 3])), isNull);
    // Right magic but a length that runs past the buffer.
    final b = BytesBuilder()
      ..add(ascii.encode('STKP'))
      ..addByte(1)
      ..add([0, 0]) // nameLen 0
      ..add([1, 0]) // count 1
      ..add([255, 255, 255, 255]); // len ~4G, no data
    expect(decodeStickerPack(b.toBytes()), isNull);
  });

  test('trailing garbage is rejected', () {
    final blob = encodeStickerPack('x', [Uint8List.fromList([1])]);
    final withTail = Uint8List.fromList([...blob, 0, 0]);
    expect(decodeStickerPack(withTail), isNull);
  });

  test('pack filename check', () {
    expect(isStickerPackFileName('a.stkpack'), isTrue);
    expect(isStickerPackFileName('a.stkr'), isFalse);
    expect(isStickerPackFileName(null), isFalse);
  });
}
