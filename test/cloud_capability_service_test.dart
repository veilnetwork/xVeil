import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/cloud.dart';
import 'package:xveil/domain/cloud_capability.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/state/cloud_capability_service.dart';

import 'support/fake_hv_container.dart';

class _Random implements Random {
  int value = 1;
  @override
  bool nextBool() => nextInt(2) == 1;
  @override
  double nextDouble() => nextInt(1 << 24) / (1 << 24);
  @override
  int nextInt(int max) {
    value = (value * 1664525 + 1013904223) & 0x7fffffff;
    return value % max;
  }
}

class _Endpoint implements CloudCapabilityEndpointPort {
  _Endpoint(
    this.servicePublicKey,
    this.appId,
    this.endpointId, {
    required this.providerSlot,
    this.closeGate,
    required this.send,
  });
  @override
  final Uint8List servicePublicKey;
  @override
  final Uint8List appId;
  @override
  final int endpointId;
  final int providerSlot;
  final Completer<void>? closeGate;
  final Future<void> Function({
    required Uint8List servicePublicKey,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List data,
  })
  send;
  final controller = StreamController<Uint8List>.broadcast();
  bool closed = false;
  int sentCount = 0;
  @override
  Stream<Uint8List> get messages => controller.stream;
  @override
  Future<void> sendAnonymous({
    required Uint8List servicePublicKey,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List data,
  }) {
    sentCount++;
    return send(
      servicePublicKey: servicePublicKey,
      targetAppId: targetAppId,
      targetEndpointId: targetEndpointId,
      data: data,
    );
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await closeGate?.future;
    await controller.close();
  }
}

class _Network implements CloudCapabilityNetworkPort {
  final endpoints = <_Endpoint>[];
  final sent = <Uint8List>[];
  Completer<void>? nextCloseGate;

  @override
  Future<CloudCapabilityEndpointPort> host({
    required Uint8List identitySeed,
    required String alias,
    required int endpointId,
    required int providerSlot,
    bool transient = false,
  }) async {
    final serviceKey = Uint8List.fromList(
      crypto.sha256.convert(identitySeed).bytes,
    );
    final appId = Uint8List.fromList(
      crypto.sha256.convert(utf8.encode(alias)).bytes,
    );
    identitySeed.fillRange(0, identitySeed.length, 0);
    final endpoint = _Endpoint(
      serviceKey,
      appId,
      endpointId,
      providerSlot: providerSlot,
      closeGate: nextCloseGate,
      send: _sendAnonymous,
    );
    nextCloseGate = null;
    endpoints.add(endpoint);
    return endpoint;
  }

  Future<void> _sendAnonymous({
    required Uint8List servicePublicKey,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List data,
  }) async {
    sent.add(Uint8List.fromList(data));
    final target = endpoints.where(
      (endpoint) =>
          !endpoint.closed &&
          _same(endpoint.servicePublicKey, servicePublicKey) &&
          _same(endpoint.appId, targetAppId) &&
          endpoint.endpointId == targetEndpointId,
    );
    if (target.isNotEmpty) {
      scheduleMicrotask(
        () => target.first.controller.add(Uint8List.fromList(data)),
      );
    }
  }
}

class _SyncBackend {
  final rows = <DeviceSyncRecord>[];
  final members = <String, NodeId>{};
  final changes = StreamController<void>.broadcast();
}

class _SyncPort implements CloudCapabilitySyncPort {
  _SyncPort(this.backend, int author)
    : _author = NodeId.fromHex(author.toRadixString(16).padLeft(64, '0')) {
    backend.members[_author.hex] = _author;
  }
  final _SyncBackend backend;
  final NodeId _author;
  @override
  NodeId get selfId => _author;
  @override
  Stream<void> get changes => backend.changes.stream;
  @override
  Future<List<NodeId>> members() async => backend.members.values.toList();
  @override
  Future<List<DeviceSyncRecord>> records() async => [...backend.rows];
  @override
  Future<bool> post(DeviceSyncEvent event) async {
    backend.rows.add((event: event, author: _author));
    backend.changes.add(null);
    return true;
  }

  @override
  Future<void> close() async {}
}

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

Uint8List _request(
  CloudCapability capability, {
  required Uint8List returnService,
  required Uint8List returnApp,
  int piece = 0,
  int chunk = 0,
}) {
  final nonce = Uint8List.fromList(List.generate(16, (i) => i + 1));
  final mac = CloudCapabilityCodec.requestMac(
    capability: capability,
    returnServicePublicKey: returnService,
    returnAppId: returnApp,
    returnEndpointId: 41,
    pieceIndex: piece,
    chunkIndex: chunk,
    requestNonce: nonce,
  );
  final wire = Uint8List(158)..setAll(0, utf8.encode('XCR1'));
  wire.setAll(4, capability.shareId);
  wire.setAll(36, returnService);
  wire.setAll(68, returnApp);
  final data = ByteData.sublistView(wire);
  data.setUint16(100, 41, Endian.big);
  data.setUint32(102, piece, Endian.big);
  data.setUint32(106, chunk, Endian.big);
  wire.setAll(110, nonce);
  wire.setAll(126, mac);
  return wire;
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test(
    'owner devices converge active alias and revoke through device log',
    () async {
      final backend = _SyncBackend();
      final ownerA = FakeHvContainer();
      final storageA = ownerA.storage();
      await storageA.open(password: 'a', createIfMissing: true);
      final bytes = Uint8List.fromList(List.generate(128, (i) => i));
      final manifest = ContentManifest.fromBytes('sync.bin', bytes);
      await storageA.storeFile(manifest.contentId, bytes);
      await storageA.storeFile(
        'mf:${manifest.contentId}',
        Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
      );
      final networkA = _Network();
      final serviceA = CloudCapabilityService(
        storageA,
        networkA,
        sync: _SyncPort(backend, 1),
        now: () => DateTime(2030),
        random: _Random(),
      );
      final share = await serviceA.createShare(
        CloudItem(
          id: 'sync-item',
          kind: CloudItemKind.file,
          name: manifest.name,
          contentId: manifest.contentId,
          size: bytes.length,
          createdAtMs: 1,
          modifiedAtMs: 1,
          revision: 1,
          deleted: false,
        ),
      );
      expect(backend.rows.single.event.kind, DeviceSyncKind.cloudCapability);
      expect(backend.rows.single.event.toBody(), isNot(contains('nodeId')));

      final ownerB = FakeHvContainer();
      final storageB = ownerB.storage();
      await storageB.open(password: 'b', createIfMissing: true);
      final networkB = _Network();
      final serviceB = CloudCapabilityService(
        storageB,
        networkB,
        sync: _SyncPort(backend, 2),
        now: () => DateTime(2030),
      );
      await serviceB.start();
      expect((await serviceB.listShares()).single.link, share.link);
      expect(networkB.endpoints.single.closed, isFalse);
      expect(networkA.endpoints.single.providerSlot, 0);
      expect(networkB.endpoints.single.providerSlot, 1);
      expect(
        networkB.endpoints.single.servicePublicKey,
        networkA.endpoints.single.servicePublicKey,
      );
      expect(networkB.endpoints.single.appId, networkA.endpoints.single.appId);

      final earlier = NodeId.fromHex('0'.padLeft(64, '0'));
      backend.members[earlier.hex] = earlier;
      backend.changes.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(networkA.endpoints, hasLength(2));
      expect(networkA.endpoints.first.closed, isTrue);
      expect(networkA.endpoints.last.providerSlot, 1);
      expect(networkB.endpoints, hasLength(2));
      expect(networkB.endpoints.first.closed, isTrue);
      expect(networkB.endpoints.last.providerSlot, 2);

      for (var id = 3; id <= 9; id++) {
        final member = NodeId.fromHex(id.toRadixString(16).padLeft(64, '0'));
        backend.members[member.hex] = member;
      }
      final overflowContainer = FakeHvContainer();
      final overflowStorage = overflowContainer.storage();
      await overflowStorage.open(password: 'c', createIfMissing: true);
      final overflowNetwork = _Network();
      final overflowService = CloudCapabilityService(
        overflowStorage,
        overflowNetwork,
        sync: _SyncPort(backend, 9),
        now: () => DateTime(2030),
      );
      await overflowService.start();
      expect((await overflowService.listShares()).single.link, share.link);
      expect(
        overflowNetwork.endpoints,
        isEmpty,
        reason: 'devices outside the fixed eight slots must not publish',
      );
      await overflowService.close();
      await overflowStorage.close();

      expect(await serviceA.revoke(share.shareId), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(await serviceB.listShares(), isEmpty);
      expect(networkB.endpoints.every((endpoint) => endpoint.closed), isTrue);

      await serviceA.close();
      await serviceB.close();
      await storageA.close();
      await storageB.close();
      await backend.changes.close();
    },
  );

  test(
    'encrypted registry rehosts, serves authorized chunk, and revoke is silent',
    () async {
      final container = FakeHvContainer();
      final storage = container.storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final bytes = Uint8List.fromList(
        List.generate(5000, (i) => (i * 17) & 0xff),
      );
      final manifest = ContentManifest.fromBytes(
        'shared.bin',
        bytes,
        pieceSize: 4096,
      );
      await storage.storeFile(manifest.contentId, bytes, name: manifest.name);
      await storage.storeFile(
        'mf:${manifest.contentId}',
        Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
      );
      final item = CloudItem(
        id: 'item-1',
        kind: CloudItemKind.file,
        name: manifest.name,
        contentId: manifest.contentId,
        size: bytes.length,
        mime: 'application/octet-stream',
        createdAtMs: 1,
        modifiedAtMs: 2,
        revision: 1,
        deleted: false,
      );
      final network = _Network();
      final first = CloudCapabilityService(
        storage,
        network,
        now: () => DateTime(2030),
        random: _Random(),
      );
      final share = await first.createShare(item);
      final capability = await CloudCapabilityCodec.parse(share.link);
      expect(share.link, isNot(contains('nodeId')));
      expect(network.endpoints, hasLength(1));

      final returnService = Uint8List.fromList(List.filled(32, 7));
      final returnApp = Uint8List.fromList(List.filled(32, 8));
      network.endpoints.last.controller.add(
        _request(
          capability,
          returnService: returnService,
          returnApp: returnApp,
        ),
      );
      await _settle();
      expect(network.sent, hasLength(1));
      expect(network.endpoints.first.sentCount, 1);
      final response = network.sent.single;
      expect(utf8.decode(response.sublist(0, 4)), 'XCP1');
      final sealedLength = ByteData.sublistView(
        response,
      ).getUint16(60, Endian.big);
      final clear = await CloudCapabilityCodec.openChunk(
        capability: capability,
        pieceIndex: 0,
        chunkIndex: 0,
        sealed: Uint8List.fromList(response.sublist(62, 62 + sealedLength)),
      );
      expect(clear, Uint8List.sublistView(bytes, 0, 2048));

      final recipientContainer = FakeHvContainer();
      final recipientStorage = recipientContainer.storage();
      await recipientStorage.open(password: 'recipient', createIfMissing: true);
      final recipient = CloudCapabilityService(
        recipientStorage,
        network,
        now: () => DateTime(2030),
        random: _Random(),
      );
      final downloaded = await recipient.download(share.link);
      expect(downloaded.manifest.contentId, manifest.contentId);
      expect(await recipientStorage.loadFile(manifest.contentId), bytes);
      expect(
        network.endpoints[1].sentCount,
        greaterThan(0),
        reason: 'the transient return endpoint must own every request source',
      );
      await recipient.close();
      await recipientStorage.close();

      await first.close();
      final second = CloudCapabilityService(
        storage,
        network,
        now: () => DateTime(2030),
      );
      await second.start();
      expect((await second.listShares()).single.link, share.link);
      expect(network.endpoints, hasLength(3));

      final before = network.sent.length;
      expect(await second.revoke(share.shareId), isTrue);
      expect(network.endpoints.last.closed, isTrue);
      expect(network.sent, hasLength(before));
      expect(await second.listShares(), isEmpty);
      expect(
        jsonDecode(
          utf8.decode(
            (await storage.loadFile('cloud.capabilities.registry.v2'))!,
          ),
        ),
        isEmpty,
      );

      await second.close();
      await storage.close();
    },
  );

  test(
    'revoke does not wait for descriptor withdrawal or reuse its slot',
    () async {
      final container = FakeHvContainer();
      final storage = container.storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final network = _Network();
      final closeGate = Completer<void>();
      network.nextCloseGate = closeGate;
      final service = CloudCapabilityService(
        storage,
        network,
        random: _Random(),
      );

      Future<CloudPublicShare> create(String id, int salt) async {
        final bytes = Uint8List.fromList(List.generate(32, (i) => i + salt));
        final manifest = ContentManifest.fromBytes('$id.bin', bytes);
        await storage.storeFile(manifest.contentId, bytes);
        await storage.storeFile(
          'mf:${manifest.contentId}',
          Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
        );
        return service.createShare(
          CloudItem(
            id: id,
            kind: CloudItemKind.file,
            name: manifest.name,
            contentId: manifest.contentId,
            size: bytes.length,
            createdAtMs: salt,
            modifiedAtMs: salt,
            revision: 1,
            deleted: false,
          ),
        );
      }

      final first = await create('first', 1);
      expect(await service.revoke(first.shareId), isTrue);
      expect(closeGate.isCompleted, isFalse);
      await create('second', 2);
      expect(network.endpoints.map((endpoint) => endpoint.endpointId), [
        40,
        41,
      ]);

      closeGate.complete();
      await service.close();
      await storage.close();
    },
  );

  test(
    'all six advertised active shares persist beyond settings capacity',
    () async {
      final container = FakeHvContainer();
      final storage = container.storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final network = _Network();
      final service = CloudCapabilityService(
        storage,
        network,
        random: _Random(),
      );

      for (
        var index = 0;
        index < CloudCapabilityService.maxActiveShares;
        index++
      ) {
        final bytes = Uint8List.fromList(
          List.generate(64 + index, (offset) => index * 17 + offset),
        );
        final manifest = ContentManifest.fromBytes('six-$index.bin', bytes);
        await storage.storeFile(manifest.contentId, bytes);
        await storage.storeFile(
          'mf:${manifest.contentId}',
          Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
        );
        await service.createShare(
          CloudItem(
            id: 'six-$index',
            kind: CloudItemKind.file,
            name: manifest.name,
            contentId: manifest.contentId,
            size: bytes.length,
            createdAtMs: index,
            modifiedAtMs: index,
            revision: 1,
            deleted: false,
          ),
        );
      }
      expect(await service.listShares(), hasLength(6));
      expect(network.endpoints, hasLength(6));

      await service.close();
      final reopened = CloudCapabilityService(storage, network);
      await reopened.start();
      expect(await reopened.listShares(), hasLength(6));
      expect(
        network.endpoints.where((endpoint) => !endpoint.closed),
        hasLength(6),
      );

      await reopened.close();
      await storage.close();
    },
  );

  test('malformed and wrong-MAC probes are dropped without response', () async {
    final container = FakeHvContainer();
    final storage = container.storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final bytes = Uint8List.fromList(List.generate(32, (i) => i));
    final manifest = ContentManifest.fromBytes('small.bin', bytes);
    await storage.storeFile(manifest.contentId, bytes);
    await storage.storeFile(
      'mf:${manifest.contentId}',
      Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
    );
    final network = _Network();
    final service = CloudCapabilityService(storage, network, random: _Random());
    final share = await service.createShare(
      CloudItem(
        id: 'item-2',
        kind: CloudItemKind.file,
        name: manifest.name,
        contentId: manifest.contentId,
        size: bytes.length,
        createdAtMs: 1,
        modifiedAtMs: 1,
        revision: 1,
        deleted: false,
      ),
    );
    final capability = await CloudCapabilityCodec.parse(share.link);
    final secondBytes = Uint8List.fromList(List.generate(33, (i) => i + 1));
    final secondManifest = ContentManifest.fromBytes('second.bin', secondBytes);
    await storage.storeFile(secondManifest.contentId, secondBytes);
    await storage.storeFile(
      'mf:${secondManifest.contentId}',
      Uint8List.fromList(utf8.encode(jsonEncode(secondManifest.toJson()))),
    );
    await service.createShare(
      CloudItem(
        id: 'item-3',
        kind: CloudItemKind.file,
        name: secondManifest.name,
        contentId: secondManifest.contentId,
        size: secondBytes.length,
        createdAtMs: 2,
        modifiedAtMs: 2,
        revision: 1,
        deleted: false,
      ),
    );
    expect(network.endpoints.map((endpoint) => endpoint.endpointId), [40, 41]);
    final endpoint = network.endpoints.first;
    endpoint.controller.add(Uint8List.fromList([1, 2, 3]));
    final forged = _request(
      capability,
      returnService: Uint8List.fromList(List.filled(32, 1)),
      returnApp: Uint8List.fromList(List.filled(32, 2)),
    )..[157] ^= 1;
    endpoint.controller.add(forged);
    await _settle();
    expect(network.sent, isEmpty);
    await service.close();
    await storage.close();
  });

  test(
    'folder share hosts, serves a listing+file, then revokes silently',
    () async {
      // Owner and downloader share one network so anonymous datagrams route.
      final network = _Network();
      final ownerBox = FakeHvContainer();
      final ownerStorage = ownerBox.storage();
      await ownerStorage.open(password: 'o', createIfMissing: true);
      final entries = <CloudFolderListingEntry>[];
      final plaintext = <String, Uint8List>{};
      for (var i = 0; i < 2; i++) {
        final bytes = Uint8List.fromList(
          List.generate(500 + i * 120, (j) => (j * (i + 5)) & 0xff),
        );
        final manifest = ContentManifest.fromBytes(
          'doc$i.bin',
          bytes,
          pieceSize: 256,
        );
        await ownerStorage.storeFile(manifest.contentId, bytes);
        await ownerStorage.storeFile(
          'mf:${manifest.contentId}',
          Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
        );
        plaintext[manifest.contentId] = bytes;
        entries.add(
          CloudFolderListingEntry.file(name: 'doc$i.bin', manifest: manifest),
        );
      }
      final owner = CloudCapabilityService(
        ownerStorage,
        network,
        now: () => DateTime(2030),
        random: _Random(),
        folderClientTimeout: const Duration(milliseconds: 400),
      );
      final share = await owner.createFolderShare(
        folderId: 'folder-1',
        folderName: 'Проекты',
        entries: [
          entries.first,
          CloudFolderListingEntry.folder(
            name: 'вложенная',
            entries: [entries[1]],
          ),
        ],
      );
      expect(share.link, startsWith('xveil://cloud/v1#'));
      expect(owner.listFolderShares().single.folderId, 'folder-1');

      final downloaderBox = FakeHvContainer();
      final downloaderStorage = downloaderBox.storage();
      await downloaderStorage.open(password: 'd', createIfMissing: true);
      final downloader = CloudCapabilityService(
        downloaderStorage,
        network,
        now: () => DateTime(2030),
        random: _Random()..value = 99,
        folderClientTimeout: const Duration(milliseconds: 400),
      );

      final listing = await downloader.fetchFolderListing(share.link);
      expect(listing.name, 'Проекты');
      // One top-level file + the subfolder node + its one nested file.
      expect(listing.totalEntries, 3);
      final nested = listing.entries
          .firstWhere((e) => e.isFolder)
          .entries!
          .single;

      final capability = await downloader.downloadFolderFile(
        share.link,
        nested,
      );
      expect(
        await downloaderStorage.hasFile(capability.manifest.contentId),
        isTrue,
      );
      final fetched = await downloaderStorage.loadFile(
        capability.manifest.contentId,
      );
      expect(fetched, plaintext[capability.manifest.contentId]);

      // Revoke: the endpoint stops accepting, so a new open goes silent.
      expect(await owner.revokeFolderShare(share.shareId), isTrue);
      expect(owner.listFolderShares(), isEmpty);
      await _settle();
      await expectLater(
        downloader.fetchFolderListing(share.link),
        throwsA(anything),
      );

      await downloader.close();
      await owner.close();
      await ownerStorage.close();
      await downloaderStorage.close();
    },
  );

  test(
    'a removed file stops downloading after the share is refreshed',
    () async {
      final network = _Network();
      final ownerBox = FakeHvContainer();
      final ownerStorage = ownerBox.storage();
      await ownerStorage.open(password: 'o', createIfMissing: true);
      final entries = <CloudFolderListingEntry>[];
      for (var i = 0; i < 2; i++) {
        final bytes = Uint8List.fromList(
          List.generate(400 + i * 90, (j) => (j * (i + 2)) & 0xff),
        );
        final manifest = ContentManifest.fromBytes(
          'r$i.bin',
          bytes,
          pieceSize: 256,
        );
        await ownerStorage.storeFile(manifest.contentId, bytes);
        await ownerStorage.storeFile(
          'mf:${manifest.contentId}',
          Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
        );
        entries.add(
          CloudFolderListingEntry.file(name: 'r$i.bin', manifest: manifest),
        );
      }
      final owner = CloudCapabilityService(
        ownerStorage,
        network,
        now: () => DateTime(2030),
        random: _Random(),
        folderClientTimeout: const Duration(milliseconds: 400),
      );
      final share = await owner.createFolderShare(
        folderId: 'folder-2',
        folderName: 'Refresh',
        entries: entries,
      );
      final downloaderBox = FakeHvContainer();
      final downloaderStorage = downloaderBox.storage();
      await downloaderStorage.open(password: 'd', createIfMissing: true);
      final downloader = CloudCapabilityService(
        downloaderStorage,
        network,
        now: () => DateTime(2030),
        random: _Random()..value = 7,
        folderClientTimeout: const Duration(milliseconds: 400),
      );

      // Republish with only the first file (revision bumped to 2).
      expect(
        await owner.refreshFolderShare(
          share.shareId,
          folderName: 'Refresh',
          entries: [entries.first],
        ),
        isTrue,
      );
      expect(owner.listFolderShares().single.listingRevision, 2);
      final listing = await downloader.fetchFolderListing(share.link);
      expect(listing.revision, 2);
      expect(listing.totalEntries, 1);

      // The removed file is gone from the listing and no longer served.
      await expectLater(
        downloader.downloadFolderFile(share.link, entries[1]),
        throwsA(anything),
      );
      // The retained file still downloads.
      final capability = await downloader.downloadFolderFile(
        share.link,
        entries.first,
      );
      expect(
        await downloaderStorage.hasFile(capability.manifest.contentId),
        isTrue,
      );

      await downloader.close();
      await owner.close();
      await ownerStorage.close();
      await downloaderStorage.close();
    },
  );
}
