// The invite names the IDENTITY, not the device — for a hybrid master too.
//
// A contact derives the address as BLAKE3 of the key in the invite. For a
// classic identity every source agreed: the master IS the 32-byte Ed25519 key
// the node config holds. For a HYBRID identity the master is 929 bytes and no
// config source can express it — the master config holds the Ed25519 half, and
// a CREATED identity has no master config at all, so the invite fell through to
// the DEVICE's own key. Measured on one identity before this:
//
//     contact SENDS TO    e794a118…   blake3(key in the invite)
//     identity LISTENS ON d7a78850…   the document's node_id
//
// Nothing listens at the first, and nothing said so. The mailbox registration,
// the rendezvous ad and the relay choice all follow the receive address.
@Timeout(Duration(minutes: 8))
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/identity/veil_identity.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';

void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final skip = (dylib?.isNotEmpty ?? false)
      ? false
      : 'set VEIL_FFI_DYLIB to libveilclient_ffi';

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xveil-invite-');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// The two ends, for one identity: what a contact would address, and what
  /// the identity answers at.
  Future<({Uint8List sendsTo, Uint8List listensOn, int algo})> ends(
    DynamicLibrary lib, {
    required bool hybrid,
  }) async {
    final phrase = veilGeneratePhrase()!;
    // A device with a key of its OWN, which every install past the first has —
    // and the case where the old invite named the device.
    final deviceToml = EmbeddedNode.configFromPhrase(
      veilGeneratePhrase()!,
      lib: lib,
    );
    final dir = '${tmp.path}/${hybrid ? "h" : "c"}';
    await Directory(dir).create(recursive: true);
    if (hybrid) {
      final bundle = EmbeddedNode.createHybridSovereignBundle(phrase, lib: lib);
      EmbeddedNode.provisionHybridSovereignIdentity(
        bundle,
        phrase,
        veilDir: dir,
        instanceLabel: 'probe',
        nodeConfigToml: deviceToml,
        lib: lib,
      );
    } else {
      EmbeddedNode.provisionSovereignIdentity(
        phrase,
        veilDir: dir,
        instanceLabel: 'probe',
        nodeConfigToml: deviceToml,
        lib: lib,
      );
    }
    final files = await collectSovereignIdentity(dir);
    final doc = files[kIdentityDocumentFile]!;
    final master = EmbeddedNode.identityDocumentMaster(doc, lib: lib);
    return (
      // What the invite now carries, hashed the way a redeemer hashes it.
      sendsTo: blake3Hash(master.publicKey),
      listensOn: EmbeddedNode.identityDocumentNodeId(doc, lib: lib),
      algo: master.algo,
    );
  }

  test('a hybrid identity: the invite key hashes to where it listens', () async {
    final lib = DynamicLibrary.open(dylib!);
    final e = await ends(lib, hybrid: true);
    expect(e.algo, 3, reason: 'the fixture must actually be hybrid');
    expect(
      e.sendsTo,
      orderedEquals(e.listensOn),
      reason:
          'a contact derives BLAKE3 of the key in the invite; if that is not '
          'the address the identity collects mail at, the invite points at '
          'nobody',
    );
  }, skip: skip);

  test('a classic identity still agrees, the fork did not move it', () async {
    final lib = DynamicLibrary.open(dylib!);
    final e = await ends(lib, hybrid: false);
    // ZERO. Ed25519 is algo 0 in the document — the "1" this first said came
    // from an error message next door that had it wrong too.
    expect(e.algo, 0);
    expect(
      e.sendsTo,
      orderedEquals(e.listensOn),
      reason: 'classic identities agreed before and must still agree',
    );
  }, skip: skip);

  test('the master a hybrid document names is the WHOLE 929 bytes', () async {
    // The size is the reason no config source could carry it, so it is worth
    // pinning: a 32-byte answer here would mean the accessor handed back the
    // Ed25519 half and the hashes above would agree for the wrong reason.
    final lib = DynamicLibrary.open(dylib!);
    final phrase = veilGeneratePhrase()!;
    final toml = EmbeddedNode.configFromPhrase(phrase, lib: lib);
    final bundle = EmbeddedNode.createHybridSovereignBundle(phrase, lib: lib);
    final dir = '${tmp.path}/size';
    await Directory(dir).create(recursive: true);
    EmbeddedNode.provisionHybridSovereignIdentity(
      bundle,
      phrase,
      veilDir: dir,
      instanceLabel: 'probe',
      nodeConfigToml: toml,
      lib: lib,
    );
    final files = await collectSovereignIdentity(dir);
    final master = EmbeddedNode.identityDocumentMaster(
      files[kIdentityDocumentFile]!,
      lib: lib,
    );
    expect(master.publicKey, hasLength(32 + 897));
    expect(sovereignMasterAlgoName(master.algo), 'ed25519+falcon512');
  }, skip: skip);
}
