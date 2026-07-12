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

  @override
  Stream<void> get changes => controller.stream;

  @override
  Future<List<DeviceSyncRecord>> records() async => [...rows];

  @override
  Future<bool> postItem(CloudItem item) async {
    if (throwPosts) throw StateError('transport unavailable');
    if (!connected) return false;
    rows.add((event: item.toEvent(), author: selfId));
    controller.add(null);
    return true;
  }

  @override
  Future<bool> postClaim(CloudReplicaClaim claim) async {
    if (throwPosts) throw StateError('transport unavailable');
    if (!connected) return false;
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
    'cloud deletion keeps chat-shared payload+manifest until the chat is gone',
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
      expect(
        await storage.hasFile(cid),
        isFalse,
        reason: 'the last cross-domain reference now disappeared',
      );
      expect(
        await storage.hasFile('mf:$cid'),
        isFalse,
        reason: 'the manifest shares the payload reachability lifetime',
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
      expect(await storage.hasFile(item.contentId!), isFalse);
      expect(await storage.hasFile('mf:${item.contentId}'), isFalse);
      final all = await service.listItems(includeDeleted: true);
      expect(all.single.deleted, isTrue);
      final raw = await storage.getSetting('cloud.index.v1');
      final rows = jsonDecode(raw!) as List;
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

  test('physical delete preserves a cid shared by another live item', () async {
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
    await service.deleteItem(second.id);
    expect(await storage.hasFile(first.contentId!), isFalse);

    await service.close();
    await storage.close();
  });
}
