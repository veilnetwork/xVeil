import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/sticker_message.dart';

void main() {
  test('sticker filename check', () {
    expect(isStickerFileName('a.stkr'), isTrue);
    expect(isStickerFileName('A.STKR'), isTrue);
    expect(isStickerFileName('a.png'), isFalse);
    expect(isStickerFileName('a.vnote'), isFalse);
    expect(isStickerFileName(null), isFalse);
  });
}
