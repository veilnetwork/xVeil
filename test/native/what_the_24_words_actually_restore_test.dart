// What the twenty-four words actually bring back, measured.
//
// Asked from the field, and it is the right question: "Что делает
// восстановление по 24 словам? Всегда ли будет один и тот же node_id? Если
// нет, то как будто противоречит идее и смысла сохранять фразу нет."
//
// Reading the call chain is how this was got wrong once already
// (2026-09-14): the names all say "from seed" and one of them is not. So this
// asks the real library instead, twice, and compares.
//
// The two identities one phrase names:
//
//   CLASSIC  node_id = BLAKE3(ed25519_pk)            — from the words alone
//   HYBRID   node_id = BLAKE3(ed25519_pk ‖ falcon_pk) — needs the credential
//
// `create_hybrid512` derives the Ed25519 half from the phrase and then calls
// `falcon512::keypair()`, which takes no seed. So the hybrid address exists
// only in the credential that minted it, and the words cannot reproduce it.
@Timeout(Duration(minutes: 5))
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;
import 'package:xveil/data/identity/veil_identity.dart';
import 'package:xveil/data/node/embedded_node.dart';

void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final skip = (dylib?.isNotEmpty ?? false)
      ? false
      : 'set VEIL_FFI_DYLIB to libveilclient_ffi';

  test('the words alone give the SAME classic node id every time', () async {
    // The half that does hold. This is what makes a phrase worth writing down
    // at all, and it is not in dispute — it is measured here so the failure
    // below is read as "the other half", not as "phrases do nothing".
    final lib = DynamicLibrary.open(dylib!);
    final phrase = veilGeneratePhrase()!;
    final first = EmbeddedNode.configFromPhrase(phrase, lib: lib);
    final second = EmbeddedNode.configFromPhrase(phrase, lib: lib);
    expect(
      first,
      second,
      reason:
          'the classic identity IS the phrase; if this ever differs, writing '
          'the words down buys nothing at all',
    );
  }, skip: skip);

  test('the same phrase mints a DIFFERENT hybrid identity each time', () async {
    // The half that does not. Two credentials from one phrase, and the address
    // each one names.
    final lib = DynamicLibrary.open(dylib!);
    final phrase = veilGeneratePhrase()!;

    final a = EmbeddedNode.createHybridSovereignBundle(phrase, lib: lib);
    final b = EmbeddedNode.createHybridSovereignBundle(phrase, lib: lib);

    final idA = veil.VeilSovereignSigner.openBundle(a, phrase);
    final idB = veil.VeilSovereignSigner.openBundle(b, phrase);
    try {
      final hexA = idA.nodeId
          .map((x) => x.toRadixString(16).padLeft(2, '0'))
          .join();
      final hexB = idB.nodeId
          .map((x) => x.toRadixString(16).padLeft(2, '0'))
          .join();
      // ignore: avoid_print
      print('hybrid from one phrase: $hexA  vs  $hexB');
      expect(
        hexA,
        isNot(hexB),
        reason:
            'if these ever matched, the Falcon half would be derived from the '
            'phrase and the certificate would be unnecessary — that is the '
            'claim this test exists to keep honest',
      );
    } finally {
      idA.close();
      idB.close();
    }
  }, skip: skip);
}
