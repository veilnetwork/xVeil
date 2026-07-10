import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/vnote_message.dart';

void main() {
  test('vnote filename check', () {
    expect(isVnoteFileName('a.vnote'), isTrue);
    expect(isVnoteFileName('A.VNOTE'), isTrue);
    expect(isVnoteFileName('a.opus'), isFalse);
    expect(isVnoteFileName(null), isFalse);
  });

  test('sidecar round-trips with and without a thumb', () {
    final withThumb = encodeVnoteSidecar(4200, 'aGk=');
    final s1 = decodeVnoteSidecar(withThumb)!;
    expect(s1.durationMs, 4200);
    expect(s1.thumbB64, 'aGk=');

    final noThumb = encodeVnoteSidecar(900, null);
    final s2 = decodeVnoteSidecar(noThumb)!;
    expect(s2.durationMs, 900);
    expect(s2.thumbB64, isNull);
  });

  test('negative duration clamps to zero on encode', () {
    expect(decodeVnoteSidecar(encodeVnoteSidecar(-5, null))!.durationMs, 0);
  });

  test('malformed sidecars decode to null, never throw', () {
    expect(decodeVnoteSidecar(null), isNull);
    expect(decodeVnoteSidecar(''), isNull);
    expect(decodeVnoteSidecar('vw1:100::'), isNull, reason: 'voice tag');
    expect(decodeVnoteSidecar('vn1:'), isNull, reason: 'no separator');
    expect(decodeVnoteSidecar('vn1:abc:xx'), isNull, reason: 'bad duration');
    expect(decodeVnoteSidecar('vn1:-4:xx'), isNull, reason: 'negative');
    expect(decodeVnoteSidecar('iVBORw0KGgo='), isNull, reason: 'image thumb');
  });
}
