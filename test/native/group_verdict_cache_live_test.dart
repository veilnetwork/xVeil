import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/identity/veil_identity.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/domain/group.dart';
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

  test(
    'a delegated cache hit cannot change the key/signature boundary',
    () async {
      final lib = DynamicLibrary.open(dylib!);
      final dir = await Directory.systemTemp.createTemp('xveil-cache-binding-');
      addTearDown(() async => dir.delete(recursive: true));
      final toml = File(
        'test/native/fixtures/ratchet_state_identity_0.toml',
      ).readAsStringSync();
      final phrase = veilGeneratePhrase()!;
      final credential = EmbeddedNode.createHybridSovereignBundle(
        phrase,
        lib: lib,
      );
      try {
        EmbeddedNode.provisionHybridSovereignIdentity(
          credential,
          phrase,
          veilDir: dir.path,
          instanceLabel: 'cache-binding',
          nodeConfigToml: toml,
          lib: lib,
        );
      } finally {
        credential.fillRange(0, credential.length, 0);
      }
      final files = await collectSovereignIdentity(dir.path);
      final document = files[kIdentityDocumentFile]!;
      final identity = NodeId(
        EmbeddedNode.identityDocumentNodeId(document, lib: lib),
      );
      final message = Uint8List.fromList('delegated cache row'.codeUnits);
      final signed = signDetachedIdentity(
        identityToml: toml,
        message: message,
        lib: lib,
      );
      expect(NodeId(blake3Hash(signed.publicKey)), isNot(identity));
      Uint8List? heldDocument = document;
      setIdentityDocumentLookup((id) => id == identity ? heldDocument : null);
      addTearDown(() => setIdentityDocumentLookup(null));
      debugClearVerdicts();
      addTearDown(debugClearVerdicts);
      bool verify(Uint8List key, Uint8List sig) => verifyDetachedIdentity(
        signer: identity,
        publicKey: key,
        message: message,
        signature: sig,
        lib: lib,
      );
      expect(verify(signed.publicKey, signed.signature), isTrue);
      final key31 = Uint8List.sublistView(signed.publicKey, 0, 31);
      final sig65 = Uint8List.fromList([
        signed.publicKey.last,
        ...signed.signature,
      ]);
      // Their concatenation is byte-for-byte the original key || signature.
      // A cache must not authorize them before native shape checks can refuse.
      expect(verify(key31, sig65), isFalse);
      final key33 = Uint8List.fromList([
        ...signed.publicKey,
        signed.signature.first,
      ]);
      final sig63 = Uint8List.sublistView(signed.signature, 1);
      expect(verify(key33, sig63), isFalse);
      expect(verify(signed.publicKey, signed.signature), isTrue);
      heldDocument = null;
      expect(verify(signed.publicKey, signed.signature), isFalse);
      heldDocument = Uint8List.fromList([0xff, ...document.sublist(1)]);
      expect(verify(signed.publicKey, signed.signature), isFalse);
      heldDocument = Uint8List.fromList(document);
      expect(verify(signed.publicKey, signed.signature), isTrue);

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final control = signControlEntry(
        identityToml: toml,
        unsigned: ControlEntry(
          groupId: identity,
          author: identity,
          seq: 0,
          prevHash: '',
          op: ControlOp.setName,
          target: null,
          role: null,
          policyVersion: 1,
          createdAtMs: now * 1000,
          signature: Uint8List(0),
          text: 'cache clock',
        ),
        lib: lib,
      );
      expect(verifyControlEntry(control, lib: lib), isTrue);
      expect(verifyControlEntry(control, atUnixSecs: now, lib: lib), isTrue);
      expect(verifyControlEntry(control, atUnixSecs: 1, lib: lib), isFalse);
      expect(verifyControlEntry(control, atUnixSecs: now, lib: lib), isTrue);
    },
    skip: skip,
  );
}
