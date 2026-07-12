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
    this.closeGate,
  });
  @override
  final Uint8List servicePublicKey;
  @override
  final Uint8List appId;
  @override
  final int endpointId;
  final Completer<void>? closeGate;
  final controller = StreamController<Uint8List>.broadcast();
  bool closed = false;
  @override
  Stream<Uint8List> get messages => controller.stream;
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
      closeGate: nextCloseGate,
    );
    nextCloseGate = null;
    endpoints.add(endpoint);
    return endpoint;
  }

  @override
  Future<void> sendAnonymous({
    required Uint8List servicePublicKey,
    required Uint8List targetAppId,
    required int targetEndpointId,
    required Uint8List srcAppId,
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
  final changes = StreamController<void>.broadcast();
}

class _SyncPort implements CloudCapabilitySyncPort {
  _SyncPort(this.backend, int author)
    : _author = NodeId.fromHex(author.toRadixString(16).padLeft(64, '0'));
  final _SyncBackend backend;
  final NodeId _author;
  @override
  Stream<void> get changes => backend.changes.stream;
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
      expect(
        networkB.endpoints.single.servicePublicKey,
        networkA.endpoints.single.servicePublicKey,
      );
      expect(networkB.endpoints.single.appId, networkA.endpoints.single.appId);

      expect(await serviceA.revoke(share.shareId), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(await serviceB.listShares(), isEmpty);
      expect(networkB.endpoints.single.closed, isTrue);

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
        jsonDecode((await storage.getSetting('cloud.capabilities.v1'))!),
        isEmpty,
      );

      await second.close();
      await storage.close();
    },
  );

  test('revoke does not wait for descriptor withdrawal or reuse its slot', () async {
    final container = FakeHvContainer();
    final storage = container.storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final network = _Network();
    final closeGate = Completer<void>();
    network.nextCloseGate = closeGate;
    final service = CloudCapabilityService(storage, network, random: _Random());

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
    expect(network.endpoints.map((endpoint) => endpoint.endpointId), [40, 41]);

    closeGate.complete();
    await service.close();
    await storage.close();
  });

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
}
