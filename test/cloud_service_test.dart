import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/cloud.dart';
import 'package:xveil/domain/cloud_capability.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/state/cloud_service.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int value) =>
    NodeId.fromHex(value.toRadixString(16).padLeft(64, '0'));

class _FakeSync implements CloudSyncPort {
  _FakeSync(this.selfId, {List<DeviceSyncRecord>? seed}) : rows = [...?seed];

  @override
  final NodeId selfId;
  final List<DeviceSyncRecord> rows;
  final StreamController<void> controller = StreamController.broadcast();
  final List<(String, NodeId)> fetches = [];
  List<NodeId> memberList = [];
  bool connected = true;
  bool throwPosts = false;
  Completer<bool>? postGate;

  @override
  Stream<void> get changes => controller.stream;

  @override
  Future<List<DeviceSyncRecord>> records() async => [...rows];

  @override
  Future<bool> postItem(CloudItem item) async {
    if (throwPosts) throw StateError('transport unavailable');
    if (!connected) return false;
    final gate = postGate;
    if (gate != null) return gate.future;
    rows.add((event: item.toEvent(), author: selfId));
    controller.add(null);
    return true;
  }

  @override
  Future<bool> postFolder(CloudFolder folder) async {
    if (throwPosts) throw StateError('transport unavailable');
    if (!connected) return false;
    final gate = postGate;
    if (gate != null) return gate.future;
    rows.add((event: folder.toEvent(), author: selfId));
    controller.add(null);
    return true;
  }

  @override
  Future<bool> postClaim(CloudReplicaClaim claim) async {
    if (throwPosts) throw StateError('transport unavailable');
    if (!connected) return false;
    final gate = postGate;
    if (gate != null) return gate.future;
    rows.add((event: claim.toEvent(), author: selfId));
    controller.add(null);
    return true;
  }

  @override
  Future<List<NodeId>> members() async => [...memberList];

  @override
  Future<bool> fetch(String contentId, NodeId holder) async {
    fetches.add((contentId, holder));
    return true;
  }

  @override
  Future<void> close() => controller.close();
}

Uint8List _bytes(int length) =>
    Uint8List.fromList(List.generate(length, (index) => (index * 31) & 0xff));

Future<Uint8List> Function(int, int) _reader(Uint8List bytes) =>
    (offset, length) async =>
        Uint8List.sublistView(bytes, offset, offset + length);

void main() {
  test('text note edit retires old body into global GC quarantine', () async {
    final container = FakeHvContainer();
    final storage = container.storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final sync = _FakeSync(_id(1));
    final received = StreamController<String>.broadcast();
    var clock = 1000;
    final service = CloudService(
      storage,
      sync,
      contentReceived: received.stream,
      now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
      newId: () => 'note-1',
      integrityChecks: false,
    );

    final created = await service.saveTextNote(
      title: 'Private note',
      body: 'first body',
    );
    final firstCid = created.contentId!;
    expect(created.kind, CloudItemKind.note);
    expect(created.revision, 1);
    expect(await service.loadTextNote(created), 'first body');

    final edited = await service.saveTextNote(
      itemId: created.id,
      expectedRevision: created.revision,
      expectedContentId: created.contentId,
      title: 'Renamed note',
      body: 'second body',
    );
    expect(edited.revision, 2);
    expect(edited.createdAtMs, created.createdAtMs);
    expect(await service.loadTextNote(edited), 'second body');
    expect(await storage.hasFile(firstCid), isTrue);
    expect(await storage.hasFile('mf:$firstCid'), isTrue);
    final reachability = await storage.sharedContentReferenceSnapshot();
    expect(reachability.complete, isTrue);
    expect(reachability.referencedContentIds, isNot(contains(firstCid)));
    expect(
      sync.rows
          .where((row) => row.event.kind == DeviceSyncKind.cloudEntry)
          .map((row) => CloudItem.fromEvent(row.event)?.revision),
      containsAllInOrder([1, 2]),
    );

    await service.close();
    await received.close();
    await storage.close();
  });

  test(
    'stale note editor gets an explicit conflict without overwrite',
    () async {
      final container = FakeHvContainer();
      final storage = container.storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final sync = _FakeSync(_id(1));
      final received = StreamController<String>.broadcast();
      final service = CloudService(
        storage,
        sync,
        contentReceived: received.stream,
        newId: () => 'note-conflict',
        integrityChecks: false,
      );
      final original = await service.saveTextNote(title: 'Note', body: 'v1');
      final current = await service.saveTextNote(
        itemId: original.id,
        expectedRevision: original.revision,
        expectedContentId: original.contentId,
        title: 'Note',
        body: 'v2 remote',
      );

      await expectLater(
        service.saveTextNote(
          itemId: original.id,
          expectedRevision: original.revision,
          expectedContentId: original.contentId,
          title: 'Note',
          body: 'stale local',
        ),
        throwsA(
          isA<CloudEditConflict>().having(
            (error) => error.current.revision,
            'current revision',
            current.revision,
          ),
        ),
      );
      expect(await service.loadTextNote(current), 'v2 remote');

      await service.close();
      await received.close();
      await storage.close();
    },
  );

  test(
    'remote note revision quarantines superseded local ciphertext',
    () async {
      final container = FakeHvContainer();
      final storage = container.storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final sync = _FakeSync(_id(1));
      final received = StreamController<String>.broadcast();
      var clock = 3000;
      final service = CloudService(
        storage,
        sync,
        contentReceived: received.stream,
        now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
        newId: () => 'remote-note',
        integrityChecks: false,
      );
      final original = await service.saveTextNote(title: 'Note', body: 'local');
      final oldCid = original.contentId!;
      final remoteBytes = Uint8List.fromList(utf8.encode('remote'));
      final remoteManifest = ContentManifest.fromBytes('Note', remoteBytes);
      final remote = CloudItem(
        id: original.id,
        kind: CloudItemKind.note,
        name: 'Note',
        contentId: remoteManifest.contentId,
        size: remoteBytes.length,
        mime: 'text/plain; charset=utf-8',
        createdAtMs: original.createdAtMs,
        modifiedAtMs: original.modifiedAtMs + 100,
        revision: original.revision + 1,
        deleted: false,
      );
      sync.rows.add((event: remote.toEvent(), author: _id(2)));
      sync.controller.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect((await service.listItems()).single.contentId, remote.contentId);
      expect(await storage.hasFile(oldCid), isTrue);
      expect(await storage.hasFile('mf:$oldCid'), isTrue);
      expect(
        (await storage.sharedContentReferenceSnapshot()).referencedContentIds,
        isNot(contains(oldCid)),
      );
      final claims = foldCloudReplicaClaims(sync.rows);
      final localClaims = claims.values
          .where(
            (claim) =>
                claim.itemId == original.id &&
                claim.deviceId == sync.selfId &&
                claim.contentId == oldCid,
          )
          .toList();
      expect(localClaims, hasLength(1));
      final localClaim = localClaims.single;
      expect(localClaim.contentId, oldCid);
      expect(localClaim.present, isFalse);

      await service.close();
      await received.close();
      await storage.close();
    },
  );

  test(
    'concurrent note heads survive reconcile/restart and merge explicitly',
    () async {
      final container = FakeHvContainer();
      final storage = container.storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final sync = _FakeSync(_id(1));
      final received = StreamController<String>.broadcast();
      var clock = 4000;
      final service = CloudService(
        storage,
        sync,
        contentReceived: received.stream,
        now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
        newId: () => 'branch-note',
        integrityChecks: false,
      );
      final root = await service.saveTextNote(title: 'Note', body: 'root');
      final left = await service.saveTextNote(
        itemId: root.id,
        expectedRevision: root.revision,
        expectedContentId: root.contentId,
        title: 'Note',
        body: 'left branch',
      );
      final rightBytes = Uint8List.fromList(utf8.encode('right branch'));
      final rightManifest = ContentManifest.fromBytes('Note', rightBytes);
      await storage.storeFile(
        rightManifest.contentId,
        rightBytes,
        name: 'Note',
      );
      await storage.storeFile(
        'mf:${rightManifest.contentId}',
        Uint8List.fromList(utf8.encode(jsonEncode(rightManifest.toJson()))),
      );
      final right = CloudItem(
        id: root.id,
        kind: CloudItemKind.note,
        name: 'Note',
        contentId: rightManifest.contentId,
        size: rightBytes.length,
        mime: 'text/plain; charset=utf-8',
        createdAtMs: root.createdAtMs,
        modifiedAtMs: left.modifiedAtMs + 100,
        revision: 2,
        deleted: false,
        parentContentIds: [root.contentId!],
      );
      sync.rows.add((event: right.toEvent(), author: _id(2)));
      sync.controller.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final current = (await service.listItems()).single;
      expect(current.contentId, right.contentId);
      expect(service.noteHeads(current).map((item) => item.contentId), {
        left.contentId,
        right.contentId,
      });
      expect(await storage.hasFile(left.contentId!), isTrue);
      expect(await storage.hasFile(right.contentId!), isTrue);
      await expectLater(
        service.saveTextNote(
          itemId: left.id,
          expectedRevision: left.revision,
          expectedContentId: left.contentId,
          title: 'Note',
          body: 'must not bypass the equal-revision conflict',
        ),
        throwsA(
          isA<CloudEditConflict>().having(
            (error) => error.current.contentId,
            'current cid',
            right.contentId,
          ),
        ),
      );

      await service.close();
      await received.close();
      final sync2 = _FakeSync(_id(1), seed: sync.rows);
      final received2 = StreamController<String>.broadcast();
      final restarted = CloudService(
        storage,
        sync2,
        contentReceived: received2.stream,
        now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
        integrityChecks: false,
      );
      final reloaded = (await restarted.listItems()).single;
      final heads = restarted.noteHeads(reloaded);
      expect(heads.map((item) => item.contentId), {
        left.contentId,
        right.contentId,
      });

      final merged = await restarted.saveTextNote(
        itemId: reloaded.id,
        expectedRevision: reloaded.revision,
        expectedContentId: reloaded.contentId,
        mergeParentContentIds: heads.map((item) => item.contentId!),
        title: 'Note',
        body: 'merged body',
      );
      expect(merged.revision, 3);
      expect(restarted.noteHeads(merged).single.contentId, merged.contentId);
      expect(await restarted.loadTextNote(merged), 'merged body');
      expect(await storage.hasFile(left.contentId!), isTrue);
      expect(await storage.hasFile(right.contentId!), isTrue);
      final reachability = await storage.sharedContentReferenceSnapshot();
      expect(
        reachability.referencedContentIds,
        isNot(contains(left.contentId)),
      );
      expect(
        reachability.referencedContentIds,
        isNot(contains(right.contentId)),
      );

      await restarted.close();
      await received2.close();
      await storage.close();
    },
  );

  test('text note bounds are enforced before storage mutation', () async {
    final container = FakeHvContainer();
    final storage = container.storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final sync = _FakeSync(_id(1));
    final received = StreamController<String>.broadcast();
    final service = CloudService(
      storage,
      sync,
      contentReceived: received.stream,
      newId: () => 'note-large',
      integrityChecks: false,
    );

    await expectLater(
      service.saveTextNote(
        title: 'Too large',
        body: List.filled(CloudService.maxTextNoteBytes + 1, 'x').join(),
      ),
      throwsArgumentError,
    );
    expect(await service.listItems(), isEmpty);

    await service.close();
    await received.close();
    await storage.close();
  });

  test('note save stays local-first when device sync never returns', () async {
    final container = FakeHvContainer();
    final storage = container.storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final sync = _FakeSync(_id(1))..postGate = Completer<bool>();
    final received = StreamController<String>.broadcast();
    final service = CloudService(
      storage,
      sync,
      contentReceived: received.stream,
      newId: () => 'offline-note',
      integrityChecks: false,
    );

    final note = await service
        .saveTextNote(title: 'Offline', body: 'durable first')
        .timeout(const Duration(seconds: 1));
    expect((await service.listItems()).single.id, note.id);
    expect(await service.loadTextNote(note), 'durable first');
    expect(await storage.hasFile(note.contentId!), isTrue);

    await service.close();
    await received.close();
    await storage.close();
  });

  test(
    'adopts verified capability bytes without a second content id',
    () async {
      final container = FakeHvContainer();
      final storage = container.storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final bytes = _bytes(4096);
      final manifest = ContentManifest.fromBytes('public.bin', bytes);
      await storage.storeFile(manifest.contentId, bytes, name: manifest.name);
      await storage.storeFile(
        'mf:${manifest.contentId}',
        Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
      );
      final sync = _FakeSync(_id(1));
      final received = StreamController<String>.broadcast();
      final service = CloudService(
        storage,
        sync,
        contentReceived: received.stream,
        newId: () => 'public-item',
      );
      final item = await service.adoptCapability(
        CloudCapability(
          shareId: Uint8List(32),
          key: Uint8List(32),
          servicePublicKey: Uint8List(32),
          appId: Uint8List(32),
          endpointId: 37,
          expiresAtMs: DateTime(2035).millisecondsSinceEpoch,
          manifest: manifest,
          revision: 4,
          mime: 'application/octet-stream',
        ),
      );
      expect(item.id, 'public-item');
      expect(item.contentId, manifest.contentId);
      expect(item.revision, 4);
      expect(await storage.loadFile(manifest.contentId), bytes);
      expect(
        sync.rows.where((row) => row.event.kind == DeviceSyncKind.cloudEntry),
        isNotEmpty,
      );
      await service.close();
      await received.close();
      await storage.close();
    },
  );

  test(
    'RAM-bounded import persists blob, manifest, index and replica claim',
    () async {
      final container = FakeHvContainer();
      final storage = container.storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final sync = _FakeSync(_id(1));
      final received = StreamController<String>.broadcast();
      var now = 100;
      final service = CloudService(
        storage,
        sync,
        contentReceived: received.stream,
        now: () => DateTime.fromMillisecondsSinceEpoch(now++),
        newId: () => 'cloud_item_1',
      );
      // Above the 3.8 MB whole-blob ceiling: exercises the truly streamed
      // large-object path rather than the small-file index-saving fast path.
      final bytes = _bytes(4000000);
      var largestRead = 0;
      final item = await service.importContent(
        name: 'archive.bin',
        size: bytes.length,
        readRange: (offset, length) async {
          if (length > largestRead) largestRead = length;
          return Uint8List.sublistView(bytes, offset, offset + length);
        },
        mime: 'application/octet-stream',
      );

      expect(item.id, 'cloud_item_1');
      expect(await storage.hasFile(item.contentId!), isTrue);
      expect(
        largestRead,
        lessThanOrEqualTo(ContentManifest.adaptivePieceSize(bytes.length)),
      );
      expect(await service.verifyItem(item), isTrue);
      expect(service.replicaCount(item), 1);
      expect(
        sync.rows.where((row) => row.event.kind == DeviceSyncKind.cloudEntry),
        isNotEmpty,
      );
      expect(
        sync.rows.where((row) => row.event.kind == DeviceSyncKind.cloudReplica),
        isNotEmpty,
      );

      await service.close();
      await received.close();
      await storage.close();
    },
  );

  test(
    'solo index survives restart and backfills once device sync exists',
    () async {
      final container = FakeHvContainer();
      final storage = container.storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final offline = _FakeSync(_id(1))..connected = false;
      final received = StreamController<String>.broadcast();
      final first = CloudService(
        storage,
        offline,
        contentReceived: received.stream,
        now: () => DateTime.fromMillisecondsSinceEpoch(100),
        newId: () => 'solo',
      );
      final bytes = _bytes(1000);
      await first.importContent(
        name: 'solo.bin',
        size: bytes.length,
        readRange: _reader(bytes),
      );
      expect(
        (await storage.settingsKeys()).where(
          (key) => key.startsWith('filepiece:'),
        ),
        isEmpty,
        reason: 'small cloud files must not consume one index key per piece',
      );
      expect(offline.rows, isEmpty);
      await first.close();
      await storage.close();

      final reopened = container.storage();
      await reopened.open(password: 'pw');
      final linked = _FakeSync(_id(1));
      final second = CloudService(
        reopened,
        linked,
        contentReceived: const Stream.empty(),
      );
      await second.start();
      expect((await second.listItems()).single.id, 'solo');
      expect(
        linked.rows.any((row) => row.event.kind == DeviceSyncKind.cloudEntry),
        isTrue,
      );
      expect(
        linked.rows.any((row) => row.event.kind == DeviceSyncKind.cloudReplica),
        isTrue,
      );
      await second.close();
      await reopened.close();
      await received.close();
    },
  );

  test(
    'materialized index exceeds one setting record and survives restart',
    () async {
      final container = FakeHvContainer();
      final storage = container.storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final author = _id(2);
      final seed = <DeviceSyncRecord>[
        for (var index = 1; index <= 80; index++)
          (
            event: CloudItem(
              id: 'bulk_$index',
              kind: CloudItemKind.file,
              name: 'bulk-$index.bin',
              contentId: index.toRadixString(16).padLeft(64, '0'),
              size: index,
              createdAtMs: index,
              modifiedAtMs: index,
              revision: 1,
              deleted: false,
            ).toEvent(),
            author: author,
          ),
      ];
      final first = CloudService(
        storage,
        _FakeSync(_id(1), seed: seed)..connected = false,
        contentReceived: const Stream.empty(),
        integrityChecks: false,
      );

      expect((await first.listItems()).length, 80);
      final active = await storage.getSetting('cloud.index.v1.active');
      expect(active, anyOf('a', 'b'));
      final encoded = await storage.loadFile('cloud.index.v1.$active');
      expect(encoded, isNotNull);
      expect(encoded!.length, greaterThan(4096));
      expect(await storage.getSetting('cloud.index.v1'), isEmpty);
      await first.close();
      final missingSlot = active == 'a' ? 'b' : 'a';
      expect(await storage.hasFile('cloud.index.v1.$missingSlot'), isFalse);
      await storage.putSetting('cloud.index.v1.active', missingSlot);
      await storage.close();

      final reopened = container.storage();
      await reopened.open(password: 'pw');
      final second = CloudService(
        reopened,
        _FakeSync(_id(1))..connected = false,
        contentReceived: const Stream.empty(),
        integrityChecks: false,
      );
      expect((await second.listItems()).length, 80);
      expect(
        await reopened.hasFile('cloud.index.v1.$missingSlot'),
        isTrue,
        reason:
            'save repairs into the missing slot without overwriting the '
            'only readable fallback first',
      );
      await second.close();
      await reopened.putSetting('cloud.index.v1.active', 'corrupt');
      await reopened.close();

      final pointerless = container.storage();
      await pointerless.open(password: 'pw');
      final third = CloudService(
        pointerless,
        _FakeSync(_id(1))..connected = false,
        contentReceived: const Stream.empty(),
        integrityChecks: false,
      );
      expect((await third.listItems()).length, 80);
      await third.close();
      await pointerless.close();
    },
  );

  test('transport failure does not undo a durable local import', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final sync = _FakeSync(_id(1))..throwPosts = true;
    final service = CloudService(
      storage,
      sync,
      contentReceived: const Stream.empty(),
      now: () => DateTime.fromMillisecondsSinceEpoch(100),
      newId: () => 'offline_throw',
    );
    final bytes = _bytes(64);

    final item = await service.importContent(
      name: 'offline.bin',
      size: bytes.length,
      readRange: _reader(bytes),
    );

    expect((await service.listItems()).single.id, item.id);
    expect(await storage.hasFile(item.contentId!), isTrue);
    await service.close();
    await storage.close();
  });

  test(
    'contact sharing is accepted-only and delegates the existing cid',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final peer = _id(9);
      await storage.upsertContact(
        Contact(nodeId: peer, name: 'Peer', status: ContactStatus.accepted),
      );
      await storage.upsertContact(
        Contact(nodeId: _id(1), status: ContactStatus.accepted),
      );
      await storage.upsertContact(
        Contact(nodeId: _id(8), status: ContactStatus.blocked),
      );
      (NodeId, String)? shared;
      final service = CloudService(
        storage,
        _FakeSync(_id(1)),
        contentReceived: const Stream.empty(),
        shareStoredContent: (target, cid) async {
          shared = (target, cid);
          return true;
        },
        now: () => DateTime.fromMillisecondsSinceEpoch(100),
        newId: () => 'share_me',
      );
      final bytes = _bytes(64);
      final item = await service.importContent(
        name: 'share.bin',
        size: bytes.length,
        readRange: _reader(bytes),
      );

      expect((await service.acceptedContacts()).single.nodeId, peer);
      expect(await service.shareWithContact(item, peer), isTrue);
      expect(shared, (peer, item.contentId!));

      await service.close();
      await storage.close();
    },
  );

  test(
    'cloud/chat deletion defers shared payload+manifest to global GC',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final peer = _id(9);
      await storage.upsertContact(
        Contact(nodeId: peer, name: 'Peer', status: ContactStatus.accepted),
      );
      final service = CloudService(
        storage,
        _FakeSync(_id(1)),
        contentReceived: const Stream.empty(),
        now: () => DateTime.fromMillisecondsSinceEpoch(100),
        newId: () => 'cloud_chat_shared',
      );
      final bytes = _bytes(64);
      final item = await service.importContent(
        name: 'shared.bin',
        size: bytes.length,
        readRange: _reader(bytes),
      );
      final cid = item.contentId!;
      await storage.appendMessage(
        Message(
          id: 'share-post',
          conversationId: peer.hex,
          direction: MessageDirection.outgoing,
          body: '📎 shared.bin',
          timestamp: DateTime.fromMillisecondsSinceEpoch(101),
          fileId: cid,
          fileName: 'shared.bin',
        ),
      );

      await service.deleteItem(item.id);

      expect(
        await storage.hasFile(cid),
        isTrue,
        reason: 'the live chat post still owns the deduplicated payload',
      );
      expect(
        await storage.hasFile('mf:$cid'),
        isTrue,
        reason: 'restart/reoffer still needs the shared durable manifest',
      );

      await storage.deleteMessage(peer.hex, 'share-post');
      expect(await storage.hasFile(cid), isTrue);
      expect(await storage.hasFile('mf:$cid'), isTrue);
      final reachability = await storage.sharedContentReferenceSnapshot();
      expect(reachability.complete, isTrue);
      expect(
        reachability.referencedContentIds,
        isNot(contains(cid)),
        reason: 'the global collector can now quarantine the last reference',
      );

      await service.close();
      await storage.close();
    },
  );

  test(
    'index-only stays lazy; all mode pulls from a verified replica',
    () async {
      final source = _id(1);
      final target = _id(2);
      final item = CloudItem(
        id: 'remote',
        kind: CloudItemKind.file,
        name: 'remote.bin',
        contentId: List.filled(32, 'aa').join(),
        size: 12,
        createdAtMs: 10,
        modifiedAtMs: 10,
        revision: 1,
        deleted: false,
      );
      final claim = CloudReplicaClaim(
        itemId: item.id,
        deviceId: source,
        contentId: item.contentId!,
        present: true,
        verifiedAtMs: 11,
        size: item.size,
      );
      final sync = _FakeSync(
        target,
        seed: [
          (event: item.toEvent(), author: source),
          (event: claim.toEvent(), author: source),
        ],
      )..memberList = [source, target];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = CloudService(
        storage,
        sync,
        contentReceived: const Stream.empty(),
      );
      await service.start();
      expect(
        sync.fetches,
        isEmpty,
        reason: 'safe mobile default is index-only',
      );
      await service.setProfile(
        const CloudReplicationProfile(mode: CloudReplicationMode.all),
      );
      await Future<void>.delayed(Duration.zero);
      expect(sync.fetches, [(item.contentId!, source)]);
      await service.close();
      await storage.close();
    },
  );

  test(
    'corruption is claimed absent and repair scrubs before refetch',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final sync = _FakeSync(_id(1))..memberList = [_id(1), _id(2)];
      final service = CloudService(
        storage,
        sync,
        contentReceived: const Stream.empty(),
        now: () => DateTime.fromMillisecondsSinceEpoch(100),
        newId: () => 'repair_me',
      );
      final bytes = _bytes(4096);
      final item = await service.importContent(
        name: 'repair.bin',
        size: bytes.length,
        readRange: _reader(bytes),
      );
      await storage.deleteStoredFile(item.contentId!);
      await storage.scrubDeleted();
      expect(await service.verifyItem(item, repair: true), isFalse);
      expect(sync.fetches.single.$1, item.contentId);
      expect(sync.fetches.single.$2, _id(2));
      final claims = sync.rows
          .where((row) => row.event.kind == DeviceSyncKind.cloudReplica)
          .map(
            (row) => CloudReplicaClaim.fromEvent(row.event, author: row.author),
          )
          .whereType<CloudReplicaClaim>();
      expect(claims.last.present, isFalse);
      await service.close();
      await storage.close();
    },
  );

  test(
    'tombstone converges and is retained in deniable materialized index',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final sync = _FakeSync(_id(1));
      final service = CloudService(
        storage,
        sync,
        contentReceived: const Stream.empty(),
        now: () => DateTime.fromMillisecondsSinceEpoch(100),
        newId: () => 'delete_me',
      );
      final bytes = _bytes(3);
      final item = await service.importContent(
        name: 'delete.bin',
        size: bytes.length,
        readRange: _reader(bytes),
      );
      await service.deleteItem(item.id);
      expect(await service.listItems(), isEmpty);
      expect(await storage.hasFile(item.contentId!), isTrue);
      expect(await storage.hasFile('mf:${item.contentId}'), isTrue);
      expect(
        (await storage.sharedContentReferenceSnapshot()).referencedContentIds,
        isNot(contains(item.contentId)),
      );
      final all = await service.listItems(includeDeleted: true);
      expect(all.single.deleted, isTrue);
      final active = await storage.getSetting('cloud.index.v1.active');
      final raw = utf8.decode(
        (await storage.loadFile('cloud.index.v1.$active'))!,
      );
      final rows = jsonDecode(raw) as List;
      expect(
        CloudItem.fromEvent(
          DeviceSyncEvent.fromBody(rows.single as String)!,
        )?.deleted,
        isTrue,
      );
      await service.close();
      await storage.close();
    },
  );

  test('global roots preserve a cid shared by another live item', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final sync = _FakeSync(_id(1));
    final ids = ['first', 'second'].iterator;
    final service = CloudService(
      storage,
      sync,
      contentReceived: const Stream.empty(),
      now: () => DateTime.fromMillisecondsSinceEpoch(100),
      newId: () {
        ids.moveNext();
        return ids.current;
      },
    );
    final bytes = _bytes(32);
    final first = await service.importContent(
      name: 'same.bin',
      size: bytes.length,
      readRange: _reader(bytes),
    );
    final second = await service.importContent(
      name: 'same.bin',
      size: bytes.length,
      readRange: _reader(bytes),
    );
    expect(second.contentId, first.contentId);

    await service.deleteItem(first.id);
    expect(await storage.hasFile(first.contentId!), isTrue);
    expect(
      (await storage.sharedContentReferenceSnapshot()).referencedContentIds,
      contains(first.contentId),
    );
    await service.deleteItem(second.id);
    expect(await storage.hasFile(first.contentId!), isTrue);
    expect(
      (await storage.sharedContentReferenceSnapshot()).referencedContentIds,
      isNot(contains(first.contentId)),
    );

    await service.close();
    await storage.close();
  });

  test('folder lifecycle persists, syncs, and survives a restart', () async {
    final container = FakeHvContainer();
    final storage = container.storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final sync = _FakeSync(_id(1));
    var clock = 10000;
    final ids = ['folder-a', 'note-a'].iterator;
    final service = CloudService(
      storage,
      sync,
      contentReceived: const Stream.empty(),
      now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
      newId: () {
        ids.moveNext();
        return ids.current;
      },
      integrityChecks: false,
    );

    final folder = await service.createFolder('  Работа  ');
    expect(folder.name, 'Работа');
    expect(service.listFolders().single.id, folder.id);
    expect(
      sync.rows.where((row) => row.event.kind == DeviceSyncKind.cloudFolder),
      hasLength(1),
      reason: 'folder rows travel the signed device-group log',
    );

    final note = await service.saveTextNote(
      title: 'In folder',
      body: 'text',
      folderId: folder.id,
    );
    expect(note.folderId, folder.id);

    final renamed = await service.renameFolder(folder.id, 'Личное');
    expect(renamed.revision, 2);

    // A second service over the same storage sees folders and assignment.
    await service.close();
    final restarted = CloudService(
      storage,
      _FakeSync(_id(1)),
      contentReceived: const Stream.empty(),
      now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
      integrityChecks: false,
    );
    await restarted.start();
    expect(restarted.listFolders().single.name, 'Личное');
    final reloaded = (await restarted.listItems()).single;
    expect(reloaded.folderId, folder.id);
    expect(restarted.effectiveFolderId(reloaded), folder.id);
    await restarted.close();
    await storage.close();
  });

  test(
    'deleting a folder reassigns documents to root without rewrites',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final sync = _FakeSync(_id(1));
      var clock = 20000;
      final ids = ['folder-b', 'file-b'].iterator;
      final service = CloudService(
        storage,
        sync,
        contentReceived: const Stream.empty(),
        now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
        newId: () {
          ids.moveNext();
          return ids.current;
        },
        integrityChecks: false,
      );
      final folder = await service.createFolder('Docs');
      final bytes = _bytes(16);
      final file = await service.importContent(
        name: 'doc.bin',
        size: bytes.length,
        readRange: _reader(bytes),
        folderId: folder.id,
      );
      expect(service.effectiveFolderId(file), folder.id);

      final itemRowsBefore = sync.rows
          .where((row) => row.event.kind == DeviceSyncKind.cloudEntry)
          .length;
      await service.deleteFolder(folder.id);
      expect(service.listFolders(), isEmpty);
      final current = (await service.listItems()).single;
      expect(current.deleted, isFalse, reason: 'the document is never lost');
      expect(current.folderId, folder.id, reason: 'row is not rewritten');
      expect(
        service.effectiveFolderId(current),
        isNull,
        reason: 'dangling folder resolves to root at view time',
      );
      expect(
        sync.rows
            .where((row) => row.event.kind == DeviceSyncKind.cloudEntry)
            .length,
        itemRowsBefore,
        reason: 'folder delete must not repost item rows (no LWW clobber)',
      );

      // Tombstone wins the fold against the stale upsert on a fresh merge.
      final folded = foldCloudFolders([for (final row in sync.rows) row.event]);
      expect(folded[folder.id]?.deleted, isTrue);

      await expectLater(
        service.moveItemToFolder(current.id, folder.id),
        throwsA(isA<StateError>()),
      );
      await service.close();
      await storage.close();
    },
  );

  test('moves are metadata-only and remote folders reconcile in', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final sync = _FakeSync(_id(1));
    var clock = 30000;
    final ids = ['folder-c', 'note-c'].iterator;
    final service = CloudService(
      storage,
      sync,
      contentReceived: const Stream.empty(),
      now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
      newId: () {
        ids.moveNext();
        return ids.current;
      },
      integrityChecks: false,
    );
    final folder = await service.createFolder('Target');
    final note = await service.saveTextNote(title: 'Movable', body: 'v1');
    expect(note.folderId, isNull);

    final moved = await service.moveItemToFolder(note.id, folder.id);
    expect(moved.folderId, folder.id);
    expect(moved.revision, note.revision, reason: 'move is metadata-only');
    expect(moved.contentId, note.contentId);

    // The open-editor optimistic check still matches after a move, and the
    // edit keeps the note in its folder.
    final edited = await service.saveTextNote(
      itemId: note.id,
      expectedRevision: note.revision,
      expectedContentId: note.contentId,
      title: 'Movable',
      body: 'v2',
    );
    expect(edited.folderId, folder.id, reason: 'edits keep the folder');
    expect(edited.revision, note.revision + 1);

    // A folder authored on another device appears after reconcile.
    final remoteFolder = CloudFolder(
      id: 'remote-folder',
      name: 'From phone',
      createdAtMs: clock,
      modifiedAtMs: clock + 1,
      revision: 1,
      deleted: false,
    );
    sync.rows.add((event: remoteFolder.toEvent(), author: _id(2)));
    sync.controller.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(
      service.listFolders().map((entry) => entry.id),
      containsAll(['folder-c', 'remote-folder']),
    );
    await service.close();
    await storage.close();
  });

  test(
    'a remote move with a newer clock cannot resurrect a deleted item',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final sync = _FakeSync(_id(1));
      var clock = 50000;
      final service = CloudService(
        storage,
        sync,
        contentReceived: const Stream.empty(),
        now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
        newId: () => 'gone-note',
        integrityChecks: false,
      );
      final note = await service.saveTextNote(title: 'Gone', body: 'v1');
      await service.deleteItem(note.id);
      expect(await service.listItems(), isEmpty);

      // Another device moved the note into a folder while offline, with a
      // wall clock AHEAD of the deletion. The tombstone must absorb it.
      final remoteMove = note.movedToFolder('some-folder', clock + 5000);
      sync.rows.add((event: remoteMove.toEvent(), author: _id(2)));
      sync.controller.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(await service.listItems(), isEmpty);
      final all = await service.listItems(includeDeleted: true);
      expect(all.single.deleted, isTrue);
      await service.close();
      await storage.close();
    },
  );

  test(
    'a concurrent edit is not clobbered by a folder move that wins LWW',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final sync = _FakeSync(_id(1));
      var clock = 40000;
      final ids = ['folder-d', 'note-d'].iterator;
      final service = CloudService(
        storage,
        sync,
        contentReceived: const Stream.empty(),
        now: () => DateTime.fromMillisecondsSinceEpoch(clock++),
        newId: () {
          ids.moveNext();
          return ids.current;
        },
        integrityChecks: false,
      );
      final folder = await service.createFolder('Race');
      final note = await service.saveTextNote(title: 'Raced', body: 'v1');
      // The local move happens with a LATER wall clock than the remote edit.
      clock += 1000;
      final moved = await service.moveItemToFolder(note.id, folder.id);

      // Another device edited the same note offline before the move's ts.
      final remoteEdit = CloudItem(
        id: note.id,
        kind: CloudItemKind.note,
        name: 'Raced',
        contentId: List.filled(64, 'e').join(),
        size: 9,
        mime: 'text/plain; charset=utf-8',
        createdAtMs: note.createdAtMs,
        modifiedAtMs: moved.modifiedAtMs - 500,
        revision: note.revision + 1,
        deleted: false,
        parentContentIds: [note.contentId!],
      );
      sync.rows.add((event: remoteEdit.toEvent(), author: _id(2)));
      sync.controller.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final winner = (await service.listItems()).single;
      expect(
        winner.contentId,
        remoteEdit.contentId,
        reason: 'reconcile promotes the DAG head over the stale metadata row',
      );
      expect(
        winner.folderId,
        folder.id,
        reason: 'the promoted head carries the move destination',
      );
      expect(winner.revision, remoteEdit.revision);
      await service.close();
      await storage.close();
    },
  );
}
