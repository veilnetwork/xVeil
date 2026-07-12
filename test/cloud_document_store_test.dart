import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/cloud_document.dart';
import 'package:xveil/domain/cloud_document_envelope.dart';
import 'package:xveil/state/cloud_document_store.dart';

import 'support/fake_hv_container.dart';

String _hash(int byte) => List.filled(
  32,
  byte,
).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

NodeId _id(int byte) => NodeId.fromHex(_hash(byte));

CloudDocumentStoredBundle _bundle({int operationCount = 0, int keyByte = 7}) {
  final key = Uint8List.fromList(List.filled(32, keyByte));
  final commitment = cloudDocumentEpochKeyCommitment(
    documentId: _id(10),
    epoch: 0,
    key: key,
  );
  final envelope = CloudDocumentEpochEnvelopeBundle(
    documentId: _id(10),
    epoch: 0,
    keyCommitment: commitment,
    envelopes: [
      CloudDocumentRecipientEnvelope(
        recipient: _id(1),
        sealed: Uint8List.fromList([1, 2, 3, 4]),
      ),
    ],
  );
  final root = CloudDocumentRoot(
    documentId: _id(10),
    owner: _id(1),
    ownerPubKey: Uint8List.fromList(List.filled(32, 1)),
    kind: CloudDocumentKind.note,
    codec: 'xveil.note.rga.v1',
    epochKeyCommitment: commitment,
    epochEnvelopeHash: envelope.bundleHash,
    controlLogRoot: _hash(42),
    createdAtMs: 1000,
    signature: Uint8List.fromList(List.filled(64, 1)),
  );
  return CloudDocumentStoredBundle(
    root: root,
    controls: const [],
    operations: [
      for (var index = 0; index < operationCount; index++)
        CloudDocumentOperation(
          documentId: root.documentId,
          membershipEpoch: 0,
          author: root.owner,
          seq: index,
          prevAuthorHash: index == 0 ? '' : _hash(30 + index),
          operationId: _hash(100 + index),
          parentOperationIds: const [],
          opType: 'insert',
          payloadHash: _hash(20 + index),
          createdAtMs: 2000 + index,
          authorPubKey: Uint8List.fromList(List.filled(32, 1)),
          signature: Uint8List.fromList(List.filled(64, 1)),
        ),
    ],
    envelopes: [envelope],
    localEpochKeys: {0: key},
  );
}

void main() {
  test(
    'deniable document bundle survives restart beyond setting-record size',
    () async {
      final container = FakeHvContainer();
      final storage = container.storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final store = CloudDocumentStore(storage);
      final bundle = _bundle(operationCount: 80);
      expect(
        utf8.encode(jsonEncode(bundle.toJson())).length,
        greaterThan(4096),
      );

      await store.save(bundle);
      expect(await store.listDocumentIds(), [bundle.root.documentId.hex]);
      final loaded = await store.load(bundle.root.documentId.hex);
      expect(loaded, isNotNull);
      expect(loaded!.operations.length, 80);
      expect(loaded.localEpochKeys[0], bundle.localEpochKeys[0]);
      await storage.close();

      final reopened = container.storage();
      await reopened.open(password: 'pw');
      final afterRestart = CloudDocumentStore(reopened);
      final loadedAgain = await afterRestart.load(bundle.root.documentId.hex);
      expect(loadedAgain, isNotNull);
      expect(loadedAgain!.operations.length, 80);
      expect(await afterRestart.listDocumentIds(), [
        bundle.root.documentId.hex,
      ]);
      loadedAgain.wipeLocalEpochKeys();
      expect(loadedAgain.localEpochKeys[0], everyElement(0));
      await reopened.close();
    },
  );

  test(
    'corrupt active document and index slots fall back to prior generation',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final store = CloudDocumentStore(storage);
      final first = _bundle();
      final second = _bundle(operationCount: 20);
      await store.save(first);
      await store.save(second);
      expect(
        (await store.load(first.root.documentId.hex))!.operations.length,
        20,
      );

      final documentKey = 'cloud.document.v1.${first.root.documentId.hex}';
      final activeDocument = await storage.getSetting('$documentKey.active');
      await storage.storeFile(
        '$documentKey.$activeDocument',
        Uint8List.fromList(utf8.encode('{}')),
        name: 'cloud-document-log',
      );
      final fallback = await store.load(first.root.documentId.hex);
      expect(fallback, isNotNull);
      expect(fallback!.operations, isEmpty);

      const indexKey = 'cloud.documents.index.v1';
      final activeIndex = await storage.getSetting('$indexKey.active');
      await storage.storeFile(
        '$indexKey.$activeIndex',
        Uint8List.fromList(utf8.encode('{}')),
        name: 'cloud-document-log',
      );
      expect(await store.listDocumentIds(), [first.root.documentId.hex]);
      await storage.close();
    },
  );

  test('pending marker recovers a fully written pre-index document', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final bundle = _bundle(operationCount: 3);
    final id = bundle.root.documentId.hex;
    final documentKey = 'cloud.document.v1.$id';
    await storage.putSetting('cloud.documents.pending.v1', id);
    await storage.storeFile(
      '$documentKey.a',
      Uint8List.fromList(utf8.encode(jsonEncode(bundle.toJson()))),
      name: 'cloud-document-log',
    );
    await storage.putSetting('$documentKey.active', 'a');

    final store = CloudDocumentStore(storage);
    expect(await store.listDocumentIds(), [id]);
    expect((await store.load(id))!.operations.length, 3);

    // The next serialized write folds the recovered id into the durable index
    // and clears the one-slot pending journal.
    await store.save(bundle);
    expect(await storage.getSetting('cloud.documents.pending.v1'), isEmpty);
    expect(await store.listDocumentIds(), [id]);
    await storage.close();
  });

  test('wrong local epoch key is rejected before persistence', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final valid = _bundle();
    final invalid = CloudDocumentStoredBundle(
      root: valid.root,
      controls: valid.controls,
      operations: valid.operations,
      envelopes: valid.envelopes,
      localEpochKeys: {0: Uint8List.fromList(List.filled(32, 99))},
    );
    expect(invalid.isStructurallyValid, isFalse);
    await expectLater(
      CloudDocumentStore(storage).save(invalid),
      throwsArgumentError,
    );
    expect(
      await storage.hasFile('cloud.document.v1.${valid.root.documentId.hex}.a'),
      isFalse,
    );
    await storage.close();
  });
}
