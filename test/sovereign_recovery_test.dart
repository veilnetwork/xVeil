import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/sovereign_recovery.dart';

void main() {
  test('XVRC copy text round-trips and exposes the bound node id', () {
    final bytes = Uint8List(96);
    bytes.setAll(0, 'XVRC'.codeUnits);
    bytes[4] = 1;
    bytes[5] = 1;
    for (var i = 0; i < 32; i++) {
      bytes[6 + i] = i;
    }
    final certificate = SovereignRecoveryCertificate.fromBytes(bytes);
    final parsed = SovereignRecoveryCertificate.parse(certificate.toText());
    expect(parsed.bytes, bytes);
    expect(parsed.nodeId.bytes, List<int>.generate(32, (i) => i));
  });

  test('XVRC copy text rejects wrong magic, version and hostile size', () {
    final bad = Uint8List(96)..setAll(0, 'NOPE'.codeUnits);
    expect(
      () => SovereignRecoveryCertificate.fromBytes(bad),
      throwsFormatException,
    );
    final version = Uint8List(96)..setAll(0, 'XVRC'.codeUnits);
    version[4] = 2;
    expect(
      () => SovereignRecoveryCertificate.fromBytes(version),
      throwsFormatException,
    );
    expect(
      () => SovereignRecoveryCertificate.parse(
        'xveil-recovery:v1:${List.filled(25000, 'A').join()}',
      ),
      throwsFormatException,
    );
  });
}
