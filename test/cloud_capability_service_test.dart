import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/cloud.dart';
import 'package:xveil/domain/cloud_capability.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/state/cloud_capability_service.dart';

import 'support/fake_hv_container.dart';

/// Fails the capability EVENT-log write on demand. The registry and every
/// other file keep working, which is the shape that matters: the two are
/// separate writes and only one of them is what a restart trusts.
class _EventsWriteFails extends HiddenVolumeStorage {
  _EventsWriteFails(super.opener, {super.keysOpener});

  static const eventsFile = 'cloud.capability.events.v2';
  static const registryFile = 'cloud.capabilities.registry.v2';

  bool fail = false;

  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) {
    if (fail && fileId == eventsFile) {
      throw StateError('no space left on device');
    }
    return super.storeFile(fileId, bytes, name: name);
  }
}

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

  /// Holds `host` open, standing in for the seconds a real onion registration
  /// takes — the window in which a close can land.
  Completer<void>? hostGate;

  /// Completes when `host` is first entered while [hostGate] is set, so a test
  /// can wait for the call to be INSIDE rather than guess with a delay.
  Completer<void>? enteredHost;

  @override
  Future<CloudCapabilityEndpointPort> host({
    required Uint8List identitySeed,
    required String alias,
    required int endpointId,
    required int providerSlot,
    bool transient = false,
    int extraProviderSlots = 0,
  }) async {
    final serviceKey = Uint8List.fromList(
      crypto.sha256.convert(identitySeed).bytes,
    );
    final appId = Uint8List.fromList(
      crypto.sha256.convert(utf8.encode(alias)).bytes,
    );
    identitySeed.fillRange(0, identitySeed.length, 0);
    final gate = hostGate;
    if (gate != null) {
      final entered = enteredHost;
      if (entered != null && !entered.isCompleted) entered.complete();
      await gate.future;
    }
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

  @override
  Future<Uint8List> capabilityAppId({
    required String alias,
    required int endpointId,
  }) async =>
      Uint8List.fromList(crypto.sha256.convert(utf8.encode(alias)).bytes);

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
  group('cloudProviderSlotFor', () {
    // Every device of an identity derives the SAME member/capability host seed
    // and alias, so the slot is the ONLY thing keeping two of them from
    // registering as one provider. Each device computes its own with no
    // coordination, which only works while the rule stays a pure function of
    // the device set — hence these cases.
    NodeId id(int b) => NodeId(Uint8List.fromList(List.filled(32, b)));

    test('a lone device takes slot 0', () {
      expect(cloudProviderSlotFor(id(7), const []), 0);
    });

    test('slot is the position in hex order, not join order', () {
      final low = id(1);
      final mid = id(2);
      final high = id(3);
      // Same set, three different orderings of the member list: a device must
      // land on the same slot every time, or two devices disagree about who
      // owns which and collide.
      expect(cloudProviderSlotFor(mid, [low, high]), 1);
      expect(cloudProviderSlotFor(mid, [high, low]), 1);
      expect(cloudProviderSlotFor(low, [high, mid]), 0);
      expect(cloudProviderSlotFor(high, [mid, low]), 2);
    });

    test('every device of a group lands on a distinct slot', () {
      final devices = [for (var i = 0; i < 5; i++) id(i)];
      final slots = {
        for (final self in devices) cloudProviderSlotFor(self, devices),
      };
      expect(slots, {0, 1, 2, 3, 4});
    });

    test('self listed among the members does not shift the slot', () {
      final self = id(2);
      // The device log can echo this device back as a member; deduplicating is
      // what keeps the index from sliding by one against its peers.
      expect(cloudProviderSlotFor(self, [id(1), self, id(3)]), 1);
      expect(cloudProviderSlotFor(self, [id(1), id(3)]), 1);
    });

    test('past the device limit it fails closed instead of colliding', () {
      final devices = [
        for (var i = 0; i < kCloudProviderSlotLimit + 1; i++) id(i),
      ];
      // The last device would need slot 8, which does not exist: refusing to
      // host beats silently registering as somebody else's provider.
      expect(
        () => cloudProviderSlotFor(devices.last, devices),
        throwsStateError,
      );
      expect(cloudProviderSlotFor(devices.first, devices), 0);
    });
  });

  /// `close` has to be a BARRIER, not a flag.
  ///
  /// The provider closes the old service on an identity switch, and `close`
  /// knew only about registered shares and the sync. A folder listing or a
  /// download already in flight kept its own transient return endpoint,
  /// verified its pieces and wrote them — plus the manifest — into a storage
  /// the app had stopped showing. Only the next `adoptCapability` noticed,
  /// leaving orphan content behind (report22 XV-LIFE1).
  test('a closed cloud service starts no new anonymous client', () async {
    final container = FakeHvContainer();
    final storage = container.storage();
    await storage.open(password: 'a', createIfMissing: true);
    addTearDown(storage.close);

    final service = CloudCapabilityService(
      storage,
      _Network(),
      sync: _SyncPort(_SyncBackend(), 1),
      now: () => DateTime(2030),
      random: _Random(),
    );

    // Vacuity: a link this service cannot parse must fail for THAT reason
    // while it is open, or the refusal below proves only that the link is
    // bad rather than that the service is closed.
    await expectLater(
      service.fetchFolderListing('not-a-link'),
      throwsA(
        isA<Object>().having(
          (e) => e.toString(),
          'reason',
          isNot(contains('has been closed')),
        ),
      ),
    );

    await service.close();

    await expectLater(
      service.fetchFolderListing('not-a-link'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('has been closed'),
        ),
      ),
      reason: 'a closed service still opened an anonymous return endpoint',
    );
    await expectLater(
      service.download('not-a-link'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('has been closed'),
        ),
      ),
      reason: 'a closed service still fetched and committed pieces',
    );
  });

  test('an EXPIRED bearer link is refused before any network work', () async {
    // Found by break-checking: removing the expiry check failed NOTHING in the
    // suite. A bearer link is the whole authorisation — it names no recipient
    // — so the moment it outlives its window it must stop working, and the
    // refusal has to come before the download does anything observable.
    final backend = _SyncBackend();
    final owner = FakeHvContainer();
    final storage = owner.storage();
    await storage.open(password: 'a', createIfMissing: true);
    final bytes = Uint8List.fromList(List.generate(64, (i) => i));
    final manifest = ContentManifest.fromBytes('expiring.bin', bytes);
    await storage.storeFile(manifest.contentId, bytes);
    await storage.storeFile(
      'mf:${manifest.contentId}',
      Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
    );
    final service = CloudCapabilityService(
      storage,
      _Network(),
      sync: _SyncPort(backend, 1),
      now: () => DateTime(2030),
      random: _Random(),
    );
    final share = await service.createShare(
      CloudItem(
        id: 'expiring-item',
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

    // A recipient whose clock is past the window. Its store is empty, so a
    // refusal cannot be confused with "already had the bytes".
    final recipientContainer = FakeHvContainer();
    final recipientStorage = recipientContainer.storage();
    await recipientStorage.open(password: 'b', createIfMissing: true);
    final recipientNetwork = _Network();
    final recipient = CloudCapabilityService(
      recipientStorage,
      recipientNetwork,
      sync: _SyncPort(_SyncBackend(), 2),
      now: () => DateTime(2040),
    );

    await expectLater(
      recipient.download(share.link),
      throwsA(isA<StateError>()),
    );
    expect(
      await recipientStorage.hasFile(manifest.contentId),
      isFalse,
      reason: 'nothing may be committed for a link that no longer authorises',
    );
    expect(
      recipientNetwork.endpoints,
      isEmpty,
      reason: 'and it must be refused before any endpoint is published',
    );
  });

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

  /// The manifest is the only integrity anchor a downloader has: the bytes
  /// arrive from a host it does not trust, and nothing downstream re-checks
  /// them — there is no whole-file hash after the pieces are stored. So a host
  /// that serves the right LENGTH of wrong bytes must be refused per piece, or
  /// the recipient stores attacker content under a legitimate content id.
  test(
    'a host serving bytes that do not match the manifest is refused',
    () async {
      final container = FakeHvContainer();
      final storage = container.storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final honest = Uint8List.fromList(
        List.generate(5000, (i) => (i * 17) & 0xff),
      );
      final manifest = ContentManifest.fromBytes(
        'shared.bin',
        honest,
        pieceSize: 4096,
      );
      await storage.storeFile(manifest.contentId, honest, name: manifest.name);
      await storage.storeFile(
        'mf:${manifest.contentId}',
        Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
      );
      final item = CloudItem(
        id: 'item-tamper',
        kind: CloudItemKind.file,
        name: manifest.name,
        contentId: manifest.contentId,
        size: honest.length,
        mime: 'application/octet-stream',
        createdAtMs: 1,
        modifiedAtMs: 2,
        revision: 1,
        deleted: false,
      );
      final network = _Network();
      final host = CloudCapabilityService(
        storage,
        network,
        now: () => DateTime(2030),
        random: _Random(),
      );
      final share = await host.createShare(item);

      // Swap the stored bytes for a same-length forgery AFTER the manifest is
      // published, so the host serves content the manifest does not describe.
      final forged = Uint8List.fromList(
        List.generate(5000, (i) => (i * 31) & 0xff),
      );
      await storage.storeFile(manifest.contentId, forged, name: manifest.name);

      final recipientContainer = FakeHvContainer();
      final recipientStorage = recipientContainer.storage();
      await recipientStorage.open(password: 'recipient', createIfMissing: true);
      final recipient = CloudCapabilityService(
        recipientStorage,
        network,
        now: () => DateTime(2030),
        random: _Random(),
      );
      await expectLater(recipient.download(share.link), throwsStateError);
      expect(
        await recipientStorage.loadFile(manifest.contentId),
        isNull,
        reason:
            'nothing may be stored under the content id it does not hash to',
      );
      await recipient.close();
      await recipientStorage.close();
      await host.close();
      await storage.close();
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
      expect(
        clear,
        Uint8List.sublistView(bytes, 0, CloudCapabilityCodec.publicChunkBytes),
      );

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

  test('a revoked folder share stays revoked across a restart', () async {
    // The registry says what was last written; the event log says what was
    // revoked. The folder path used to tear the share out of memory and
    // save the registry AFTER — so a registry write that failed left the
    // row on disk with nothing recording the withdrawal, and the next
    // launch re-hosted the bearer link for the rest of its seven-day life
    // (report22 XV-CAP-REVOKE). A full container is enough to trigger it.
    final network = _Network();
    final box = FakeHvContainer();
    final storage = box.storage();
    await storage.open(password: 'o', createIfMissing: true);
    final bytes = Uint8List.fromList(List.generate(300, (i) => i & 0xff));
    final manifest = ContentManifest.fromBytes(
      'doc.bin',
      bytes,
      pieceSize: 256,
    );
    await storage.storeFile(manifest.contentId, bytes);
    await storage.storeFile(
      'mf:${manifest.contentId}',
      Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
    );

    final owner = CloudCapabilityService(
      storage,
      network,
      now: () => DateTime(2030),
    );
    await owner.start();
    final share = await owner.createFolderShare(
      folderId: 'folder-revoked',
      folderName: 'Folder',
      entries: [
        CloudFolderListingEntry.file(name: 'doc.bin', manifest: manifest),
      ],
    );
    expect(owner.listFolderShares(), hasLength(1), reason: 'premise');
    // What the registry holds while the share is still active. The failure
    // being modelled is the revoke's registry write not landing, so this is
    // what is on disk when the app comes back.
    final activeRegistry = await storage.loadFile(
      'cloud.folder.capabilities.registry.v1',
    );
    expect(activeRegistry, isNotNull, reason: 'premise: a row was written');

    expect(await owner.revokeFolderShare(share.shareId), isTrue);
    await owner.close();

    // The revoke's registry write is undone — a full container, a crash
    // between the two writes. The tombstone in the event log is the only
    // thing left saying this share was withdrawn.
    await storage.storeFile(
      'cloud.folder.capabilities.registry.v1',
      activeRegistry!,
    );

    final second = CloudCapabilityService(
      storage,
      network,
      now: () => DateTime(2030),
    );
    await second.start();
    expect(
      second.listFolderShares(),
      isEmpty,
      reason:
          'a revoked folder share was hosted again after a restart, so '
          'the bearer link the person withdrew is serving',
    );
    await second.close();
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

  group('an unsealable listing (audit XV-18)', () {
    // Structurally impeccable — exactly the 512-entry cap, every name inside
    // its own limit — and far past the 256 KiB ceiling, which lives on the
    // CIPHERTEXT and so is invisible to every check that runs before the seal.
    List<CloudFolderListingEntry> bloated(ContentManifest manifest) => [
      for (var i = 0; i < CloudFolderListing.maxTotalEntries; i++)
        CloudFolderListingEntry.file(
          name: '${'w' * 500}$i',
          manifest: manifest,
        ),
    ];

    Future<
      ({
        _Network network,
        FakeHvContainer box,
        HiddenVolumeStorage storage,
        CloudCapabilityService owner,
        CloudFolderShareInfo share,
        ContentManifest manifest,
        CloudFolderListingEntry entry,
      })
    >
    ownerWithShare() async {
      final network = _Network();
      final box = FakeHvContainer();
      final storage = box.storage();
      await storage.open(password: 'o', createIfMissing: true);
      final bytes = Uint8List.fromList(
        List.generate(420, (j) => (j * 7) & 0xff),
      );
      final manifest = ContentManifest.fromBytes(
        'keep.bin',
        bytes,
        pieceSize: 256,
      );
      await storage.storeFile(manifest.contentId, bytes);
      await storage.storeFile(
        'mf:${manifest.contentId}',
        Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
      );
      final entry = CloudFolderListingEntry.file(
        name: 'keep.bin',
        manifest: manifest,
      );
      final owner = CloudCapabilityService(
        storage,
        network,
        now: () => DateTime(2030),
        random: _Random(),
        folderClientTimeout: const Duration(milliseconds: 400),
      );
      final share = await owner.createFolderShare(
        folderId: 'folder-xv18',
        folderName: 'Bloat',
        entries: [entry],
      );
      return (
        network: network,
        box: box,
        storage: storage,
        owner: owner,
        share: share,
        manifest: manifest,
        entry: entry,
      );
    }

    test('the sealed size is checked BEFORE the row is written, and the share '
        'goes on serving the listing it already had', () async {
      final f = await ownerWithShare();
      final downloaderBox = FakeHvContainer();
      final downloaderStorage = downloaderBox.storage();
      await downloaderStorage.open(password: 'd', createIfMissing: true);
      final downloader = CloudCapabilityService(
        downloaderStorage,
        f.network,
        now: () => DateTime(2030),
        random: _Random()..value = 21,
        folderClientTimeout: const Duration(milliseconds: 400),
      );
      expect((await downloader.fetchFolderListing(f.share.link)).revision, 1);

      await expectLater(
        f.owner.refreshFolderShare(
          f.share.shareId,
          folderName: 'Bloat',
          entries: bloated(f.manifest),
        ),
        throwsA(anything),
      );

      // The durable row must not have moved: it used to name revision 2 and a
      // listing whose bytes could never exist, which is what no restart could
      // undo.
      expect(
        f.owner.listFolderShares().single.listingRevision,
        1,
        reason: 'the refused revision was written down anyway',
      );
      // …and the live share must still answer. The refusal used to leave a
      // rejected future in the serving gate, so the host stopped answering the
      // OLD listing too — a share that had been working went silent over a
      // listing it never accepted.
      final still = await downloader.fetchFolderListing(f.share.link);
      expect(still.revision, 1);
      expect(still.totalEntries, 1);

      // And an ordinary republish still works afterwards.
      expect(
        await f.owner.refreshFolderShare(
          f.share.shareId,
          folderName: 'Bloat',
          entries: [f.entry],
        ),
        isTrue,
      );
      expect((await downloader.fetchFolderListing(f.share.link)).revision, 2);

      await downloader.close();
      await f.owner.close();
      await f.storage.close();
      await downloaderStorage.close();
    });

    test('a share left with a stored listing that cannot be sealed is hosted '
        'silent and can be republished', () async {
      final f = await ownerWithShare();
      await f.owner.close();

      // What the old write-then-seal order left on disk. Nothing produces this
      // any more, but a store that already holds it must not be a share that
      // is dead forever: it used to fail to host, which ALSO made
      // refreshFolderShare answer "unknown share" for the rest of time.
      const registryFile = 'cloud.folder.capabilities.registry.v1';
      final rows =
          jsonDecode(utf8.decode((await f.storage.loadFile(registryFile))!))
              as List;
      final row = Map<String, dynamic>.from(rows.single as Map);
      row['lrev'] = 2;
      row['listing'] = CloudFolderListing(
        name: 'Bloat',
        revision: 2,
        entries: bloated(f.manifest),
      ).toJson();
      await f.storage.storeFile(
        registryFile,
        Uint8List.fromList(utf8.encode(jsonEncode([row]))),
        name: 'cloud-capability-metadata',
      );

      final reopened = CloudCapabilityService(
        f.storage,
        f.network,
        now: () => DateTime(2030),
        random: _Random()..value = 33,
        folderClientTimeout: const Duration(milliseconds: 400),
      );
      final downloaderBox = FakeHvContainer();
      final downloaderStorage = downloaderBox.storage();
      await downloaderStorage.open(password: 'd', createIfMissing: true);
      final downloader = CloudCapabilityService(
        downloaderStorage,
        f.network,
        now: () => DateTime(2030),
        random: _Random()..value = 34,
        folderClientTimeout: const Duration(milliseconds: 400),
      );

      expect(
        await reopened.refreshFolderShare(
          f.share.shareId,
          folderName: 'Bloat',
          entries: [f.entry],
        ),
        isTrue,
        reason: 'the share was unrepairable: registered, but never hosted',
      );
      final listing = await downloader.fetchFolderListing(f.share.link);
      expect(listing.revision, 3);
      expect(listing.totalEntries, 1);

      await downloader.close();
      await reopened.close();
      await f.storage.close();
      await downloaderStorage.close();
    });
  });

  /// A close that lands while `start` is re-hosting must not leave a live
  /// endpoint behind.
  ///
  /// `close` sweeps the hosted-share maps exactly once and then sets the flag.
  /// Every registration happens after awaits — a provider slot, an onion
  /// registration — so a `start` already inside `network.host` came back and
  /// wrote its host into a map nobody will read again: a registration that goes
  /// on answering, holds its provider slot, and has no reconcile left to notice
  /// it, because the service is closed.
  ///
  /// The assertion is on the ENDPOINT rather than on the service's maps: the
  /// map is private and, more to the point, an orphan is only harmful because
  /// it stays live on the network.
  test('closing while start re-hosts leaves no endpoint open', () async {
    final backend = _SyncBackend();
    final container = FakeHvContainer();
    final storage = container.storage();
    await storage.open(password: 'a', createIfMissing: true);
    final bytes = Uint8List.fromList(List.generate(64, (i) => i * 3));
    final manifest = ContentManifest.fromBytes('orphan.bin', bytes);
    await storage.storeFile(manifest.contentId, bytes);
    await storage.storeFile(
      'mf:${manifest.contentId}',
      Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
    );

    // A share persisted by one run of the app is what the next run re-hosts.
    final first = CloudCapabilityService(
      storage,
      _Network(),
      sync: _SyncPort(backend, 1),
      now: () => DateTime(2030),
      random: _Random(),
    );
    expect(
      await first.createShare(
        CloudItem(
          id: 'orphan-item',
          kind: CloudItemKind.file,
          name: manifest.name,
          contentId: manifest.contentId,
          size: bytes.length,
          createdAtMs: 1,
          modifiedAtMs: 1,
          revision: 1,
          deleted: false,
        ),
      ),
      isNotNull,
    );
    await first.close();

    final net = _Network();
    final second = CloudCapabilityService(
      storage,
      net,
      sync: _SyncPort(backend, 2),
      now: () => DateTime(2030),
      random: _Random(),
    );
    net.hostGate = Completer<void>();
    net.enteredHost = Completer<void>();
    final starting = second.start();
    await net.enteredHost!.future.timeout(const Duration(seconds: 5));

    // Inside `network.host`, with the row already read and the host about to
    // be registered.
    await second.close();
    net.hostGate!.complete();
    net.hostGate = null;
    await starting.catchError((_) {});

    expect(
      net.endpoints,
      isNotEmpty,
      reason:
          'no re-host was attempted, so this proves nothing — the persisted '
          'share stopped being re-hosted on start and the test needs fixing',
    );
    expect(
      net.endpoints.where((endpoint) => !endpoint.closed),
      isEmpty,
      reason:
          'start finished after close and left a live onion registration: it '
          'keeps answering, keeps its provider slot, and nothing will ever '
          'close it because the service it belongs to is gone',
    );
    await storage.close();
  });

  /// A revoke the person is told succeeded must not come back.
  ///
  /// The registry says what was last written; the EVENT LOG says what was
  /// revoked, and a restart reads the log to decide. Taking the row out first
  /// and recording the tombstone after left a window where the log still held
  /// the old active row — and the write that closed it swallowed its own
  /// error. When it failed, the next start folded the stale row and re-hosted
  /// the capability the person had just withdrawn, for the rest of its
  /// lifetime: seven days by default.
  test('a revoke whose tombstone will not go down is not a revoke', () async {
    final container = FakeHvContainer();
    final storage = _EventsWriteFails(
      container.passwordOpener,
      keysOpener: container.keysOpener,
    );
    await storage.open(password: 'pw', createIfMissing: true);
    final network = _Network();
    final service = CloudCapabilityService(storage, network, random: _Random());

    final bytes = Uint8List.fromList(List.generate(32, (i) => i));
    final manifest = ContentManifest.fromBytes('f.bin', bytes);
    await storage.storeFile(manifest.contentId, bytes);
    await storage.storeFile(
      'mf:${manifest.contentId}',
      Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
    );
    final share = await service.createShare(
      CloudItem(
        id: 'f',
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
    expect(await service.listShares(), hasLength(1));

    storage.fail = true;
    expect(
      await service.revoke(share.shareId),
      isFalse,
      reason: 'no tombstone on disk, no revoke to report',
    );
    expect(
      await service.listShares(),
      hasLength(1),
      reason: 'a refused revoke leaves the share whole, not half taken apart',
    );
    expect(
      jsonDecode(
        utf8.decode((await storage.loadFile(_EventsWriteFails.registryFile))!),
      ),
      hasLength(1),
      reason: 'the registry still holds the row it was never told to drop',
    );

    // The container comes back and the same call now goes through.
    storage.fail = false;
    expect(await service.revoke(share.shareId), isTrue);
    expect(await service.listShares(), isEmpty);

    await service.close();
    await storage.close();
  });

  /// The crash the new order leaves behind, and what a restart must do with it.
  ///
  /// With the tombstone written first, a crash before the registry save leaves
  /// a tombstone AND a row still in the registry. `_start` used to host every
  /// row it read and consult the event log afterwards, so that share was
  /// served from the moment the app opened.
  test('a tombstone outranks a row a crash left in the registry', () async {
    final container = FakeHvContainer();
    final storage = container.storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final network = _Network();
    final service = CloudCapabilityService(storage, network, random: _Random());

    final bytes = Uint8List.fromList(List.generate(32, (i) => i + 5));
    final manifest = ContentManifest.fromBytes('g.bin', bytes);
    await storage.storeFile(manifest.contentId, bytes);
    await storage.storeFile(
      'mf:${manifest.contentId}',
      Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
    );
    final share = await service.createShare(
      CloudItem(
        id: 'g',
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
    final liveRegistry = (await storage.loadFile(
      _EventsWriteFails.registryFile,
    ))!;

    expect(await service.revoke(share.shareId), isTrue);
    await service.close();

    // Put the registry back the way a crash between the two writes leaves it:
    // the tombstone is down, the row never came out.
    await storage.storeFile(_EventsWriteFails.registryFile, liveRegistry);

    final hostedBefore = network.endpoints.length;
    final restarted = CloudCapabilityService(
      storage,
      network,
      random: _Random(),
    );
    await restarted.start();
    expect(
      await restarted.listShares(),
      isEmpty,
      reason:
          'the log says it was revoked; the registry is only what was last '
          'written',
    );
    expect(
      network.endpoints.length,
      hostedBefore,
      reason: 'and nothing was put back on the network to find out',
    );

    await restarted.close();
    await storage.close();
  });
}
