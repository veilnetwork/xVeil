import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/space_discovery.dart';
import 'package:xveil/domain/space_join_request.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

Uint8List _signature(NodeId signer, Uint8List publicKey, Uint8List message) =>
    Uint8List.fromList(
      crypto.sha512.convert([...signer.bytes, ...publicKey, ...message]).bytes,
    );

bool _verify({
  required NodeId signer,
  required Uint8List publicKey,
  required Uint8List message,
  required Uint8List signature,
}) =>
    publicKey.length == 32 &&
    _same(signature, _signature(signer, publicKey, message));

SpacePublicDescriptor _descriptor({
  required int now,
  int revision = 1,
  String name = 'Public Space',
  NodeId? spaceId,
}) {
  final space = spaceId ?? _id(1);
  final publisher = _id(2);
  final ticket = SpaceJoinTicket(
    ticketId: '11' * 32,
    spaceId: space,
    approver: publisher,
    spaceName: name,
    createdAtMs: now - 1000,
    expiresAtMs: now + kSpaceJoinTicketLifetime.inMilliseconds,
  );
  final unsignedGenesis = SpaceManifest.space(
    spaceId: space,
    owner: publisher,
    genesisPubKey: publisher.bytes,
    name: name,
    description: 'Genesis description',
    avatarContentId: '44' * 32,
    visibility: SpaceVisibility.public,
    discoverable: true,
    createdAtMs: now - 5000,
  );
  final genesis = unsignedGenesis.withSignature(
    _signature(publisher, publisher.bytes, unsignedGenesis.canonicalBytes()),
  );
  final unsigned = SpacePublicDescriptor(
    spaceId: space,
    publisher: publisher,
    genesisManifest: genesis,
    controlHeadHash: '33' * 32,
    revision: revision,
    name: name,
    description: 'A searchable description',
    avatarContentId: '44' * 32,
    coverContentId: null,
    createdAtMs: now - 5000,
    updatedAtMs: now - 2000 + revision,
    issuedAtMs: now,
    expiresAtMs: now + const Duration(days: 1).inMilliseconds,
    joinCode: SpaceJoinCode.encode(ticket),
  );
  return unsigned.withSignature(
    _signature(publisher, publisher.bytes, unsigned.canonicalBytes()),
  );
}

SpacePublicHolderAnnouncement _holder({
  required SpacePublicDescriptor descriptor,
  required NodeId holder,
  required int now,
}) {
  final unsigned = SpacePublicHolderAnnouncement(
    spaceId: descriptor.spaceId,
    descriptorHash: descriptor.descriptorHash,
    holder: holder,
    holderPublicKey: holder.bytes,
    issuedAtMs: now,
    expiresAtMs: now + const Duration(hours: 1).inMilliseconds,
  );
  return unsigned.withSignature(
    _signature(holder, holder.bytes, unsigned.canonicalBytes()),
  );
}

void main() {
  test('public descriptor round-trips an allowlisted signed projection', () {
    const now = 1000000;
    final descriptor = _descriptor(now: now);

    expect(descriptor.verifyAt(now, _verify), isTrue);
    final encoded = descriptor.toJson();
    expect(
      encoded.keys,
      containsAll(<String>[
        'space',
        'publisher',
        'genesis',
        'controlHeadHash',
        'joinCode',
        'signature',
      ]),
    );
    expect(
      encoded.keys,
      isNot(
        containsAll(<String>['members', 'roles', 'channels', 'epochEnvelopes']),
      ),
    );

    final decoded = SpacePublicDescriptor.fromJson(
      jsonDecode(jsonEncode(encoded)),
    );
    expect(decoded, isNotNull);
    expect(decoded!.toJson(), encoded);
    expect(decoded.descriptorHash, descriptor.descriptorHash);
    expect(decoded.verifyAt(now, _verify), isTrue);
  });

  test(
    'descriptor rejects injected fields, tampering, expiry and wrong link',
    () {
      const now = 2000000;
      final descriptor = _descriptor(now: now);

      final injected = descriptor.toJson()..['members'] = [_id(9).hex];
      expect(SpacePublicDescriptor.fromJson(injected), isNull);

      final tamperedJson = descriptor.toJson()..['name'] = 'Spoofed';
      final tampered = SpacePublicDescriptor.fromJson(tamperedJson);
      expect(tampered, isNotNull);
      expect(tampered!.verifyAt(now, _verify), isFalse);

      expect(
        descriptor.verifyAt(
          now + const Duration(days: 2).inMilliseconds,
          _verify,
        ),
        isFalse,
      );

      final wrongSpace = _descriptor(now: now, spaceId: _id(7));
      final wrongLinkJson = descriptor.toJson()
        ..['joinCode'] = wrongSpace.joinCode;
      final wrongLink = SpacePublicDescriptor.fromJson(wrongLinkJson);
      expect(wrongLink, isNotNull);
      expect(wrongLink!.verifyAt(now, _verify), isFalse);
    },
  );

  test('holder merge requires independent signatures and exact descriptor', () {
    const now = 3000000;
    final old = _descriptor(now: now, revision: 1, name: 'Veil Garden');
    final current = _descriptor(now: now + 1, revision: 2, name: 'Veil Garden');
    final first = _holder(descriptor: current, holder: _id(3), now: now);
    final second = _holder(descriptor: current, holder: _id(4), now: now);
    final duplicate = _holder(descriptor: current, holder: _id(3), now: now);
    final oldHolder = _holder(descriptor: old, holder: _id(5), now: now);

    final result = mergeSpacePublicDiscovery(
      descriptors: [old, current],
      holders: [first, second, duplicate, oldHolder],
      nowMs: now,
      verify: _verify,
      minimumIndependentHolders: 2,
      query: 'garden',
    );
    expect(result, hasLength(1));
    expect(result.single.revision, 2);

    final missingQuorum = mergeSpacePublicDiscovery(
      descriptors: [current],
      holders: [first, duplicate],
      nowMs: now,
      verify: _verify,
      minimumIndependentHolders: 2,
    );
    expect(missingQuorum, isEmpty);

    final wrongSpaceUnsigned = SpacePublicHolderAnnouncement(
      spaceId: _id(8),
      descriptorHash: current.descriptorHash,
      holder: _id(6),
      holderPublicKey: _id(6).bytes,
      issuedAtMs: now,
      expiresAtMs: now + const Duration(hours: 1).inMilliseconds,
    );
    final wrongSpace = wrongSpaceUnsigned.withSignature(
      _signature(
        wrongSpaceUnsigned.holder,
        wrongSpaceUnsigned.holderPublicKey,
        wrongSpaceUnsigned.canonicalBytes(),
      ),
    );
    expect(
      mergeSpacePublicDiscovery(
        descriptors: [current],
        holders: [first, wrongSpace],
        nowMs: now,
        verify: _verify,
        minimumIndependentHolders: 2,
      ),
      isEmpty,
    );
  });
}

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var diff = 0;
  for (var i = 0; i < left.length; i++) {
    diff |= left[i] ^ right[i];
  }
  return diff == 0;
}
