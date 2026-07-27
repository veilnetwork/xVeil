import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/space_discovery.dart';
import 'package:xveil/domain/space_discovery_carrier.dart';
import 'package:xveil/domain/space_discovery_search.dart';
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
  int wireVersion = SpacePublicDescriptor.version,
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
    wireVersion: wireVersion,
    spaceId: space,
    publisher: publisher,
    genesisManifest: genesis,
    controlHeadHash: '33' * 32,
    revision: revision,
    publicFeedManifestHash: '55' * 32,
    publicFeedRevision: revision,
    publicFeedUpdatedAtMs: now - 1500 + revision,
    publicPostCount: revision,
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

SpacePublicDescriptor _transferredDescriptor({
  required int now,
  required int revision,
  required NodeId spaceId,
}) {
  final genesisOwner = _id(2);
  final nextOwner = _id(8);
  final base = _descriptor(now: now, revision: revision, spaceId: spaceId);
  final unsignedTransfer = ControlEntry(
    version: 6,
    groupId: spaceId,
    author: genesisOwner,
    seq: 0,
    prevHash: '',
    op: ControlOp.transferOwnership,
    target: nextOwner,
    role: null,
    policyVersion: 0,
    createdAtMs: now - 1000,
    signature: Uint8List(0),
  );
  final transfer = unsignedTransfer.withSignature(
    _signature(
      genesisOwner,
      genesisOwner.bytes,
      unsignedTransfer.canonicalBytes(),
    ),
    genesisOwner.bytes,
  );
  final authority = buildSpacePublicAuthorityChain(
    spaceId: spaceId,
    genesisOwner: genesisOwner,
    acceptedControl: [transfer],
  );
  final ticket = SpaceJoinTicket(
    ticketId: '12' * 32,
    spaceId: spaceId,
    approver: nextOwner,
    spaceName: base.name,
    createdAtMs: now - 500,
    expiresAtMs: now + kSpaceJoinTicketLifetime.inMilliseconds,
  );
  final unsigned = SpacePublicDescriptor(
    spaceId: spaceId,
    publisher: nextOwner,
    publisherPublicKey: nextOwner.bytes,
    authorityChain: authority!,
    genesisManifest: base.genesisManifest,
    controlHeadHash: '66' * 32,
    revision: revision,
    publicFeedManifestHash: '77' * 32,
    publicFeedRevision: revision,
    publicFeedUpdatedAtMs: now - 250,
    publicPostCount: revision,
    name: base.name,
    description: base.description,
    avatarContentId: base.avatarContentId,
    coverContentId: base.coverContentId,
    createdAtMs: base.createdAtMs,
    updatedAtMs: now - 500,
    issuedAtMs: now,
    expiresAtMs: now + const Duration(days: 1).inMilliseconds,
    joinCode: SpaceJoinCode.encode(ticket),
  );
  return unsigned.withSignature(
    _signature(nextOwner, nextOwner.bytes, unsigned.canonicalBytes()),
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
    publicFeedManifestHash: descriptor.publicFeedManifestHash,
    holder: holder,
    holderPublicKey: holder.bytes,
    issuedAtMs: now,
    expiresAtMs: now + const Duration(hours: 1).inMilliseconds,
  );
  return unsigned.withSignature(
    _signature(holder, holder.bytes, unsigned.canonicalBytes()),
  );
}

({NodeId nodeId, Uint8List publicKey, SpacePublicHolderAnnouncement holder})
_boundHolder({
  required SpacePublicDescriptor descriptor,
  required int now,
  int seed = 7,
}) {
  final publicKey = Uint8List.fromList(List<int>.generate(32, (i) => seed + i));
  final nodeId = NodeId(blake3Hash(publicKey));
  final unsigned = SpacePublicHolderAnnouncement(
    spaceId: descriptor.spaceId,
    descriptorHash: descriptor.descriptorHash,
    publicFeedManifestHash: descriptor.publicFeedManifestHash,
    holder: nodeId,
    holderPublicKey: publicKey,
    issuedAtMs: now,
    expiresAtMs: now + const Duration(hours: 1).inMilliseconds,
  );
  return (
    nodeId: nodeId,
    publicKey: publicKey,
    holder: unsigned.withSignature(
      _signature(nodeId, publicKey, unsigned.canonicalBytes()),
    ),
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
    'authority chain transfers publisher and outranks a stale genesis owner',
    () {
      const now = 1500000;
      final spaceId = _id(1);
      final stale = _descriptor(now: now, revision: 99, spaceId: spaceId);
      final transferred = _transferredDescriptor(
        now: now,
        revision: 1,
        spaceId: spaceId,
      );

      expect(transferred.verifyAt(now, _verify), isTrue);
      expect(transferred.authorityGeneration, 1);
      expect(transferred.publisher, _id(8));
      expect(
        transferred.toJson()['authority'],
        isA<String>(),
        reason: 'authority history stays in the compact signed binary block',
      );
      final roundTrip = SpacePublicDescriptor.fromJson(
        jsonDecode(jsonEncode(transferred.toJson())),
      );
      expect(roundTrip?.toJson(), transferred.toJson());
      expect(roundTrip?.verifyAt(now, _verify), isTrue);

      final staleHolder = _holder(descriptor: stale, holder: _id(3), now: now);
      final currentHolder = _holder(
        descriptor: transferred,
        holder: _id(4),
        now: now,
      );
      final merged = mergeSpacePublicDiscovery(
        descriptors: [stale, transferred],
        holders: [staleHolder, currentHolder],
        nowMs: now,
        verify: _verify,
      );
      expect(merged.single.descriptorHash, transferred.descriptorHash);

      final tampered = transferred.toJson();
      final authority = base64Decode(tampered['authority'] as String);
      authority[authority.length - 1] ^= 0x01;
      tampered['authority'] = base64Encode(authority);
      expect(
        SpacePublicDescriptor.fromJson(tampered)?.verifyAt(now, _verify),
        isFalse,
      );
    },
  );

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
      publicFeedManifestHash: current.publicFeedManifestHash,
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

  test(
    'native XS carrier round-trips and rejects tampering or wrong route',
    () {
      const now = 4000000;
      final descriptor = _descriptor(now: now);
      final bound = _boundHolder(descriptor: descriptor, now: now);
      final payload = SpacePublicDiscoveryPayload(
        descriptor: descriptor,
        holder: bound.holder,
      );
      final direct = SpaceDiscoveryCarrierRoute.direct(descriptor.spaceId);
      final carrier = SpaceDiscoveryCarrier.sign(
        route: direct,
        payload: payload,
        holder: bound.nodeId,
        holderPublicKey: bound.publicKey,
        sign: (message) => (
          signature: _signature(bound.nodeId, bound.publicKey, message),
          publicKey: bound.publicKey,
        ),
      );

      final wire = carrier.toBytes();
      expect(wire.sublist(0, 2), [0x58, 0x53]);
      final parsed = SpaceDiscoveryCarrier.fromBytes(wire);
      expect(parsed, isNotNull);
      expect(parsed!.route.sameAs(direct), isTrue);
      expect(parsed.verifyAt(now, _verify), isTrue);

      final tampered = Uint8List.fromList(wire)..[wire.length - 1] ^= 0x01;
      expect(
        SpaceDiscoveryCarrier.fromBytes(tampered)!.verifyAt(now, _verify),
        isFalse,
      );
      expect(
        SpaceDiscoveryCarrier.fromBytes(Uint8List.fromList([...wire, 0])),
        isNull,
      );

      final wrongDirect = SpaceDiscoveryCarrier(
        route: SpaceDiscoveryCarrierRoute.direct(_id(99)),
        spaceId: descriptor.spaceId,
        holder: carrier.holder,
        holderPublicKey: carrier.holderPublicKey,
        issuedAtUnixMs: carrier.issuedAtUnixMs,
        expiresAtUnixMs: carrier.expiresAtUnixMs,
        payload: carrier.payload,
        signature: carrier.signature,
      );
      expect(wrongDirect.verifyAt(now, _verify), isFalse);
    },
  );

  test(
    'public search terms are Unicode-aware, bounded and prefix-friendly',
    () {
      expect(
        normalizeSpaceDiscoverySearchText('  ТЕСТовое-сообщество  2026! '),
        'тестовое сообщество 2026',
      );
      final terms = spaceDiscoveryPublishedSearchTerms(
        'Тестовое Сообщество 2026',
      );
      expect(terms.first, 'тестовое сообщество 2026');
      expect(terms, containsAll(<String>['те', 'тес', 'со', 'соо', '2026']));
      expect(
        terms.length,
        lessThanOrEqualTo(kSpaceDiscoveryPublishedSearchTermLimit),
      );
      expect(spaceDiscoveryQueryTerms('ТЕС соо'), ['тес соо', 'тес', 'соо']);
      expect(spaceDiscoverySearchTokenHash('тес'), hasLength(32));
      expect(
        utf8.decode(spaceDiscoverySearchTokenHash('тес'), allowMalformed: true),
        isNot(contains('тес')),
      );
    },
  );
}

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var diff = 0;
  for (var i = 0; i < left.length; i++) {
    diff |= left[i] ^ right[i];
  }
  return diff == 0;
}
