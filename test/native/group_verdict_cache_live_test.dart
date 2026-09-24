import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/state/group_crypto.dart';

/// A group row's signature is verified once, not on every read of the group.
///
/// Every read verified every row again, and on the stand 94 rows cost up to
/// five seconds a read. The cache may only ever answer what the native check
/// would: the same row gets the same verdict without asking again, and any
/// change to what was signed — or the passing of the cache's window — is asked
/// afresh.
///
/// Env-gated:
///   VEIL_FFI_DYLIB = libveilclient_ffi
void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final skip = dylib == null || dylib.isEmpty
      ? 'set VEIL_FFI_DYLIB to libveilclient_ffi'
      : false;

  test('a verdict is remembered, and only for exactly what was signed', () {
    final lib = DynamicLibrary.open(dylib!);
    // Pre-mined: mining a 24-bit identity in a debug library takes a minute.
    final identityToml = File(
      'test/native/fixtures/ratchet_state_identity_0.toml',
    ).readAsStringSync();
    final message = Uint8List.fromList('a group row'.codeUnits);
    final signed = signDetachedIdentity(
      identityToml: identityToml,
      message: message,
      lib: lib,
    );
    final signer = NodeId(blake3Hash(signed.publicKey));
    bool verify(Uint8List msg, Uint8List sig) => verifyDetachedIdentity(
      signer: signer,
      publicKey: signed.publicKey,
      message: msg,
      signature: sig,
      lib: lib,
    );

    debugClearVerdicts();
    var clock = DateTime(2026, 9, 24, 12);
    debugVerdictClock = () => clock;
    addTearDown(() => debugVerdictClock = DateTime.now);
    final start = debugNativeVerifications;

    expect(verify(message, signed.signature), isTrue);
    expect(debugNativeVerifications - start, 1);
    expect(verify(message, signed.signature), isTrue);
    expect(
      debugNativeVerifications - start,
      1,
      reason: 'the same row read again is not verified again',
    );

    final tampered = Uint8List.fromList(message)..[0] ^= 1;
    expect(
      verify(tampered, signed.signature),
      isFalse,
      reason: 'a different message never inherits the verdict',
    );
    final forged = Uint8List.fromList(signed.signature)..[0] ^= 1;
    expect(verify(message, forged), isFalse);
    expect(debugNativeVerifications - start, 3, reason: 'both asked afresh');

    clock = clock.add(const Duration(minutes: 6));
    expect(verify(message, signed.signature), isTrue);
    expect(
      debugNativeVerifications - start,
      4,
      reason: 'past its window the verdict is asked for again',
    );
  }, skip: skip);
}
