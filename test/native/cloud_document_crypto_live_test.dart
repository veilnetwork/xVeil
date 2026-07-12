import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/node/embedded_node.dart';
import 'package:xveil/domain/cloud_document.dart';
import 'package:xveil/state/cloud_document_crypto.dart';

String _hash(int byte) => List.filled(
  32,
  byte,
).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final dylib = Platform.environment['VEIL_FFI_DYLIB'];
  final skip = dylib == null || dylib.isEmpty
      ? 'set VEIL_FFI_DYLIB to libveilclient_ffi'
      : false;

  test('native signatures bind root, control and operation to node id', () {
    final lib = DynamicLibrary.open(dylib!);
    final identityToml = EmbeddedNode.mineConfig(0, lib: lib);
    final probe = EmbeddedNode.signMessage(
      identityToml,
      Uint8List.fromList([1]),
      lib: lib,
    );
    final owner = NodeId(blake3Hash(probe.publicKey));
    final unsignedRoot = CloudDocumentRoot(
      documentId: NodeId.fromHex(_hash(10)),
      owner: owner,
      ownerPubKey: Uint8List(0),
      kind: CloudDocumentKind.note,
      codec: 'xveil.note.rga.v1',
      epochKeyCommitment: _hash(40),
      epochEnvelopeHash: _hash(41),
      controlLogRoot: _hash(42),
      createdAtMs: 1000,
      signature: Uint8List(0),
    );
    final root = signCloudDocumentRoot(
      identityToml: identityToml,
      unsigned: unsignedRoot,
      lib: lib,
    );
    expect(verifyCloudDocumentRoot(root, lib: lib), isTrue);

    final control = signCloudDocumentControl(
      identityToml: identityToml,
      unsigned: CloudDocumentControlEntry(
        documentId: root.documentId,
        author: owner,
        seq: 0,
        prevControlHash: root.controlLogRoot,
        controlId: _hash(50),
        membershipEpoch: 0,
        nextEpoch: 1,
        op: CloudDocumentControlOp.rotateEpoch,
        target: null,
        role: null,
        epochKeyCommitment: _hash(60),
        epochEnvelopeHash: _hash(61),
        closedEpochFrontier: const {},
        createdAtMs: 2000,
        authorPubKey: Uint8List(0),
        signature: Uint8List(0),
      ),
      lib: lib,
    );
    expect(verifyCloudDocumentControl(control, lib: lib), isTrue);

    final operation = signCloudDocumentOperation(
      identityToml: identityToml,
      unsigned: CloudDocumentOperation(
        documentId: root.documentId,
        membershipEpoch: 1,
        author: owner,
        seq: 0,
        prevAuthorHash: '',
        operationId: _hash(70),
        parentOperationIds: const [],
        opType: 'insert',
        payloadHash: _hash(71),
        createdAtMs: 3000,
        authorPubKey: Uint8List(0),
        signature: Uint8List(0),
      ),
      lib: lib,
    );
    expect(verifyCloudDocumentOperation(operation, lib: lib), isTrue);

    final tampered = CloudDocumentOperation(
      documentId: operation.documentId,
      membershipEpoch: operation.membershipEpoch,
      author: operation.author,
      seq: operation.seq,
      prevAuthorHash: operation.prevAuthorHash,
      operationId: operation.operationId,
      parentOperationIds: operation.parentOperationIds,
      opType: operation.opType,
      payloadHash: _hash(72),
      createdAtMs: operation.createdAtMs,
      authorPubKey: operation.authorPubKey,
      signature: operation.signature,
    );
    expect(verifyCloudDocumentOperation(tampered, lib: lib), isFalse);
  }, skip: skip);
}
