import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/domain/cloud_document.dart';
import 'package:xveil/domain/cloud_document_replication.dart';
import 'package:xveil/domain/cloud_document_payload.dart';
import 'package:xveil/state/cloud_document_envelope_service.dart';
import 'package:xveil/state/cloud_document_replication_service.dart';
import 'package:xveil/state/cloud_document_store.dart';

import 'support/fake_hv_container.dart';

String _hash(int byte) => List.filled(
  32,
  byte,
).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

NodeId _id(int byte) => NodeId.fromHex(_hash(byte));
Uint8List _bytes(int byte, int count) =>
    Uint8List.fromList(List.filled(count, byte));

class _Fixture {
  _Fixture({
    required this.bundle,
    required this.owner,
    required this.editor,
    required this.envelopeService,
  });

  final CloudDocumentStoredBundle bundle;
  final NodeId owner;
  final NodeId editor;
  final CloudDocumentEnvelopeService envelopeService;
}

Future<_Fixture> _fixture() async {
  final owner = _id(1);
  final editor = _id(2);
  final documentId = _id(10);
  final envelopeService = CloudDocumentEnvelopeService(
    LoopbackMailboxCrypto(senderForOpen: owner),
  );
  final epoch0Key = _bytes(30, 32);
  final epoch0 = await envelopeService.sealEpoch(
    documentId: documentId,
    epoch: 0,
    epochKey: epoch0Key,
    recipients: [owner],
  );
  final epoch1Key = _bytes(31, 32);
  final epoch1 = await envelopeService.sealEpoch(
    documentId: documentId,
    epoch: 1,
    epochKey: epoch1Key,
    recipients: [owner, editor],
  );
  final root = CloudDocumentRoot(
    documentId: documentId,
    owner: owner,
    ownerPubKey: _bytes(1, 32),
    kind: CloudDocumentKind.note,
    codec: 'xveil.note.rga.v1',
    epochKeyCommitment: epoch0.keyCommitment,
    epochEnvelopeHash: epoch0.bundleHash,
    controlLogRoot: _hash(40),
    createdAtMs: 1000,
    signature: _bytes(1, 64),
  );
  final grant = CloudDocumentControlEntry(
    documentId: documentId,
    author: owner,
    seq: 0,
    prevControlHash: root.controlLogRoot,
    controlId: _hash(50),
    membershipEpoch: 0,
    nextEpoch: 1,
    op: CloudDocumentControlOp.grant,
    target: editor,
    role: CloudDocumentRole.editor,
    epochKeyCommitment: epoch1.keyCommitment,
    epochEnvelopeHash: epoch1.bundleHash,
    closedEpochFrontier: const {},
    createdAtMs: 1100,
    authorPubKey: _bytes(1, 32),
    signature: _bytes(1, 64),
  );
  return _Fixture(
    owner: owner,
    editor: editor,
    envelopeService: envelopeService,
    bundle: CloudDocumentStoredBundle(
      root: root,
      controls: [grant],
      operations: const [],
      envelopes: [epoch0, epoch1],
      localEpochKeys: {0: epoch0Key, 1: epoch1Key},
    ),
  );
}

CloudDocumentReplicationService _service({
  required NodeId self,
  required CloudDocumentStore store,
  required CloudDocumentEnvelopeService envelopes,
  required List<({NodeId peer, String documentId, String json})> sent,
}) => CloudDocumentReplicationService(
  localNodeId: self,
  ourCertVersion: 0,
  store: store,
  envelopes: envelopes,
  sendFrame: (peer, documentId, json) async {
    sent.add((peer: peer, documentId: documentId, json: json));
  },
  verifyRoot: (_) => true,
  verifyControl: (_) => true,
  verifyOperation: (_) => true,
  now: () => DateTime.fromMillisecondsSinceEpoch(9000),
);

Future<CloudDocumentStore> _openStore(FakeHvContainer container) async {
  final storage = container.storage();
  await storage.open(password: 'pw', createIfMissing: true);
  return CloudDocumentStore(storage);
}

Future<
  ({CloudDocumentOperation operation, CloudDocumentEncryptedPayload payload})
>
_sealedOperation({
  required CloudDocumentOperation unsigned,
  required Uint8List key,
}) async {
  final payload = await encryptCloudDocumentPayload(
    operation: unsigned,
    clearText: _bytes(unsigned.seq + 1, 12),
    epochKey: key,
  );
  return (
    operation: unsigned.withPayloadHash(payload.payloadHash),
    payload: payload,
  );
}

void main() {
  test(
    'invite is inert, survives restart, and explicit adopt opens key',
    () async {
      final fixture = await _fixture();
      final senderContainer = FakeHvContainer();
      final receiverContainer = FakeHvContainer();
      final senderStorage = senderContainer.storage();
      await senderStorage.open(password: 'pw', createIfMissing: true);
      final senderStore = CloudDocumentStore(senderStorage);
      final receiverStorage = receiverContainer.storage();
      await receiverStorage.open(password: 'pw', createIfMissing: true);
      final receiverStore = CloudDocumentStore(receiverStorage);
      final sent = <({NodeId peer, String documentId, String json})>[];
      final ownerService = _service(
        self: fixture.owner,
        store: senderStore,
        envelopes: fixture.envelopeService,
        sent: sent,
      );
      await ownerService.sendInvite(fixture.editor, fixture.bundle);
      expect(sent, hasLength(1));

      final receiver = _service(
        self: fixture.editor,
        store: receiverStore,
        envelopes: fixture.envelopeService,
        sent: sent,
      );
      expect(await receiver.ingest(fixture.owner, sent.single.json), isTrue);
      final documentId = fixture.bundle.root.documentId.hex;
      expect(await receiverStore.load(documentId), isNull);
      expect(await receiverStore.listPendingInviteIds(), [documentId]);

      await receiverStorage.close();
      final restartedStorage = receiverContainer.storage();
      await restartedStorage.open(password: 'pw');
      final restartedStore = CloudDocumentStore(restartedStorage);
      final afterRestart = _service(
        self: fixture.editor,
        store: restartedStore,
        envelopes: fixture.envelopeService,
        sent: sent,
      );
      expect((await afterRestart.pendingInvites()).single.receivedAtMs, 9000);
      expect(await afterRestart.adopt(documentId), isTrue);
      final adopted = await restartedStore.load(documentId);
      expect(adopted, isNotNull);
      expect(adopted!.localEpochKeys[1], _bytes(31, 32));
      expect(await restartedStore.listPendingInviteIds(), isEmpty);
      adopted.wipeLocalEpochKeys();
    },
  );

  test(
    'stranger, tamper and invite replay cannot materialize a document',
    () async {
      final fixture = await _fixture();
      final container = FakeHvContainer();
      final store = await _openStore(container);
      final service = _service(
        self: fixture.editor,
        store: store,
        envelopes: fixture.envelopeService,
        sent: [],
      );
      final invite = CloudDocumentFrame(
        kind: CloudDocumentFrameKind.invite,
        root: fixture.bundle.root,
        controls: fixture.bundle.controls,
        operations: const [],
        envelopes: fixture.bundle.envelopes,
      );
      expect(await service.ingest(_id(9), invite.encode()), isFalse);
      expect(await store.listPendingInviteIds(), isEmpty);

      final tampered = CloudDocumentFrame(
        kind: CloudDocumentFrameKind.invite,
        root: fixture.bundle.root,
        controls: const [],
        operations: const [],
        envelopes: fixture.bundle.envelopes,
      );
      expect(await service.ingest(fixture.owner, tampered.encode()), isFalse);
      expect(await service.ingest(fixture.owner, invite.encode()), isTrue);
      expect(await service.adopt(fixture.bundle.root.documentId.hex), isTrue);
      expect(await service.ingest(fixture.owner, invite.encode()), isFalse);
    },
  );

  test('delta converges once and a revoked editor cannot append', () async {
    final fixture = await _fixture();
    final container = FakeHvContainer();
    final store = await _openStore(container);
    final service = _service(
      self: fixture.editor,
      store: store,
      envelopes: fixture.envelopeService,
      sent: [],
    );
    final invite = CloudDocumentFrame(
      kind: CloudDocumentFrameKind.invite,
      root: fixture.bundle.root,
      controls: fixture.bundle.controls,
      operations: const [],
      envelopes: fixture.bundle.envelopes,
    );
    await service.ingest(fixture.owner, invite.encode());
    await service.adopt(fixture.bundle.root.documentId.hex);

    final sealedEdit = await _sealedOperation(
      key: _bytes(31, 32),
      unsigned: CloudDocumentOperation(
        documentId: fixture.bundle.root.documentId,
        membershipEpoch: 1,
        author: fixture.editor,
        seq: 0,
        prevAuthorHash: '',
        operationId: _hash(70),
        parentOperationIds: const [],
        opType: 'insert',
        payloadHash: _hash(0),
        createdAtMs: 2000,
        authorPubKey: _bytes(2, 32),
        signature: _bytes(2, 64),
      ),
    );
    final edit = sealedEdit.operation;
    final delta = CloudDocumentFrame(
      kind: CloudDocumentFrameKind.delta,
      root: fixture.bundle.root,
      controls: fixture.bundle.controls,
      operations: [edit],
      envelopes: fixture.bundle.envelopes,
      payloads: [sealedEdit.payload],
    );
    expect(await service.ingest(fixture.owner, delta.encode()), isTrue);
    expect(await service.ingest(fixture.owner, delta.encode()), isTrue);
    expect(
      (await store.load(fixture.bundle.root.documentId.hex))!.operations,
      hasLength(1),
    );
    expect(
      await service.decryptOperation(
        fixture.bundle.root.documentId.hex,
        edit.operationId,
      ),
      _bytes(1, 12),
    );

    final unsignedGarbage = CloudDocumentOperation(
      documentId: fixture.bundle.root.documentId,
      membershipEpoch: 1,
      author: fixture.editor,
      seq: 1,
      prevAuthorHash: edit.recordHash,
      operationId: _hash(74),
      parentOperationIds: [edit.operationId],
      opType: 'insert',
      payloadHash: _hash(0),
      createdAtMs: 2500,
      authorPubKey: _bytes(2, 32),
      signature: _bytes(2, 64),
    );
    final sealedGarbage = await _sealedOperation(
      unsigned: unsignedGarbage,
      key: _bytes(31, 32),
    );
    final corruptPayload = CloudDocumentEncryptedPayload(
      documentId: sealedGarbage.payload.documentId,
      membershipEpoch: sealedGarbage.payload.membershipEpoch,
      operationId: sealedGarbage.payload.operationId,
      nonce: sealedGarbage.payload.nonce,
      cipherText: Uint8List.fromList(sealedGarbage.payload.cipherText)
        ..[0] ^= 1,
      mac: sealedGarbage.payload.mac,
    );
    final signedGarbage = unsignedGarbage.withPayloadHash(
      corruptPayload.payloadHash,
    );
    final garbageDelta = CloudDocumentFrame(
      kind: CloudDocumentFrameKind.delta,
      root: fixture.bundle.root,
      controls: fixture.bundle.controls,
      operations: [edit, signedGarbage],
      envelopes: fixture.bundle.envelopes,
      payloads: [sealedEdit.payload, corruptPayload],
    );
    expect(await service.ingest(fixture.owner, garbageDelta.encode()), isFalse);
    expect(
      (await store.load(fixture.bundle.root.documentId.hex))!.operations,
      hasLength(1),
    );

    final epoch2Key = _bytes(32, 32);
    final epoch2 = await fixture.envelopeService.sealEpoch(
      documentId: fixture.bundle.root.documentId,
      epoch: 2,
      epochKey: epoch2Key,
      recipients: [fixture.owner],
    );
    final revoke = CloudDocumentControlEntry(
      documentId: fixture.bundle.root.documentId,
      author: fixture.owner,
      seq: 1,
      prevControlHash: fixture.bundle.controls.single.recordHash,
      controlId: _hash(51),
      membershipEpoch: 1,
      nextEpoch: 2,
      op: CloudDocumentControlOp.revoke,
      target: fixture.editor,
      role: null,
      epochKeyCommitment: epoch2.keyCommitment,
      epochEnvelopeHash: epoch2.bundleHash,
      closedEpochFrontier: {
        fixture.editor.hex: CloudDocumentAuthorHead(
          seq: 0,
          hash: edit.recordHash,
        ),
      },
      createdAtMs: 3000,
      authorPubKey: _bytes(1, 32),
      signature: _bytes(1, 64),
    );
    final revoked = CloudDocumentFrame(
      kind: CloudDocumentFrameKind.snapshot,
      root: fixture.bundle.root,
      controls: [...fixture.bundle.controls, revoke],
      operations: [edit],
      envelopes: [...fixture.bundle.envelopes, epoch2],
      payloads: [sealedEdit.payload],
    );
    expect(await service.ingest(fixture.owner, revoked.encode()), isTrue);

    final sealedIllegal = await _sealedOperation(
      key: epoch2Key,
      unsigned: CloudDocumentOperation(
        documentId: fixture.bundle.root.documentId,
        membershipEpoch: 2,
        author: fixture.editor,
        seq: 1,
        prevAuthorHash: edit.recordHash,
        operationId: _hash(72),
        parentOperationIds: [_hash(70)],
        opType: 'insert',
        payloadHash: _hash(0),
        createdAtMs: 4000,
        authorPubKey: _bytes(2, 32),
        signature: _bytes(2, 64),
      ),
    );
    final illegal = sealedIllegal.operation;
    final attack = CloudDocumentFrame(
      kind: CloudDocumentFrameKind.delta,
      root: fixture.bundle.root,
      controls: revoked.controls,
      operations: [edit, illegal],
      envelopes: revoked.envelopes,
      payloads: [sealedEdit.payload, sealedIllegal.payload],
    );
    expect(await service.ingest(fixture.editor, attack.encode()), isFalse);
    expect(
      (await store.load(fixture.bundle.root.documentId.hex))!.operations,
      hasLength(1),
    );
  });
}
