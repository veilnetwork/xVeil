import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/features/contacts/qr_scan_screen.dart';

void main() {
  test('QR capture ignores empty values and trims a valid veil invite', () {
    final decision = classifyScannedInviteValues([
      null,
      '',
      '   ',
      '  veil:invite?payload=abc  ',
    ]);

    expect(decision.invite, 'veil:invite?payload=abc');
    expect(decision.sawNonInvite, isFalse);
  });

  test('valid invite wins when the same capture has another barcode', () {
    final decision = classifyScannedInviteValues([
      'https://example.invalid',
      'veil:signed-invite?payload=abc',
    ]);

    expect(decision.invite, 'veil:signed-invite?payload=abc');
    expect(decision.sawNonInvite, isTrue);
  });

  test('non-invite capture remains distinguishable from an empty frame', () {
    final nonInvite = classifyScannedInviteValues(['mailto:user@example.com']);
    final empty = classifyScannedInviteValues([null, '']);

    expect(nonInvite.invite, isNull);
    expect(nonInvite.sawNonInvite, isTrue);
    expect(empty.invite, isNull);
    expect(empty.sawNonInvite, isFalse);
  });
}
