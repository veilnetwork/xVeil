// The document half of link and revoke carries the CREDENTIAL, not just the
// words.
//
// This file used to assert the opposite feature: that a certificate-restored
// identity is refused link and revoke up front, because both reached native
// calls that derived the master from a PHRASE and a recovery code is not one.
// That refusal was honest about a gap, and the gap turned out to be much wider
// than certificates — it took in every HYBRID identity, which is what this app
// now creates by default. A hybrid master is 929 bytes of Ed25519+Falcon-512
// and the identity's address is hashed over all of them, so a phrase-derived
// 32-byte master matches no hybrid document: `UnsupportedMasterAlgo`, every
// time. An identity that could never gain a second device, nor disown a stolen
// one. Found by standing two daemons up on 2026-09-12, not by a test.
//
// A source guard because what has to hold is a property of the call sites: the
// credential is read where the document is amended, and handed to the native
// side. A closed-loop test cannot see it — the fake has no master to sign with
// and the native call is where the choice lands.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final stack = File('lib/data/veil_stack.dart').readAsStringSync();

  /// The body of the named static method, by brace matching from its `async {`.
  String bodyOf(String signature) {
    final start = stack.indexOf(signature);
    expect(start, isNot(-1), reason: '$signature was renamed or removed');
    var i = stack.indexOf('async {', start);
    expect(i, isNot(-1), reason: '$signature is no longer an async body');
    i += 'async '.length;
    var depth = 0;
    final open = i;
    for (; i < stack.length; i++) {
      if (stack[i] == '{') depth++;
      if (stack[i] == '}') {
        depth--;
        if (depth == 0) return stack.substring(open, i + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  for (final site in const [
    'static Future<DeviceDelegation> delegateDeviceIntoDocument(',
    'static Future<DocumentRevocation> revokeDeviceFromDocument(',
  ]) {
    test('$site signs with the identity\'s own master', () {
      final body = bodyOf(site);
      expect(
        body,
        contains('readSovereignCredential('),
        reason:
            'without reading the credential this call can only build the '
            'Ed25519 master a phrase gives, which a hybrid identity\'s '
            'document does not name — the operation then refuses, always',
      );
      expect(
        body,
        contains('credential: credential'),
        reason:
            'reading the credential and not passing it is the same failure '
            'with an extra read',
      );
    });
  }

  test('the native wrappers take a credential at all', () {
    final node = File('lib/data/node/embedded_node.dart').readAsStringSync();
    for (final fn in const [
      'static void delegateDevice({',
      'static bool revokeIdentityDevice({',
    ]) {
      final start = node.indexOf(fn);
      expect(start, isNot(-1), reason: '$fn was renamed or removed');
      final head = node.substring(start, start + 260);
      expect(
        head,
        contains('Uint8List? credential'),
        reason:
            'a wrapper without this parameter cannot reach '
            'veil_delegate_device_zeroize / veil_revoke_identity_device_zeroize '
            'with anything but a phrase',
      );
    }
  });
}
