import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/node/space_discovery_transport.dart';
import 'package:xveil/domain/public_directory_pointer.dart';
import 'package:xveil/domain/space_discovery_carrier.dart';
import 'package:xveil/state/public_directory_service.dart';

/// A deterministic stand-in for identity signing: the "signature" is a hash
/// over (secret || message) and verification recomputes it, so a wrong signer
/// or tampered message fails exactly like real Ed25519 would for these tests.
class _FakeIdentity {
  _FakeIdentity(int seed)
    : publicKey = Uint8List.fromList(List.filled(32, seed)) {
    nodeId = NodeId(blake3Hash(publicKey));
  }

  final Uint8List publicKey;
  late final NodeId nodeId;

  ({Uint8List signature, Uint8List publicKey}) sign(Uint8List message) {
    final sig = blake3Hash(
      (BytesBuilder(copy: false)
            ..add(publicKey)
            ..add(message))
          .toBytes(),
    );
    return (
      signature: Uint8List.fromList([...sig, ...sig]),
      publicKey: publicKey,
    );
  }
}

bool _fakeVerify({
  required NodeId signer,
  required Uint8List publicKey,
  required Uint8List message,
  required Uint8List signature,
}) {
  if (signature.length != 64) return false;
  final expected = blake3Hash(
    (BytesBuilder(copy: false)
          ..add(publicKey)
          ..add(message))
        .toBytes(),
  );
  final want = Uint8List.fromList([...expected, ...expected]);
  if (want.length != signature.length) return false;
  for (var i = 0; i < want.length; i++) {
    if (want[i] != signature[i]) return false;
  }
  return true;
}

/// In-memory DHT keyed by (routeKind, routeBody). publish stores under the
/// signer-declared route; resolve returns everything under the queried route.
class _FakeDiscoveryTransport implements SpaceDiscoveryTransport {
  final Map<String, List<Uint8List>> _store = {};
  int publishCount = 0;

  String _key(SpaceDiscoveryCarrierRoute route) =>
      '${route.kind.index}:${route.body.join(',')}';

  @override
  Future<void> publish(Uint8List record) async {
    publishCount++;
    final carrier = SpaceDiscoveryCarrier.fromBytes(record);
    if (carrier == null) throw StateError('bad record');
    // Mimic the native store: one value per (key), last-writer wins for the
    // same holder (a fresh republish replaces the stale one).
    _store[_key(carrier.route)] = [record];
  }

  @override
  Future<List<Uint8List>> resolve(
    SpaceDiscoveryCarrierRoute route, {
    Duration timeout = const Duration(seconds: 8),
  }) async => List.of(_store[_key(route)] ?? const []);
}

void main() {
  test('pointer round-trips and verifies under the owner route', () {
    final owner = _FakeIdentity(7);
    final record = signPublicDirectoryRecord(
      owner: owner.nodeId,
      ownerPublicKey: owner.publicKey,
      title: 'My photos',
      link: 'xveil://cloud/v1#abc',
      issuedAtUnixMs: 1000,
      expiresAtUnixMs: 1000 + kSpaceDiscoveryCarrierLifetime.inMilliseconds,
      sign: owner.sign,
    );
    final pointer = parsePublicDirectoryRecord(
      bytes: record,
      expectedOwner: owner.nodeId,
      nowMs: 2000,
      verify: _fakeVerify,
    );
    expect(pointer, isNotNull);
    expect(pointer!.title, 'My photos');
    expect(pointer.link, 'xveil://cloud/v1#abc');
    expect(pointer.owner, owner.nodeId);
  });

  test('rejects a record whose holder is not the expected owner', () {
    final owner = _FakeIdentity(7);
    final other = _FakeIdentity(9);
    final record = signPublicDirectoryRecord(
      owner: owner.nodeId,
      ownerPublicKey: owner.publicKey,
      title: 't',
      link: 'xveil://cloud/v1#abc',
      issuedAtUnixMs: 1000,
      expiresAtUnixMs: 1000 + kSpaceDiscoveryCarrierLifetime.inMilliseconds,
      sign: owner.sign,
    );
    // A resolver asking for `other` must not accept `owner`'s record even
    // though the signature itself is valid — the route/holder must match.
    expect(
      parsePublicDirectoryRecord(
        bytes: record,
        expectedOwner: other.nodeId,
        nowMs: 2000,
        verify: _fakeVerify,
      ),
      isNull,
    );
  });

  test('rejects an expired record and a tampered payload', () {
    final owner = _FakeIdentity(3);
    final record = signPublicDirectoryRecord(
      owner: owner.nodeId,
      ownerPublicKey: owner.publicKey,
      title: 't',
      link: 'xveil://cloud/v1#abc',
      issuedAtUnixMs: 1000,
      expiresAtUnixMs: 1000 + kSpaceDiscoveryCarrierLifetime.inMilliseconds,
      sign: owner.sign,
    );
    // Past expiry.
    expect(
      parsePublicDirectoryRecord(
        bytes: record,
        expectedOwner: owner.nodeId,
        nowMs: 1000 + kSpaceDiscoveryCarrierLifetime.inMilliseconds + 1,
        verify: _fakeVerify,
      ),
      isNull,
    );
    // Flip a payload byte (near the end, inside the link) → signature breaks.
    final tampered = Uint8List.fromList(record);
    tampered[tampered.length - 70] ^= 0xff;
    expect(
      parsePublicDirectoryRecord(
        bytes: tampered,
        expectedOwner: owner.nodeId,
        nowMs: 2000,
        verify: _fakeVerify,
      ),
      isNull,
    );
  });

  test('service publish → persist → restart republish → resolve', () async {
    final owner = _FakeIdentity(5);
    final transport = _FakeDiscoveryTransport();
    final kv = <String, String>{};
    final revoked = <String>[];
    var clock = 100000;
    PublicDirectoryService build() => PublicDirectoryService(
      transport: transport,
      selfId: owner.nodeId,
      selfPublicKey: owner.publicKey,
      sign: owner.sign,
      verify: _fakeVerify,
      putSetting: (k, v) async => kv[k] = v,
      getSetting: (k) async => kv[k],
      resolveNickname: (name) async => name == 'alice' ? owner.nodeId : null,
      revokeShare: (shareId) async => revoked.add(shareId),
      now: () => DateTime.fromMillisecondsSinceEpoch(clock),
      republishEvery: null, // deterministic: drive republish manually
    );

    final service = build();
    await service.start();
    expect(service.status.isPublished, isFalse);

    expect(
      await service.publish(
        folderId: 'folder-1',
        shareId: 'share-1',
        link: 'xveil://cloud/v1#folderlink',
        title: 'Alice files',
      ),
      isTrue,
    );
    expect(service.status.isPublished, isTrue);
    expect(service.status.folderId, 'folder-1');
    expect(transport.publishCount, 1);
    expect(revoked, isEmpty); // nothing prior to revoke

    // Publishing a DIFFERENT folder revokes the previous folder's share.
    expect(
      await service.publish(
        folderId: 'folder-2',
        shareId: 'share-2',
        link: 'xveil://cloud/v1#folderlink2',
        title: 'Alice more',
      ),
      isTrue,
    );
    expect(revoked, ['share-1']);
    expect(service.status.shareId, 'share-2');

    // Anyone resolves alice → the current live directory.
    final resolved = await service.resolveByNickname('alice');
    expect(resolved, isNotNull);
    expect(resolved!.link, 'xveil://cloud/v1#folderlink2');
    expect(resolved.title, 'Alice more');

    // Unknown nickname resolves to nothing.
    expect(await service.resolveByNickname('bob'), isNull);

    // Restart: a fresh service over the same KV restores + republishes.
    clock += 60 * 60 * 1000; // 1h later (the record would still be live)
    final republishesBefore = transport.publishCount;
    final restarted = build();
    await restarted.start();
    expect(restarted.status.isPublished, isTrue);
    expect(restarted.status.folderId, 'folder-2');
    expect(transport.publishCount, republishesBefore + 1); // republished
    expect((await restarted.resolveByNodeId(owner.nodeId))!.title,
        'Alice more');

    // Withdraw stops publishing AND revokes the current folder share.
    final prior = await restarted.withdraw();
    expect(prior.shareId, 'share-2');
    expect(revoked, ['share-1', 'share-2']);
    expect(restarted.status.isPublished, isFalse);

    // After withdraw the record still lingers in the DHT until it expires,
    // but a fresh resolve past its expiry returns nothing.
    clock += kSpaceDiscoveryCarrierLifetime.inMilliseconds;
    expect(await restarted.resolveByNodeId(owner.nodeId), isNull);
  });
}
