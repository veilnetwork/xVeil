import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/domain/cloud_capability.dart';
import 'package:xveil/domain/cloud_collection_crdt.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/state/cloud_capability_service.dart'
    show CloudCapabilityEndpointPort, CloudCapabilityNetworkPort;
import 'package:xveil/domain/cloud_document.dart';
import 'package:xveil/domain/cloud_document_replication.dart';
import 'package:xveil/domain/cloud_document_payload.dart';
import 'package:xveil/domain/cloud_rich_text_crdt.dart';
import 'package:xveil/state/cloud_document_envelope_service.dart';
import 'package:xveil/state/cloud_document_crypto.dart';
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

class _Signer implements CloudDocumentSigner {
  _Signer(this.selfId, this.byte);

  @override
  final NodeId selfId;
  final int byte;

  @override
  CloudDocumentRoot signRoot(CloudDocumentRoot unsigned) =>
      unsigned.withSignature(_bytes(byte, 64), _bytes(byte, 32));

  @override
  CloudDocumentControlEntry signControl(CloudDocumentControlEntry unsigned) =>
      unsigned.withSignature(_bytes(byte, 64), _bytes(byte, 32));

  @override
  CloudDocumentOperation signOperation(CloudDocumentOperation unsigned) =>
      unsigned.withSignature(_bytes(byte, 64), _bytes(byte, 32));

  @override
  CloudDocumentQuiescenceAck signQuiescenceAck(
    CloudDocumentQuiescenceAck unsigned,
  ) => unsigned.withSignature(_bytes(byte, 64), _bytes(byte, 32));
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
  CloudDocumentSigner? signer,
  CloudDocumentAcceptedContact? acceptedContact,
  Random? random,
  bool Function(CloudDocumentQuiescenceAck)? verifyQuiescenceAck,
  int automaticCompactionEntries = defaultCloudDocumentAutoCompactionEntries,
  Duration automaticQuiescenceDelay = const Duration(seconds: 2),
  DateTime Function()? now,
}) => CloudDocumentReplicationService(
  localNodeId: self,
  ourCertVersion: 0,
  store: store,
  envelopes: envelopes,
  sendFrame: (peer, documentId, json) async {
    sent.add((peer: peer, documentId: documentId, json: json));
  },
  signer: signer,
  acceptedContact: acceptedContact,
  random: random,
  verifyRoot: (_) => true,
  verifyControl: (_) => true,
  verifyOperation: (_) => true,
  verifyQuiescenceAck: verifyQuiescenceAck ?? (_) => true,
  now: now ?? () => DateTime.fromMillisecondsSinceEpoch(9000),
  automaticCompactionEntries: automaticCompactionEntries,
  automaticQuiescenceDelay: automaticQuiescenceDelay,
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
  test('quiescence frame codec is versioned, bounded and root-bound', () async {
    final fixture = await _fixture();
    final ack = CloudDocumentQuiescenceAck(
      documentId: fixture.bundle.root.documentId,
      rootHash: fixture.bundle.root.recordHash,
      generation: fixture.bundle.root.generation,
      stateHash: _hash(91),
      roundId: _hash(92),
      author: fixture.editor,
      issuedAtMs: 9000,
      authorPubKey: _bytes(2, 32),
      signature: _bytes(2, 64),
    );
    final frame = CloudDocumentFrame(
      kind: CloudDocumentFrameKind.quiescenceAck,
      root: fixture.bundle.root,
      controls: const [],
      operations: const [],
      envelopes: const [],
      quiescenceAck: ack,
      quiescenceId: _hash(92),
    );
    final decoded = CloudDocumentFrame.decode(frame.encode())!;
    expect(decoded.kind, CloudDocumentFrameKind.quiescenceAck);
    expect(decoded.quiescenceAck!.stateHash, _hash(91));
    expect(decoded.quiescenceAck!.canonicalBytes(), ack.canonicalBytes());

    final badState = Map<String, dynamic>.from(frame.toJson());
    badState['ack'] = Map<String, dynamic>.from(badState['ack'] as Map)
      ..['state'] = '00';
    expect(CloudDocumentFrame.fromJson(badState), isNull);
    final wrongVersionKind = Map<String, dynamic>.from(frame.toJson())
      ..['kind'] = CloudDocumentFrameKind.snapshot.name
      ..remove('ack');
    expect(CloudDocumentFrame.fromJson(wrongVersionKind), isNull);
    final proposalWithAck = Map<String, dynamic>.from(frame.toJson())
      ..['kind'] = CloudDocumentFrameKind.quiescence.name;
    expect(CloudDocumentFrame.fromJson(proposalWithAck), isNull);
    fixture.bundle.wipeLocalEpochKeys();
  });

  test(
    'owner creates, invites, rotates roles and revokes with closed frontier',
    () async {
      final owner = _id(1);
      final editor = _id(2);
      final stranger = _id(9);
      final envelopeService = CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      );
      final ownerStore = await _openStore(FakeHvContainer());
      final receiverStore = await _openStore(FakeHvContainer());
      final sent = <({NodeId peer, String documentId, String json})>[];
      final ownerService = _service(
        self: owner,
        store: ownerStore,
        envelopes: envelopeService,
        sent: sent,
        signer: _Signer(owner, 1),
        acceptedContact: (peer) async => peer == editor,
        random: Random(41),
      );
      final receiver = _service(
        self: editor,
        store: receiverStore,
        envelopes: envelopeService,
        sent: sent,
      );

      final created = await ownerService.createDocument();
      expect(created, isNotNull);
      final documentId = created!.documentId;
      expect((await ownerService.listDocuments()).single.currentEpoch, 0);
      expect(
        await ownerService.grant(
          documentId,
          stranger,
          CloudDocumentRole.editor,
        ),
        isNull,
        reason: 'only an accepted contact can be granted from this surface',
      );

      final granted = await ownerService.grant(
        documentId,
        editor,
        CloudDocumentRole.editor,
      );
      expect(granted, isNotNull);
      expect(granted!.fullyQueued, isTrue);
      expect(sent, hasLength(1));
      var frame = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(frame.kind, CloudDocumentFrameKind.invite);
      expect(await receiver.ingest(owner, frame.encode()), isTrue);
      expect(await receiver.adopt(documentId), isTrue);
      expect(
        (await receiver.listDocuments()).single.localRole,
        CloudDocumentRole.editor,
      );

      // Plant one valid editor operation so the next ACL mutation must close
      // the old epoch with its exact signed author frontier.
      final ownerBundle = (await ownerStore.load(documentId))!;
      try {
        final unsigned = CloudDocumentOperation(
          documentId: ownerBundle.root.documentId,
          membershipEpoch: 1,
          author: editor,
          seq: 0,
          prevAuthorHash: '',
          operationId: _hash(70),
          parentOperationIds: const [],
          opType: 'text.insert',
          payloadHash: _hash(0),
          createdAtMs: 2000,
          authorPubKey: _bytes(2, 32),
          signature: _bytes(2, 64),
        );
        final sealed = await _sealedOperation(
          unsigned: unsigned,
          key: ownerBundle.localEpochKeys[1]!,
        );
        await ownerStore.save(
          CloudDocumentStoredBundle(
            root: ownerBundle.root,
            controls: ownerBundle.controls,
            operations: [...ownerBundle.operations, sealed.operation],
            envelopes: ownerBundle.envelopes,
            localEpochKeys: ownerBundle.localEpochKeys,
            payloads: [...ownerBundle.payloads, sealed.payload],
          ),
        );
      } finally {
        ownerBundle.wipeLocalEpochKeys();
      }

      final roleChanged = await ownerService.setRole(
        documentId,
        editor,
        CloudDocumentRole.viewer,
      );
      expect(roleChanged?.fullyQueued, isTrue);
      frame = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(frame.kind, CloudDocumentFrameKind.snapshot);
      expect(
        frame.controls.last.closedEpochFrontier[editor.hex]?.hash,
        frame.operations
            .singleWhere((operation) => operation.author == editor)
            .recordHash,
      );
      expect(await receiver.ingest(owner, frame.encode()), isTrue);
      var view = (await receiver.listDocuments()).single;
      expect(view.currentEpoch, 2);
      expect(view.localRole, CloudDocumentRole.viewer);
      expect(
        await ownerService.setRole(
          documentId,
          editor,
          CloudDocumentRole.viewer,
        ),
        isNull,
        reason: 'a no-op role change must not rotate the epoch',
      );

      final rotated = await ownerService.rotateEpoch(documentId);
      expect(rotated?.fullyQueued, isTrue);
      frame = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(await receiver.ingest(owner, frame.encode()), isTrue);
      expect((await receiver.listDocuments()).single.currentEpoch, 3);

      final revoked = await ownerService.revoke(documentId, editor);
      expect(revoked?.fullyQueued, isTrue);
      frame = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(await receiver.ingest(owner, frame.encode()), isTrue);
      view = (await receiver.listDocuments()).single;
      expect(view.currentEpoch, 4);
      expect(view.localRole, isNull);
      expect(view.members.keys, [owner.hex]);

      final finalOwner = (await ownerStore.load(documentId))!;
      expect(finalOwner.localEpochKeys.keys, [0, 1, 2, 3, 4]);
      expect(
        finalOwner.envelopes.last.envelopeFor(editor),
        isNull,
        reason: 'the revoked peer must not receive the next epoch key',
      );
      finalOwner.wipeLocalEpochKeys();
    },
  );

  test('ACL persists locally when durable fanout cannot be queued', () async {
    final owner = _id(1);
    final editor = _id(2);
    final store = await _openStore(FakeHvContainer());
    final service = CloudDocumentReplicationService(
      localNodeId: owner,
      ourCertVersion: 0,
      store: store,
      envelopes: CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
      sendFrame: (_, _, _) async => throw StateError('offline'),
      signer: _Signer(owner, 1),
      acceptedContact: (_) async => true,
      verifyRoot: (_) => true,
      verifyControl: (_) => true,
      verifyOperation: (_) => true,
      random: Random(42),
    );
    final created = await service.createDocument();
    final result = await service.grant(
      created!.documentId,
      editor,
      CloudDocumentRole.editor,
    );
    expect(result, isNotNull);
    expect(result!.failedRecipients, [editor]);
    final view = (await service.listDocuments()).single;
    expect(view.currentEpoch, 1);
    expect(view.members[editor.hex], CloudDocumentRole.editor);
  });

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

  test(
    'rich text checkpoint grants current state and delete preserves unseen edit',
    () async {
      final owner = _id(1);
      final editor = _id(2);
      final envelopes = CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      );
      final ownerStore = await _openStore(FakeHvContainer());
      final editorStore = await _openStore(FakeHvContainer());
      final sent = <({NodeId peer, String documentId, String json})>[];
      final ownerService = _service(
        self: owner,
        store: ownerStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(owner, 1),
        random: Random(91),
      );
      final editorService = _service(
        self: editor,
        store: editorStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(editor, 2),
        random: Random(92),
      );

      final documentId = (await ownerService.createDocument())!.documentId;
      var ownerState = (await ownerService.loadRichText(documentId))!;
      expect(ownerState.snapshot.text, isEmpty);
      expect(
        await ownerService.saveRichText(
          documentId,
          base: ownerState.snapshot,
          text: 'Hello world',
          styles: List.filled(11, const CloudRichTextStyle()),
        ),
        isNotNull,
      );
      ownerState = (await ownerService.loadRichText(documentId))!;
      expect(ownerState.snapshot.text, 'Hello world');
      expect(
        await ownerService.saveRichText(
          documentId,
          base: ownerState.snapshot,
          text: 'Hello veil',
          styles: List.filled(10, const CloudRichTextStyle(bold: true)),
        ),
        isNotNull,
      );
      ownerState = (await ownerService.loadRichText(documentId))!;
      expect(ownerState.snapshot.text, 'Hello veil');

      expect(
        await ownerService.grant(documentId, editor, CloudDocumentRole.editor),
        isNotNull,
      );
      final invite = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(await editorService.ingest(owner, invite.encode()), isTrue);
      expect(await editorService.adopt(documentId), isTrue);
      var editorState = (await editorService.loadRichText(documentId))!;
      expect(editorState.snapshot.text, 'Hello veil');
      expect(editorState.snapshot.unavailableOperationIds, isNotEmpty);
      expect(editorState.snapshot.invalidOperationIds, isEmpty);
      ownerState = (await ownerService.loadRichText(documentId))!;

      sent.clear();
      expect(
        await ownerService.deleteRichTextDocument(
          documentId,
          parentOperationIds: ownerState.snapshot.headOperationIds,
        ),
        isNotNull,
      );
      final deleteFrame = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(
        await editorService.saveRichText(
          documentId,
          base: editorState.snapshot,
          text: 'Hello veil remote',
          styles: List.filled(17, const CloudRichTextStyle(italic: true)),
        ),
        isNotNull,
      );
      final editFrame = CloudDocumentFrame.decode(sent.removeLast().json)!;

      expect(await ownerService.ingest(editor, editFrame.encode()), isTrue);
      expect(await editorService.ingest(owner, deleteFrame.encode()), isTrue);
      ownerState = (await ownerService.loadRichText(documentId))!;
      editorState = (await editorService.loadRichText(documentId))!;
      expect(ownerState.snapshot.text, ' remote');
      expect(editorState.snapshot.text, ownerState.snapshot.text);
      expect(ownerState.snapshot.hasConcurrentRecovery, isTrue);
      expect(editorState.snapshot.hasConcurrentRecovery, isTrue);
      expect(
        ownerState.snapshot.atoms.every((atom) => atom.style.italic),
        isTrue,
      );

      sent.clear();
      final compacted = await ownerService.compactDocument(documentId);
      expect(compacted, isNotNull);
      expect(
        compacted!.operationsAfter,
        2,
        reason: 'checkpoint + concurrent document-delete marker',
      );
      final compactFrame = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(await editorService.ingest(owner, compactFrame.encode()), isTrue);
      ownerState = (await ownerService.loadRichText(documentId))!;
      editorState = (await editorService.loadRichText(documentId))!;
      expect(ownerState.snapshot.text, ' remote');
      expect(ownerState.snapshot.hasConcurrentRecovery, isTrue);
      expect(editorState.snapshot.text, ownerState.snapshot.text);
      expect(editorState.snapshot.hasConcurrentRecovery, isTrue);

      sent.clear();
      expect(
        await ownerService.setRole(
          documentId,
          editor,
          CloudDocumentRole.viewer,
        ),
        isNotNull,
      );
      final viewerFrame = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(await editorService.ingest(owner, viewerFrame.encode()), isTrue);
      editorState = (await editorService.loadRichText(documentId))!;
      expect(editorState.canEdit, isFalse);
      expect(
        await editorService.saveRichText(
          documentId,
          base: editorState.snapshot,
          text: 'forbidden',
          styles: List.filled(9, const CloudRichTextStyle()),
        ),
        isNull,
      );
    },
  );

  test(
    'task document checkpoints on grant and concurrent fields converge',
    () async {
      final owner = _id(1);
      final editor = _id(2);
      final envelopes = CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      );
      final ownerStore = await _openStore(FakeHvContainer());
      final editorStore = await _openStore(FakeHvContainer());
      final sent = <({NodeId peer, String documentId, String json})>[];
      final ownerService = _service(
        self: owner,
        store: ownerStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(owner, 1),
        random: Random(101),
      );
      final editorService = _service(
        self: editor,
        store: editorStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(editor, 2),
        random: Random(102),
      );

      expect(
        await ownerService.createDocument(
          kind: CloudDocumentKind.calendar,
          codec: cloudTaskListCodecV1,
        ),
        isNull,
        reason: 'kind and codec must be an exact protocol pair',
      );
      final documentId = (await ownerService.createDocument(
        kind: CloudDocumentKind.taskList,
        codec: cloudTaskListCodecV1,
      ))!.documentId;
      final taskId = _hash(77);
      var ownerState = (await ownerService.loadCollection(documentId))!;
      expect(ownerState.tasks, isEmpty);
      expect(
        await ownerService.appendCollectionEdits(documentId, [
          CloudCollectionEdit.create(
            taskId,
            CloudTask(
              id: taskId,
              title: 'Initial',
              notes: '',
              completed: false,
              position: 0,
            ).toFields(),
          ),
        ], parentOperationIds: ownerState.snapshot.headOperationIds),
        isNotNull,
      );
      ownerState = (await ownerService.loadCollection(documentId))!;
      expect(ownerState.tasks.single.title, 'Initial');

      sent.clear();
      expect(
        await ownerService.grant(documentId, editor, CloudDocumentRole.editor),
        isNotNull,
      );
      final invite = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(await editorService.ingest(owner, invite.encode()), isTrue);
      expect(await editorService.adopt(documentId), isTrue);
      var editorState = (await editorService.loadCollection(documentId))!;
      expect(editorState.tasks.single.title, 'Initial');
      expect(editorState.snapshot.unavailableOperationIds, isNotEmpty);
      expect(editorState.snapshot.invalidOperationIds, isEmpty);
      ownerState = (await ownerService.loadCollection(documentId))!;
      expect(
        editorState.snapshot.headOperationIds,
        ownerState.snapshot.headOperationIds,
      );

      sent.clear();
      expect(
        await ownerService.appendCollectionEdits(documentId, [
          CloudCollectionEdit.patch(taskId, {'title': 'Owner rename'}),
        ], parentOperationIds: ownerState.snapshot.headOperationIds),
        isNotNull,
      );
      final ownerFrame = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(
        await editorService.appendCollectionEdits(documentId, [
          CloudCollectionEdit.patch(taskId, {'completed': true}),
        ], parentOperationIds: editorState.snapshot.headOperationIds),
        isNotNull,
      );
      final editorFrame = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(await ownerService.ingest(editor, editorFrame.encode()), isTrue);
      expect(await editorService.ingest(owner, ownerFrame.encode()), isTrue);

      ownerState = (await ownerService.loadCollection(documentId))!;
      editorState = (await editorService.loadCollection(documentId))!;
      expect(ownerState.tasks.single.title, 'Owner rename');
      expect(ownerState.tasks.single.completed, isTrue);
      expect(editorState.tasks.single.title, ownerState.tasks.single.title);
      expect(editorState.tasks.single.completed, isTrue);
      expect(
        editorState.snapshot.headOperationIds,
        ownerState.snapshot.headOperationIds,
      );
    },
  );

  test(
    'automatic quiescence ACK compacts only an exact frozen editor state',
    () async {
      final owner = _id(1);
      final editor = _id(2);
      final envelopes = CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      );
      final ownerStore = await _openStore(FakeHvContainer());
      final editorStore = await _openStore(FakeHvContainer());
      final sent = <({NodeId peer, String documentId, String json})>[];
      final ownerService = _service(
        self: owner,
        store: ownerStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(owner, 1),
        random: Random(181),
        automaticCompactionEntries: 3,
        automaticQuiescenceDelay: Duration.zero,
      );
      var editorService = _service(
        self: editor,
        store: editorStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(editor, 2),
        random: Random(182),
      );

      final id = (await ownerService.createDocument())!.documentId;
      await ownerService.grant(id, editor, CloudDocumentRole.editor);
      final invite = sent
          .map((entry) => CloudDocumentFrame.decode(entry.json))
          .whereType<CloudDocumentFrame>()
          .firstWhere((frame) => frame.kind == CloudDocumentFrameKind.invite);
      expect(await editorService.ingest(owner, invite.encode()), isTrue);
      expect(await editorService.adopt(id), isTrue);

      sent.clear();
      final base = (await ownerService.loadRichText(id))!;
      expect(
        await ownerService.saveRichText(
          id,
          base: base.snapshot,
          text: 'automatic cut',
          styles: List.filled(13, const CloudRichTextStyle(bold: true)),
        ),
        isNotNull,
      );
      for (var attempt = 0; attempt < 20; attempt++) {
        await Future<void>.delayed(Duration.zero);
        if (sent.any(
          (entry) =>
              CloudDocumentFrame.decode(entry.json)?.kind ==
              CloudDocumentFrameKind.quiescence,
        )) {
          break;
        }
      }
      final delta = sent.firstWhere(
        (entry) =>
            CloudDocumentFrame.decode(entry.json)?.kind ==
            CloudDocumentFrameKind.delta,
      );
      final proposal = sent.firstWhere(
        (entry) =>
            CloudDocumentFrame.decode(entry.json)?.kind ==
            CloudDocumentFrameKind.quiescence,
      );
      expect(await editorService.ingest(owner, delta.json), isTrue);
      sent.clear();
      expect(await editorService.ingest(owner, proposal.json), isTrue);
      final ack = sent.singleWhere(
        (entry) =>
            CloudDocumentFrame.decode(entry.json)?.kind ==
            CloudDocumentFrameKind.quiescenceAck,
      );
      final frozen = (await editorService.loadRichText(id))!;
      expect(
        await editorService.saveRichText(
          id,
          base: frozen.snapshot,
          text: 'must wait',
          styles: List.filled(9, const CloudRichTextStyle()),
        ),
        isNull,
        reason: 'an ACK is a short write-freeze, not a racy observation',
      );
      await editorService.close();
      editorService = _service(
        self: editor,
        store: editorStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(editor, 2),
        random: Random(186),
      );
      final afterRestart = (await editorService.loadRichText(id))!;
      expect(
        await editorService.saveRichText(
          id,
          base: afterRestart.snapshot,
          text: 'restart must still wait',
          styles: List.filled(23, const CloudRichTextStyle()),
        ),
        isNull,
        reason: 'the prepare marker must survive an application restart',
      );

      sent.clear();
      expect(await ownerService.ingest(editor, ack.json), isTrue);
      CloudDocumentFrame? transition;
      for (var attempt = 0; attempt < 50; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        for (final entry in sent) {
          final frame = CloudDocumentFrame.decode(entry.json);
          if (frame != null && frame.root.generation == 1) transition = frame;
        }
        if (transition != null) break;
      }
      expect(transition, isNotNull);
      expect((await ownerStore.load(id))!.root.generation, 1);
      expect(await editorService.ingest(owner, transition!.encode()), isTrue);
      final after = (await editorService.loadRichText(id))!;
      expect(after.snapshot.text, 'automatic cut');
      expect(
        await editorService.saveRichText(
          id,
          base: after.snapshot,
          text: 'automatic cut!',
          styles: [
            ...after.snapshot.atoms.map((atom) => atom.style),
            const CloudRichTextStyle(underline: true),
          ],
        ),
        isNotNull,
        reason: 'the accepted root transition releases the writer',
      );
      await ownerService.close();
      await editorService.close();
    },
  );

  test(
    'quiescence returns an offline branch and rejects a stale ACK',
    () async {
      var ownerNowMs = 9000;
      final owner = _id(1);
      final editor = _id(2);
      final envelopes = CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      );
      final ownerStore = await _openStore(FakeHvContainer());
      final editorStore = await _openStore(FakeHvContainer());
      final sent = <({NodeId peer, String documentId, String json})>[];
      final ownerService = _service(
        self: owner,
        store: ownerStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(owner, 1),
        random: Random(183),
        now: () => DateTime.fromMillisecondsSinceEpoch(ownerNowMs),
      );
      final editorService = _service(
        self: editor,
        store: editorStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(editor, 2),
        random: Random(184),
      );
      final id = (await ownerService.createDocument())!.documentId;
      await ownerService.grant(id, editor, CloudDocumentRole.editor);
      final invite = sent
          .map((entry) => CloudDocumentFrame.decode(entry.json))
          .whereType<CloudDocumentFrame>()
          .firstWhere((frame) => frame.kind == CloudDocumentFrameKind.invite);
      expect(await editorService.ingest(owner, invite.encode()), isTrue);
      expect(await editorService.adopt(id), isTrue);

      sent.clear();
      final editorState = (await editorService.loadRichText(id))!;
      await editorService.saveRichText(
        id,
        base: editorState.snapshot,
        text: 'offline branch',
        styles: List.filled(14, const CloudRichTextStyle()),
      );
      final offlineDelta = sent.single;
      sent.clear();
      expect(
        await ownerService.requestQuiescence(id, ignoreThreshold: true),
        isTrue,
      );
      final staleProposal = sent.single;
      sent.clear();
      expect(await editorService.ingest(owner, staleProposal.json), isTrue);
      expect(
        sent.any(
          (entry) =>
              CloudDocumentFrame.decode(entry.json)?.kind ==
              CloudDocumentFrameKind.quiescenceAck,
        ),
        isFalse,
      );
      final returnedDelta = sent.singleWhere(
        (entry) =>
            CloudDocumentFrame.decode(entry.json)?.kind ==
            CloudDocumentFrameKind.delta,
      );
      expect(await ownerService.ingest(editor, returnedDelta.json), isTrue);
      expect(
        (await ownerService.loadRichText(id))!.snapshot.text,
        'offline branch',
      );

      sent.clear();
      expect(
        await ownerService.requestQuiescence(id, ignoreThreshold: true),
        isTrue,
      );
      final exactProposal = sent.single;
      sent.clear();
      expect(await editorService.ingest(owner, exactProposal.json), isTrue);
      final oldAck = sent.single;

      ownerNowMs += const Duration(minutes: 3).inMilliseconds;
      sent.clear();
      expect(
        await ownerService.requestQuiescence(id, ignoreThreshold: true),
        isTrue,
      );
      final renewedProposal = CloudDocumentFrame.decode(sent.single.json)!;
      final oldAckFrame = CloudDocumentFrame.decode(oldAck.json)!;
      expect(
        renewedProposal.quiescenceId,
        isNot(oldAckFrame.quiescenceId),
        reason: 'an expired round must receive a fresh random challenge',
      );
      expect(await ownerService.ingest(editor, oldAck.json), isFalse);

      final ownerState = (await ownerService.loadRichText(id))!;
      await ownerService.saveRichText(
        id,
        base: ownerState.snapshot,
        text: 'offline branch changed',
        styles: List.filled(22, const CloudRichTextStyle()),
      );
      expect(await ownerService.ingest(editor, oldAck.json), isFalse);
      expect((await ownerStore.load(id))!.root.generation, 0);
      expect(
        await ownerService.ingest(_id(9), oldAck.json),
        isFalse,
        reason: 'a copied member ACK cannot be replayed by another peer',
      );
      // The original offline packet is equivalent to the returned delta and
      // remains a harmless deduplicated replay.
      expect(await ownerService.ingest(editor, offlineDelta.json), isTrue);
      await ownerService.close();
      await editorService.close();
    },
  );

  test(
    'owner ingests member ACK while durable proposal send is still pending',
    () async {
      final owner = _id(1);
      final editor = _id(2);
      final envelopes = CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      );
      final ownerStore = await _openStore(FakeHvContainer());
      final editorStore = await _openStore(FakeHvContainer());
      final sent = <({NodeId peer, String documentId, String json})>[];
      var blockOwnerSend = false;
      var sendGate = Completer<void>();
      final ownerService = CloudDocumentReplicationService(
        localNodeId: owner,
        ourCertVersion: 0,
        store: ownerStore,
        envelopes: envelopes,
        sendFrame: (peer, documentId, json) async {
          sent.add((peer: peer, documentId: documentId, json: json));
          if (blockOwnerSend) await sendGate.future;
        },
        signer: _Signer(owner, 1),
        verifyRoot: (_) => true,
        verifyControl: (_) => true,
        verifyOperation: (_) => true,
        verifyQuiescenceAck: (_) => true,
        now: () => DateTime.fromMillisecondsSinceEpoch(9000),
        random: Random(187),
      );
      final editorService = _service(
        self: editor,
        store: editorStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(editor, 2),
        random: Random(188),
      );
      final id = (await ownerService.createDocument())!.documentId;
      await ownerService.grant(id, editor, CloudDocumentRole.editor);
      final invite = sent
          .map((entry) => CloudDocumentFrame.decode(entry.json))
          .whereType<CloudDocumentFrame>()
          .firstWhere((frame) => frame.kind == CloudDocumentFrameKind.invite);
      expect(await editorService.ingest(owner, invite.encode()), isTrue);
      expect(await editorService.adopt(id), isTrue);

      sent.clear();
      blockOwnerSend = true;
      final request = ownerService.requestQuiescence(id, ignoreThreshold: true);
      for (var attempt = 0; attempt < 20 && sent.isEmpty; attempt++) {
        await Future<void>.delayed(Duration.zero);
      }
      final proposal = sent.single;
      sent.clear();
      expect(await editorService.ingest(owner, proposal.json), isTrue);
      final ack = sent.single;
      expect(
        await ownerService
            .ingest(editor, ack.json)
            .timeout(const Duration(seconds: 1)),
        isTrue,
        reason: 'network await must not retain the document serialization lock',
      );
      sendGate.complete();
      expect(await request, isTrue);
      for (var attempt = 0; attempt < 50; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        final stored = await ownerStore.load(id);
        final generation = stored?.root.generation;
        stored?.wipeLocalEpochKeys();
        if (generation == 1) break;
      }
      final compacted = (await ownerStore.load(id))!;
      expect(compacted.root.generation, 1);
      compacted.wipeLocalEpochKeys();
      blockOwnerSend = false;
      await ownerService.close();
      await editorService.close();
    },
  );

  test(
    'offline editor blocks automatic compaction until owner revokes it',
    () async {
      final owner = _id(1);
      final editor = _id(2);
      final envelopes = CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      );
      final store = await _openStore(FakeHvContainer());
      final sent = <({NodeId peer, String documentId, String json})>[];
      final service = _service(
        self: owner,
        store: store,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(owner, 1),
        random: Random(185),
      );
      final id = (await service.createDocument())!.documentId;
      await service.grant(id, editor, CloudDocumentRole.editor);
      sent.clear();
      expect(
        await service.requestQuiescence(id, ignoreThreshold: true),
        isTrue,
      );
      expect(service.quiescenceStatus(id)!.complete, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect((await store.load(id))!.root.generation, 0);

      expect(await service.revoke(id, editor), isNotNull);
      sent.clear();
      expect(
        await service.requestQuiescence(id, ignoreThreshold: true),
        isTrue,
      );
      for (var attempt = 0; attempt < 50; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        final stored = await store.load(id);
        final generation = stored?.root.generation;
        stored?.wipeLocalEpochKeys();
        if (generation == 1) break;
      }
      final compacted = (await store.load(id))!;
      expect(compacted.root.generation, 1);
      compacted.wipeLocalEpochKeys();
      await service.close();
    },
  );

  test(
    'signed root compaction shrinks history, converges and rejects replay',
    () async {
      final owner = _id(1);
      final editor = _id(2);
      final envelopes = CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      );
      final ownerContainer = FakeHvContainer();
      final editorContainer = FakeHvContainer();
      final ownerStore = await _openStore(ownerContainer);
      final editorStore = await _openStore(editorContainer);
      final sent = <({NodeId peer, String documentId, String json})>[];
      final ownerService = _service(
        self: owner,
        store: ownerStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(owner, 1),
        random: Random(201),
      );
      final editorService = _service(
        self: editor,
        store: editorStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(editor, 2),
        random: Random(202),
      );

      final documentId = (await ownerService.createDocument())!.documentId;
      var ownerState = (await ownerService.loadRichText(documentId))!;
      await ownerService.saveRichText(
        documentId,
        base: ownerState.snapshot,
        text: 'before compaction',
        styles: List.filled(17, const CloudRichTextStyle(bold: true)),
      );
      await ownerService.grant(documentId, editor, CloudDocumentRole.editor);
      final invite = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(await editorService.ingest(owner, invite.encode()), isTrue);
      expect(await editorService.adopt(documentId), isTrue);
      var editorState = (await editorService.loadRichText(documentId))!;
      await editorService.saveRichText(
        documentId,
        base: editorState.snapshot,
        text: 'before compaction plus editor',
        styles: List.filled(29, const CloudRichTextStyle(italic: true)),
      );
      final editorDelta = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(await ownerService.ingest(editor, editorDelta.encode()), isTrue);
      ownerState = (await ownerService.loadRichText(documentId))!;
      expect(ownerState.snapshot.text, 'before compaction plus editor');

      final oldStored = (await ownerStore.load(documentId))!;
      final oldFrame = CloudDocumentFrame(
        kind: CloudDocumentFrameKind.snapshot,
        root: oldStored.root,
        controls: oldStored.controls,
        operations: oldStored.operations,
        envelopes: oldStored.envelopes,
        payloads: oldStored.payloads,
      );
      expect(oldStored.operations.length, greaterThan(1));
      expect(oldStored.controls, isNotEmpty);
      expect(oldStored.envelopes.length, greaterThan(1));
      oldStored.wipeLocalEpochKeys();

      sent.clear();
      final compacted = await ownerService.compactDocument(documentId);
      expect(compacted, isNotNull);
      expect(compacted!.generation, 1);
      expect(compacted.controlsBefore, greaterThan(0));
      expect(compacted.operationsBefore, greaterThan(1));
      expect(compacted.operationsAfter, 1);
      expect(sent, hasLength(1));
      final compactFrame = CloudDocumentFrame.decode(sent.single.json)!;
      expect(compactFrame.root.version, 2);
      expect(compactFrame.root.generation, 1);
      expect(compactFrame.controls, isEmpty);
      expect(compactFrame.operations, hasLength(1));
      expect(compactFrame.envelopes, hasLength(1));
      expect(await editorService.ingest(owner, compactFrame.encode()), isTrue);
      ownerState = (await ownerService.loadRichText(documentId))!;
      editorState = (await editorService.loadRichText(documentId))!;
      expect(editorState.snapshot.text, ownerState.snapshot.text);
      expect(
        editorState.snapshot.atoms.every((atom) => atom.style.italic),
        isTrue,
      );

      expect(
        await editorService.ingest(owner, oldFrame.encode()),
        isFalse,
        reason: 'a pre-compaction root must never downgrade local state',
      );
      final forkRootJson = Map<String, dynamic>.from(compactFrame.root.toJson())
        ..['gen'] = 2
        ..['prevRoot'] = _hash(99);
      final fork = CloudDocumentFrame(
        kind: CloudDocumentFrameKind.snapshot,
        root: CloudDocumentRoot.fromJson(forkRootJson)!,
        controls: compactFrame.controls,
        operations: compactFrame.operations,
        envelopes: compactFrame.envelopes,
        payloads: compactFrame.payloads,
      );
      expect(await editorService.ingest(owner, fork.encode()), isFalse);

      sent.clear();
      editorState = (await editorService.loadRichText(documentId))!;
      expect(
        await editorService.saveRichText(
          documentId,
          base: editorState.snapshot,
          text: '${editorState.snapshot.text}!',
          styles: [
            ...editorState.snapshot.atoms.map((atom) => atom.style),
            const CloudRichTextStyle(underline: true),
          ],
        ),
        isNotNull,
      );
      final postCompactDelta = CloudDocumentFrame.decode(
        sent.removeLast().json,
      )!;
      expect(
        await ownerService.ingest(editor, postCompactDelta.encode()),
        isTrue,
      );
      expect(
        (await ownerService.loadRichText(documentId))!.snapshot.text,
        'before compaction plus editor!',
      );

      sent.clear();
      expect(
        await ownerService.setRole(
          documentId,
          editor,
          CloudDocumentRole.viewer,
        ),
        isNotNull,
      );
      final aclFrame = CloudDocumentFrame.decode(sent.single.json)!;
      expect(aclFrame.controls.single.seq, 1);
      expect(
        aclFrame.controls.single.prevControlHash,
        aclFrame.root.baseControlHash,
      );
      expect(await editorService.ingest(owner, aclFrame.encode()), isTrue);
      expect(
        (await editorService.loadRichText(documentId))!.localRole,
        CloudDocumentRole.viewer,
      );

      final restartedOwner = _service(
        self: owner,
        store: ownerStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(owner, 1),
      );
      expect(
        (await restartedOwner.loadRichText(documentId))!.snapshot.text,
        'before compaction plus editor!',
      );
    },
  );

  test('task and calendar compaction preserve typed rows', () async {
    for (final kind in [
      CloudDocumentKind.taskList,
      CloudDocumentKind.calendar,
    ]) {
      final owner = _id(kind == CloudDocumentKind.taskList ? 3 : 4);
      final store = await _openStore(FakeHvContainer());
      final service = _service(
        self: owner,
        store: store,
        envelopes: CloudDocumentEnvelopeService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        sent: [],
        signer: _Signer(owner, owner.bytes.first),
        random: Random(kind.index + 300),
      );
      final documentId = (await service.createDocument(
        kind: kind,
        codec: cloudCollectionCodec(kind)!,
      ))!.documentId;
      final entityId = _hash(kind.index + 80);
      final state = (await service.loadCollection(documentId))!;
      final fields = kind == CloudDocumentKind.taskList
          ? CloudTask(
              id: entityId,
              title: 'Task',
              notes: 'kept',
              completed: true,
              position: 7,
            ).toFields()
          : CloudCalendarEvent(
              id: entityId,
              title: 'Event',
              notes: 'kept',
              startAtMs: 100,
              endAtMs: 200,
              allDay: false,
              location: 'Here',
            ).toFields();
      await service.appendCollectionEdits(documentId, [
        CloudCollectionEdit.create(entityId, fields),
        CloudCollectionEdit.patch(entityId, {'notes': 'preserved'}),
      ], parentOperationIds: state.snapshot.headOperationIds);
      final result = await service.compactDocument(documentId);
      expect(result, isNotNull);
      expect(result!.operationsAfter, 1);
      final after = (await service.loadCollection(documentId))!;
      expect(after.snapshot.rows.single.id, entityId);
      expect(after.snapshot.rows.single.fields['notes'], 'preserved');
      final stored = (await store.load(documentId))!;
      expect(stored.root.generation, 1);
      expect(stored.controls, isEmpty);
      expect(stored.operations, hasLength(1));
      expect(stored.envelopes, hasLength(1));
      stored.wipeLocalEpochKeys();
      expect(await service.compactDocument(documentId), isNotNull);
      final twice = (await store.load(documentId))!;
      expect(twice.root.generation, 2);
      expect(twice.operations, hasLength(1));
      twice.wipeLocalEpochKeys();
    }
  });

  test('replica with an unsynchronized edit rejects compaction cut', () async {
    final owner = _id(1);
    final editor = _id(2);
    final envelopes = CloudDocumentEnvelopeService(
      LoopbackMailboxCrypto(senderForOpen: owner),
    );
    final sent = <({NodeId peer, String documentId, String json})>[];
    final ownerService = _service(
      self: owner,
      store: await _openStore(FakeHvContainer()),
      envelopes: envelopes,
      sent: sent,
      signer: _Signer(owner, 1),
      random: Random(401),
    );
    final editorService = _service(
      self: editor,
      store: await _openStore(FakeHvContainer()),
      envelopes: envelopes,
      sent: sent,
      signer: _Signer(editor, 2),
      random: Random(402),
    );
    final id = (await ownerService.createDocument())!.documentId;
    await ownerService.grant(id, editor, CloudDocumentRole.editor);
    final invite = CloudDocumentFrame.decode(sent.removeLast().json)!;
    expect(await editorService.ingest(owner, invite.encode()), isTrue);
    expect(await editorService.adopt(id), isTrue);
    expect(
      await editorService.compactDocument(id),
      isNull,
      reason: 'an editor cannot mint a replacement owner root',
    );

    final before = (await editorService.loadRichText(id))!;
    sent.clear();
    await editorService.saveRichText(
      id,
      base: before.snapshot,
      text: 'offline branch',
      styles: List.filled(14, const CloudRichTextStyle()),
    );
    final unsentDelta = sent.removeLast();
    expect(unsentDelta.peer, owner);

    sent.clear();
    expect(await ownerService.compactDocument(id), isNotNull);
    final transition = CloudDocumentFrame.decode(sent.single.json)!;
    expect(await editorService.ingest(owner, transition.encode()), isFalse);
    expect(
      (await editorService.loadRichText(id))!.snapshot.text,
      'offline branch',
      reason: 'the local branch must remain intact rather than be overwritten',
    );
  });

  test(
    'fresh member adopts from a compacted root without old history',
    () async {
      final owner = _id(1);
      final viewer = _id(3);
      final envelopes = CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      );
      final sent = <({NodeId peer, String documentId, String json})>[];
      final ownerService = _service(
        self: owner,
        store: await _openStore(FakeHvContainer()),
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(owner, 1),
        random: Random(501),
      );
      final viewerStore = await _openStore(FakeHvContainer());
      final viewerService = _service(
        self: viewer,
        store: viewerStore,
        envelopes: envelopes,
        sent: sent,
        random: Random(502),
      );
      final id = (await ownerService.createDocument())!.documentId;
      final empty = (await ownerService.loadRichText(id))!;
      await ownerService.saveRichText(
        id,
        base: empty.snapshot,
        text: 'compacted invite',
        styles: List.filled(16, const CloudRichTextStyle()),
      );
      expect(await ownerService.compactDocument(id), isNotNull);
      sent.clear();
      expect(
        await ownerService.grant(id, viewer, CloudDocumentRole.viewer),
        isNotNull,
      );
      final invite = CloudDocumentFrame.decode(sent.single.json)!;
      expect(invite.root.generation, 1);
      expect(invite.root.baseEpoch, 0);
      expect(invite.controls.single.seq, 0);
      expect(
        invite.operations.length,
        2,
        reason: 'compaction checkpoint + grant checkpoint',
      );
      expect(await viewerService.ingest(owner, invite.encode()), isTrue);
      expect(await viewerService.adopt(id), isTrue);
      final state = (await viewerService.loadRichText(id))!;
      expect(state.snapshot.text, 'compacted invite');
      expect(state.localRole, CloudDocumentRole.viewer);
      final stored = (await viewerStore.load(id))!;
      expect(
        stored.localEpochKeys.keys,
        [1],
        reason: 'fresh adopt must not acquire pre-compaction epoch keys',
      );
      stored.wipeLocalEpochKeys();
    },
  );

  test(
    'shared folder: add/list/remove files replicate to a granted member',
    () async {
      final owner = _id(1);
      final editor = _id(2);
      final envelopes = CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      );
      final ownerStore = await _openStore(FakeHvContainer());
      final editorStore = await _openStore(FakeHvContainer());
      final sent = <({NodeId peer, String documentId, String json})>[];
      final ownerService = _service(
        self: owner,
        store: ownerStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(owner, 1),
        acceptedContact: (peer) async => peer == editor,
        random: Random(303),
      );
      final editorService = _service(
        self: editor,
        store: editorStore,
        envelopes: envelopes,
        sent: sent,
        signer: _Signer(editor, 2),
        random: Random(304),
      );

      final documentId = (await ownerService.createDocument(
        kind: CloudDocumentKind.fileCollection,
        codec: cloudFileCollectionCodecV1,
      ))!.documentId;
      expect(await ownerService.loadSharedFolder(documentId), isEmpty);

      final cidA = 'a' * 64;
      final cidB = 'b' * 64;
      expect(
        await ownerService.addSharedFolderFile(
          documentId,
          name: 'a.bin',
          contentId: cidA,
          size: 10,
          mime: 'application/octet-stream',
        ),
        isNotNull,
      );
      expect(
        await ownerService.addSharedFolderFile(
          documentId,
          name: 'b.txt',
          contentId: cidB,
          size: 4,
          path: 'sub',
        ),
        isNotNull,
      );
      final files = (await ownerService.loadSharedFolder(documentId))!;
      expect(files.map((f) => f.contentId).toSet(), {cidA, cidB});
      expect(files.firstWhere((f) => f.contentId == cidB).path, 'sub');

      // Grant an editor; the file list replicates to them.
      sent.clear();
      expect(
        await ownerService.grant(documentId, editor, CloudDocumentRole.editor),
        isNotNull,
      );
      final invite = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(await editorService.ingest(owner, invite.encode()), isTrue);
      expect(await editorService.adopt(documentId), isTrue);
      final editorFiles = (await editorService.loadSharedFolder(documentId))!;
      expect(editorFiles.map((f) => f.contentId).toSet(), {cidA, cidB});

      // Remove one file; the owner's list drops it (the row is tombstoned).
      final entryA = files.firstWhere((f) => f.contentId == cidA).id;
      expect(
        await ownerService.removeSharedFolderFile(documentId, entryA),
        isNotNull,
      );
      final afterRemoval = (await ownerService.loadSharedFolder(documentId))!;
      expect(afterRemoval.map((f) => f.contentId), [cidB]);

      // Revoking the editor rotates the epoch but the metadata stays readable.
      expect(await ownerService.revoke(documentId, editor), isNotNull);
      final revokedState = (await ownerService.listDocuments()).single;
      expect(revokedState.currentEpoch, greaterThan(0));
      expect(
        (await ownerService.loadSharedFolder(
          documentId,
        ))!.map((f) => f.contentId),
        [cidB],
      );
    },
  );

  test(
    'shared folder member content: host/download/servable/instant revoke',
    () async {
      final owner = _id(1);
      final editor = _id(2);
      final envelopes = CloudDocumentEnvelopeService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      );
      final ownerStore = await _openStore(FakeHvContainer());
      final editorStore = await _openStore(FakeHvContainer());
      final sent = <({NodeId peer, String documentId, String json})>[];
      final net = _MemberNet();
      final ownerFiles = _MemberStorage();
      final editorFiles = _MemberStorage();
      CloudDocumentReplicationService build({
        required NodeId self,
        required CloudDocumentStore store,
        required _MemberStorage files,
        required int slot,
        required CloudDocumentSigner signer,
        CloudDocumentAcceptedContact? acceptedContact,
        required int seed,
        _MemberNetDevice? netDevice,
      }) => CloudDocumentReplicationService(
        localNodeId: self,
        ourCertVersion: 0,
        store: store,
        envelopes: envelopes,
        sendFrame: (peer, documentId, json) async {
          sent.add((peer: peer, documentId: documentId, json: json));
        },
        signer: signer,
        acceptedContact: acceptedContact,
        random: Random(seed),
        verifyRoot: (_) => true,
        verifyControl: (_) => true,
        verifyOperation: (_) => true,
        verifyQuiescenceAck: (_) => true,
        now: () => DateTime.fromMillisecondsSinceEpoch(9000),
        // Per-device binding view: a shared fake would let a hosting member
        // derive an appId it cannot actually bind in production.
        memberContentNetwork: netDevice ?? net.device(),
        memberContentStorage: files,
        memberProviderSlot: () async => slot,
        memberFetchTimeout: const Duration(milliseconds: 400),
      );

      final ownerService = build(
        self: owner,
        store: ownerStore,
        files: ownerFiles,
        slot: 0,
        signer: _Signer(owner, 1),
        acceptedContact: (peer) async => peer == editor,
        seed: 511,
      );
      final editorService = build(
        self: editor,
        store: editorStore,
        files: editorFiles,
        slot: 1,
        signer: _Signer(editor, 2),
        seed: 512,
      );

      // Owner shares a real file: bytes + inline manifest.
      final documentId = (await ownerService.createDocument(
        kind: CloudDocumentKind.fileCollection,
        codec: cloudFileCollectionCodecV1,
      ))!.documentId;
      final bytes = Uint8List.fromList([
        for (var i = 0; i < 1500; i++) (i * 7) & 0xff,
      ]);
      final manifest = await ContentManifest.fromReader(
        name: 'shared.bin',
        size: bytes.length,
        readRange: (offset, length) async =>
            Uint8List.sublistView(bytes, offset, offset + length),
        pieceSize: 1024,
      );
      ownerFiles.files[manifest.contentId] = bytes;
      expect(
        await ownerService.addSharedFolderFile(
          documentId,
          name: 'shared.bin',
          contentId: manifest.contentId,
          size: bytes.length,
          mime: 'application/octet-stream',
          manifest: jsonEncode(manifest.toJson()),
        ),
        isNotNull,
      );

      // The owner hosts the folder under the epoch-derived identity.
      await ownerService.reconcileMemberHosting();
      var diag = ownerService.memberHostDiagnostics();
      expect(diag.keys, [documentId]);
      expect(diag[documentId]!.servable, [manifest.contentId]);
      final epochBeforeGrant = diag[documentId]!.epoch;
      expect(net.hostedSlots, [0], reason: 'constructor default applies');

      // A second sovereign device of the SAME identity derives an identical
      // host seed and alias, so only the provider slot separates them. The
      // device list lives in GroupService, which is built after this service
      // and keeps it alive, so the slot arrives by installation rather than
      // construction — that late binding is what this asserts.
      net.hostedSlots.clear();
      ownerService.memberProviderSlot = () async => 3;
      await ownerService.reconcileMemberHosting();
      expect(
        net.hostedSlots,
        isEmpty,
        reason: 'an unchanged epoch must not re-register the host',
      );

      // Grant the editor; adoption gives them metadata + the new epoch key.
      sent.clear();
      expect(
        await ownerService.grant(documentId, editor, CloudDocumentRole.editor),
        isNotNull,
      );
      final invite = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(await editorService.ingest(owner, invite.encode()), isTrue);
      expect(await editorService.adopt(documentId), isTrue);
      final entry = (await editorService.loadSharedFolder(
        documentId,
      ))!.single;
      expect(entry.manifest, isNotNull);
      expect(
        await editorService.isSharedFileLocal(manifest.contentId),
        isFalse,
      );

      // The grant rotated the epoch — the owner re-keys to the new address.
      await ownerService.reconcileMemberHosting();
      diag = ownerService.memberHostDiagnostics();
      expect(diag[documentId]!.epoch, greaterThan(epochBeforeGrant));
      // Re-hosting reads the slot again, so the installed resolver wins over
      // the constructor's default from here on.
      expect(net.hostedSlots, [3]);

      // Member download over the member content path, verified end-to-end.
      final fetched = await editorService.downloadSharedFolderFile(
        documentId,
        entry.id,
      );
      expect(fetched, isNotNull);
      expect(editorFiles.files[manifest.contentId], bytes);
      expect(editorFiles.files.containsKey('mf:${manifest.contentId}'), isTrue);
      // 1500 bytes over a 1 KiB piece size is two pieces, and each reached
      // storage on its own: adopting a shared file streams to disk instead of
      // assembling it, so a multi-GB one is bounded by disk rather than RAM.
      expect(manifest.pieceCount, 2);
      expect(editorFiles.piecesSeen[manifest.contentId], [0, 1]);
      expect(
        await editorService.isSharedFileLocal(manifest.contentId),
        isTrue,
      );

      // The editor now holds bytes → it becomes a provider too (slot 1).
      await editorService.reconcileMemberHosting();
      expect(
        editorService.memberHostDiagnostics()[documentId]!.servable,
        [manifest.contentId],
      );

      // Removing the row empties the servable set and tears the host down.
      final removed = await ownerService.removeSharedFolderFile(
        documentId,
        entry.id,
      );
      expect(removed, isNotNull);
      await ownerService.reconcileMemberHosting();
      expect(ownerService.memberHostDiagnostics(), isEmpty);

      // Re-add and re-host for the revoke stage.
      expect(
        await ownerService.addSharedFolderFile(
          documentId,
          name: 'shared.bin',
          contentId: manifest.contentId,
          size: bytes.length,
          manifest: jsonEncode(manifest.toJson()),
        ),
        isNotNull,
      );
      await ownerService.reconcileMemberHosting();
      expect(
        ownerService.memberHostDiagnostics()[documentId]!.servable,
        [manifest.contentId],
      );

      // INSTANT REVOKE: the epoch rotates, the owner re-keys, and the
      // revoked editor — still holding only the old epoch key — can neither
      // derive the new address nor a valid subkey. Its fetch fails.
      editorFiles.files.clear();
      expect(await ownerService.revoke(documentId, editor), isNotNull);
      // The old-key host dies synchronously WITH the revoke mutation itself —
      // no debounce window in which the revoked member can still pull bytes.
      expect(ownerService.memberHostDiagnostics(), isEmpty);
      await ownerService.reconcileMemberHosting();
      final refetch = await editorService.downloadSharedFolderFile(
        documentId,
        entry.id,
      );
      expect(refetch, isNull);
      expect(editorFiles.files, isEmpty);

      // RE-GRANT after revoke. The revoked editor still holds the stale
      // bundle, and an invite used to be dropped outright whenever the
      // document existed locally — silently, because the frame handler acks a
      // rejected ingest so the sender stops retrying. Revoke was therefore
      // permanent: nothing could put the member back.
      sent.clear();
      expect(
        await ownerService.grant(documentId, editor, CloudDocumentRole.editor),
        isNotNull,
      );
      final reInvite = CloudDocumentFrame.decode(sent.removeLast().json)!;
      expect(
        await editorService.ingest(owner, reInvite.encode()),
        isTrue,
        reason: 'a stale bundle that no longer admits us must not block re-entry',
      );
      expect(await editorService.adopt(documentId), isTrue);
      final regranted = (await editorService.loadSharedFolder(documentId))!;
      expect(regranted.map((f) => f.contentId), [manifest.contentId]);
      // Read the row id back rather than reusing `entry`: the remove/re-add
      // above minted a new row for the same content.
      final regrantedEntry = regranted.single;
      // ...and the restored access is real: the file downloads again over the
      // member path, on the epoch the re-grant rotated to.
      await ownerService.reconcileMemberHosting();
      expect(ownerService.memberHostDiagnostics()[documentId]?.servable, [
        manifest.contentId,
      ], reason: 'owner must be hosting again on the re-granted epoch');
      expect(
        await editorService.downloadSharedFolderFile(
          documentId,
          regrantedEntry.id,
        ),
        isNotNull,
      );
      expect(editorFiles.files[manifest.contentId], bytes);

      // Replaying that same invite must NOT reinstall the document. Its epoch
      // no longer leads the local bundle, so it is refused at ingest and never
      // becomes pending — adopt saves a frame wholesale, so an active member's
      // state has to stay theirs.
      expect(await editorService.ingest(owner, reInvite.encode()), isFalse);
      expect(await editorService.adopt(documentId), isFalse);

      // Restart: a fresh service over the same store re-hosts on reconcile.
      await ownerService.close();
      final restarted = build(
        self: owner,
        store: ownerStore,
        files: ownerFiles,
        slot: 0,
        signer: _Signer(owner, 1),
        seed: 513,
      );
      await restarted.reconcileMemberHosting();
      expect(
        restarted.memberHostDiagnostics()[documentId]!.servable,
        [manifest.contentId],
      );
      await restarted.close();
      await editorService.close();
    },
  );
}

/// In-memory member folder file store.
class _MemberStorage implements CloudMemberFolderStoragePort {
  final files = <String, Uint8List>{};

  @override
  Future<Uint8List?> readFileRange(
    String contentId,
    int offset,
    int length,
  ) async {
    final bytes = files[contentId];
    if (bytes == null || offset < 0 || offset + length > bytes.length) {
      return null;
    }
    return Uint8List.sublistView(bytes, offset, offset + length);
  }

  @override
  Future<bool> hasFile(String contentId) async => files.containsKey(contentId);

  @override
  Future<void> storeFile(
    String contentId,
    Uint8List bytes, {
    String? name,
  }) async {
    files[contentId] = Uint8List.fromList(bytes);
  }

  /// Pieces seen per contentId, in arrival order — lets a test prove the fetch
  /// streamed rather than assembled.
  final piecesSeen = <String, List<int>>{};
  final _partial = <String, Map<int, Uint8List>>{};

  @override
  Future<void> storeFilePiece(
    String contentId,
    int pieceIndex,
    int pieceCount,
    int pieceSize,
    int totalSize,
    Uint8List bytes, {
    String? name,
  }) async {
    (piecesSeen[contentId] ??= <int>[]).add(pieceIndex);
    final parts = _partial[contentId] ??= <int, Uint8List>{};
    parts[pieceIndex] = Uint8List.fromList(bytes);
    if (parts.length != pieceCount) return; // still incomplete: not a file yet
    final whole = BytesBuilder(copy: false);
    for (var i = 0; i < pieceCount; i++) {
      whole.add(parts[i]!);
    }
    files[contentId] = whole.toBytes();
    _partial.remove(contentId);
  }
}

/// Shared in-process anonymous network: endpoints registered by any service
/// are routable from any other, keyed by (servicePublicKey, appId, endpoint).
/// Service keys use the REAL ed25519-from-seed derivation so the coordinator's
/// fail-closed identity check and the client's independent derivation agree.
class _MemberNet implements CloudCapabilityNetworkPort {
  final endpoints = <_MemberNetEndpoint>[];

  /// providerSlot of every host() call, in order. All devices of an identity
  /// derive the same seed and alias, so this is the only field that tells two
  /// of them apart on the wire.
  final hostedSlots = <int>[];

  static Uint8List _appIdFor(String alias) => Uint8List.fromList(
    sha256.convert(utf8.encode('cap-app:$alias')).bytes,
  );

  @override
  Future<CloudCapabilityEndpointPort> host({
    required Uint8List identitySeed,
    required String alias,
    required int endpointId,
    required int providerSlot,
    bool transient = false,
  }) async {
    hostedSlots.add(providerSlot);
    final seed = Uint8List.fromList(identitySeed);
    identitySeed.fillRange(0, identitySeed.length, 0);
    final serviceKey = await CloudCapabilityCodec.onionServicePublicKeyFromSeed(
      seed,
    );
    final endpoint = _MemberNetEndpoint(
      serviceKey,
      _appIdFor(alias),
      endpointId,
      this,
    );
    endpoints.add(endpoint);
    return endpoint;
  }

  @override
  Future<Uint8List> capabilityAppId({
    required String alias,
    required int endpointId,
  }) async => _appIdFor(alias);

  /// A per-device view of the shared network.
  ///
  /// The real runtime binds an endpointId exclusively per node, and
  /// capabilityAppId — despite the name — BINDS to read the id back. A shared
  /// fake with no binding at all is more permissive than production, which is
  /// how "a member that hosts can never fetch" stayed invisible to tests.
  _MemberNetDevice device() => _MemberNetDevice(this);

  Future<void> route({
    required Uint8List servicePublicKey,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List data,
  }) async {
    bool same(List<int> a, List<int> b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    for (final endpoint in endpoints) {
      if (!endpoint.closed &&
          same(endpoint.servicePublicKey, servicePublicKey) &&
          same(endpoint.appId, targetAppId) &&
          endpoint.endpointId == targetEndpointId) {
        scheduleMicrotask(() {
          if (!endpoint.closed) {
            endpoint.controller.add(Uint8List.fromList(data));
          }
        });
        return;
      }
    }
  }
}

/// One node's view of [_MemberNet], enforcing exclusive endpointId binding.
///
/// Routing stays shared (that IS the network); only the binding table is
/// per-device, which is what production does. capabilityAppId binds too, so it
/// collides with a host this device already runs — the exact constraint that
/// made a hosting member unable to fetch.
class _MemberNetDevice implements CloudCapabilityNetworkPort {
  _MemberNetDevice(this._net);
  final _MemberNet _net;
  final bound = <int>{};

  @override
  Future<CloudCapabilityEndpointPort> host({
    required Uint8List identitySeed,
    required String alias,
    required int endpointId,
    required int providerSlot,
    bool transient = false,
  }) async {
    if (!bound.add(endpointId)) {
      throw StateError('bind failed: endpoint $endpointId is already bound');
    }
    final endpoint = await _net.host(
      identitySeed: identitySeed,
      alias: alias,
      endpointId: endpointId,
      providerSlot: providerSlot,
      transient: transient,
    );
    return _UnbindingEndpoint(endpoint, () => bound.remove(endpointId));
  }

  @override
  Future<Uint8List> capabilityAppId({
    required String alias,
    required int endpointId,
  }) async {
    if (bound.contains(endpointId)) {
      throw StateError('bind failed: endpoint $endpointId is already bound');
    }
    return _net.capabilityAppId(alias: alias, endpointId: endpointId);
  }
}

/// Releases the device's binding when the endpoint closes.
class _UnbindingEndpoint implements CloudCapabilityEndpointPort {
  _UnbindingEndpoint(this._inner, this._release);
  final CloudCapabilityEndpointPort _inner;
  final void Function() _release;

  @override
  Uint8List get servicePublicKey => _inner.servicePublicKey;
  @override
  Uint8List get appId => _inner.appId;
  @override
  int get endpointId => _inner.endpointId;
  @override
  Stream<Uint8List> get messages => _inner.messages;

  @override
  Future<void> sendAnonymous({
    required Uint8List servicePublicKey,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List data,
  }) => _inner.sendAnonymous(
    servicePublicKey: servicePublicKey,
    targetAppId: targetAppId,
    targetEndpointId: targetEndpointId,
    data: data,
  );

  @override
  Future<void> close() async {
    _release();
    await _inner.close();
  }
}

class _MemberNetEndpoint implements CloudCapabilityEndpointPort {
  _MemberNetEndpoint(
    this.servicePublicKey,
    this.appId,
    this.endpointId,
    this._net,
  );

  @override
  final Uint8List servicePublicKey;
  @override
  final Uint8List appId;
  @override
  final int endpointId;
  final _MemberNet _net;
  final controller = StreamController<Uint8List>.broadcast();
  bool closed = false;

  @override
  Stream<Uint8List> get messages => controller.stream;

  @override
  Future<void> sendAnonymous({
    required Uint8List servicePublicKey,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List data,
  }) => _net.route(
    servicePublicKey: servicePublicKey,
    targetAppId: targetAppId,
    targetEndpointId: targetEndpointId,
    data: data,
  );

  @override
  Future<void> close() async {
    closed = true;
    await controller.close();
  }
}
