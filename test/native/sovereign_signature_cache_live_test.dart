import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;
import 'package:xveil/crypto/sovereign_signature_cache.dart';
import 'package:xveil/crypto/verification_cache_digest.dart';
import 'package:xveil/data/identity/veil_identity.dart' show veilGeneratePhrase;
import 'package:xveil/data/node/embedded_node.dart';

void main() {
  final path = Platform.environment['VEIL_FFI_DYLIB'];
  test(
    'cached Ed25519 and hybrid checks match native binding and tampering',
    () {
      final lib = DynamicLibrary.open(path!);
      final phrase = veilGeneratePhrase()!;
      final bundle = EmbeddedNode.createHybridSovereignBundle(phrase, lib: lib);
      final signers = [
        veil.VeilSovereignSigner.open(phrase),
        veil.VeilSovereignSigner.openBundle(bundle, phrase),
      ];
      addTearDown(() {
        for (final signer in signers) {
          signer.close();
        }
        bundle.fillRange(0, bundle.length, 0);
      });
      for (final signer in signers) {
        var calls = 0;
        final cache = SovereignSignatureCache(
          digest: VerificationCacheDigest.forLibrary(lib),
          verify:
              ({
                required algorithm,
                required nodeId,
                required publicKey,
                required message,
                required signature,
              }) {
                calls++;
                return veil.verifySovereignSignature(
                  algorithm: algorithm,
                  nodeId: nodeId,
                  publicKey: publicKey,
                  message: message,
                  signature: signature,
                );
              },
        );
        final message = Uint8List.fromList(
          'fixed native signature tuple'.codeUnits,
        );
        final signature = signer.sign(message);
        bool check({Uint8List? node, Uint8List? msg, Uint8List? sig}) =>
            cache.verify(
              algorithm: signer.algorithm,
              nodeId: node ?? signer.nodeId,
              publicKey: signer.publicKey,
              message: msg ?? message,
              signature: sig ?? signature,
            );
        expect(check(), isTrue);
        expect(check(), isTrue);
        expect(calls, 1);
        final changed = Uint8List.fromList(message)..[0] ^= 1;
        expect(check(msg: changed), isFalse);
        final wrongNode = Uint8List.fromList(signer.nodeId)..[0] ^= 1;
        expect(check(node: wrongNode), isFalse);
        final wrongSignature = Uint8List.fromList(signature)..[0] ^= 1;
        expect(check(sig: wrongSignature), isFalse);
        expect(check(), isTrue);
        expect(calls, 4);
      }
    },
    skip: path == null ? 'set VEIL_FFI_DYLIB' : false,
  );
}
