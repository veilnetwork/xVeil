import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart';

/// CROSS-NODE relay-key resolve on the LOCAL dev onion mesh — fast validation of
/// the cold-start fixes (STORE-accept for "RK" + warmup republish) without a
/// testnet deploy. F resolves R's relay X25519 by R's node_id over the local
/// DHT; the resolved key must equal R's own (ground truth from R).
///
/// Bring up:  scripts/dev-mailbox-onion.sh  (rebuilt veil-cli WITH the fixes)
/// then run with the env it prints (F=SENDER sock, R=RELAY sock + node id).
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final sockF = Platform.environment['XVEIL_TEST_SOCK_SENDER'];
  final sockR = Platform.environment['XVEIL_TEST_SOCK_RELAY'];
  final rIdHex = Platform.environment['XVEIL_RELAY_NODE_ID'];
  final skip = (dylib == null || dylib.isEmpty || sockF == null || sockF.isEmpty ||
          sockR == null || sockR.isEmpty || rIdHex == null || rIdHex.length != 64)
      ? 'set VEIL_FFI_DYLIB + XVEIL_TEST_SOCK_SENDER/RELAY + XVEIL_RELAY_NODE_ID(64hex)'
      : false;

  test('F resolves R\'s relay X25519 cross-node on the local mesh',
      timeout: const Timeout(Duration(seconds: 150)), () async {
    DynamicLibrary.open(dylib!);
    final rId = _hex(rIdHex!);
    final clientF = await VeilClient.connect(sockF!);
    final clientR = await VeilClient.connect(sockR!);
    try {
      final truth = await clientR.getRelayX25519Pubkey();
      expect(truth, isNotNull, reason: 'R not relay-capable');
      stderr.writeln('[xnode] R local key: ${truth!.length}B');

      Uint8List? resolved;
      var attempts = 0;
      while (resolved == null && attempts < 25) {
        attempts++;
        resolved = await clientF.lookupRelayX25519(rId);
        stderr.writeln('[xnode] attempt $attempts: '
            '${resolved == null ? "null" : "${resolved.length}B"}');
        if (resolved == null) await Future<void>.delayed(const Duration(seconds: 3));
      }
      expect(resolved, isNotNull,
          reason: 'F could not resolve R\'s relay X25519 cross-node');
      expect(resolved, truth, reason: 'resolved must equal R\'s own key');
      stderr.writeln('[xnode] ✓ cross-node relay X25519 resolved on the local mesh');
    } finally {
      await clientF.close();
      await clientR.close();
    }
  }, skip: skip);
}

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
