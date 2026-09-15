import 'dart:convert';
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

  group('a certificate that was copied rather than downloaded', () {
    // The export sheet puts a copy button next to the save button, so a copy
    // is an ordinary way to hold this — and a copy comes back through whatever
    // carried it. Refusing those is how someone with a perfectly good
    // certificate concludes their backup is worthless.
    /// A certificate shaped the way the native writer shapes one, because the
    /// trailing-text case is decided by the HEADER: magic(4) version(1)
    /// kdf(1) node_id(32) m_cost(4) t_cost(4) p_cost(1) salt_len(1) salt(16)
    /// nonce_len(1) nonce(12) ct_len(4) ciphertext. A hand-rolled blob with a
    /// zeroed header would prove nothing here — it is exactly the shape the
    /// parser declines to trim.
    Uint8List sample() {
      final bytes = Uint8List(97);
      bytes.setAll(0, 'XVRC'.codeUnits);
      bytes[4] = 1; // version
      bytes[5] = 1; // Argon2id
      for (var i = 0; i < 32; i++) {
        bytes[6 + i] = i;
      }
      bytes[41] = 0x01; // m_cost, low byte
      bytes[45] = 3; // t_cost
      bytes[46] = 4; // p_cost
      bytes[47] = 16; // salt_len
      bytes[64] = 12; // nonce_len
      bytes[80] = 16; // ct_len
      for (var i = 81; i < 97; i++) {
        bytes[i] = 0x5A;
      }
      return bytes;
    }

    test('line breaks inside the body do not make it a different file', () {
      final text = SovereignRecoveryCertificate.fromBytes(sample()).toText();
      final wrapped =
          '${text.substring(0, 20)}\n${text.substring(20, 40)}\n'
          '${text.substring(40)}';
      expect(SovereignRecoveryCertificate.parse(wrapped).bytes, sample());
    });

    test('a label in front of it and a sentence after it are packaging', () {
      final text = SovereignRecoveryCertificate.fromBytes(sample()).toText();
      expect(
        SovereignRecoveryCertificate.parse(
          'xVeil recovery certificate:\n$text\nkeep the code separately.',
        ).bytes,
        sample(),
      );
    });

    test('tolerance about packaging is not tolerance about content', () {
      // The control. Each of these reaches the tolerant path and must still
      // be refused: no prefix at all, a prefix with nothing base64url after
      // it, and a body that decodes to something that is not an XVRC.
      expect(
        () => SovereignRecoveryCertificate.parse('my 24 words are elsewhere'),
        throwsFormatException,
      );
      expect(
        () => SovereignRecoveryCertificate.parse('xveil-recovery:v1: !!!'),
        throwsFormatException,
      );
      final notXvrc = Uint8List(96)..setAll(0, 'XVSB'.codeUnits);
      notXvrc[4] = 1;
      expect(
        () => SovereignRecoveryCertificate.parse(
          'xveil-recovery:v1:${base64Url.encode(notXvrc).replaceAll('=', '')}',
        ),
        throwsFormatException,
      );
    });
  });
}
