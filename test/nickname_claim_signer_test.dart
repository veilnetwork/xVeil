// Who signs a nickname claim — the decision, at the place it is decided.
//
// A name belongs to the IDENTITY, so the identity's master signs it. On most
// devices the node's own key IS that master and no secret is needed; on a
// device restored into an existing identity it is not, and the credential has
// to be unlocked.
//
// Getting this wrong is not a cosmetic prompt: the app's stored sovereign
// credential is an Ed25519+Falcon-512 HYBRID, and its node id is blake3 over
// 929 bytes while an identity named by a bare ed25519 master is blake3 over
// 32. Offering that credential for such an identity offers the WRONG key, and
// the claim refuses it — after the mining is already spent. This was written
// after doing exactly that.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/nickname_controller.dart';

Uint8List _id(int fill) => Uint8List.fromList(List<int>.filled(32, fill));

void main() {
  test('the node signs for itself when it IS the identity', () {
    // Standalone: the document's master is this device's key, so the two ids
    // are one value. No secret exists to ask for.
    expect(nodeSignsClaimItself(_id(7), _id(7)), isTrue);
  });

  test('a device that is not the master must unlock the credential', () {
    final identity = _id(7);
    final device = _id(8);
    expect(nodeSignsClaimItself(identity, device), isFalse);
  });

  test('one differing byte is enough — ids are compared whole', () {
    final identity = _id(7);
    final almost = _id(7);
    almost[31] = 8;
    expect(
      nodeSignsClaimItself(identity, almost),
      isFalse,
      reason: 'a prefix comparison would pass this and hand the claim a key '
          'that is not the identity master',
    );
    // And the first byte is not special either.
    final almostHead = _id(7);
    almostHead[0] = 8;
    expect(nodeSignsClaimItself(identity, almostHead), isFalse);
  });

  test('ids of different lengths never match', () {
    // The hybrid credential and a bare-ed25519 identity are the real pair
    // behind this: both hash to 32 bytes, but a caller that ever compares
    // unhashed keys must not get a match by truncation.
    expect(
      nodeSignsClaimItself(_id(7), Uint8List.fromList(List<int>.filled(16, 7))),
      isFalse,
    );
  });
}
