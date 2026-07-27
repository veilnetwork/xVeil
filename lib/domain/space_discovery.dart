import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import 'group.dart';
import 'space_discovery_search.dart' show normalizeSpaceDiscoverySearchText;
import 'space_join_request.dart';

const Duration kSpacePublicDescriptorLifetime = Duration(days: 7);
const Duration kSpacePublicHolderLifetime = Duration(hours: 2);
const Duration kSpacePublicClockSkew = Duration(minutes: 5);

final RegExp _hex32Pattern = RegExp(r'^[0-9a-f]{64}$');

typedef SpacePublicSignatureVerifier =
    bool Function({
      required NodeId signer,
      required Uint8List publicKey,
      required Uint8List message,
      required Uint8List signature,
    });

/// Minimal public projection of one accepted V6 ownership transfer.
///
/// The signature is the original control-entry signature, but the public wire
/// exposes only the fields needed to reconstruct those exact signed bytes.
/// Roster, roles, policy contents, channels and the rest of the control log
/// never cross the discovery boundary.
class SpacePublicAuthorityLink {
  SpacePublicAuthorityLink({
    required this.previousOwner,
    required this.nextOwner,
    required this.authorSeq,
    required this.authorPreviousHash,
    required this.policyVersion,
    required this.transferredAtMs,
    required this.previousOwnerPublicKey,
    required this.signature,
  });

  static const int version = 1;

  final NodeId previousOwner;
  final NodeId nextOwner;
  final int authorSeq;
  final String authorPreviousHash;
  final int policyVersion;
  final int transferredAtMs;
  final Uint8List previousOwnerPublicKey;
  final Uint8List signature;

  bool get isStructurallyValid =>
      previousOwner != nextOwner &&
      authorSeq >= 0 &&
      policyVersion >= 0 &&
      transferredAtMs >= 0 &&
      (authorSeq == 0
          ? authorPreviousHash.isEmpty
          : _hex32Pattern.hasMatch(authorPreviousHash)) &&
      previousOwnerPublicKey.length == 32 &&
      signature.length == 64;

  Uint8List transferCanonicalBytes(NodeId spaceId) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 6,
        'gid': spaceId.hex,
        'author': previousOwner.hex,
        'seq': authorSeq,
        'prev': authorPreviousHash,
        'op': ControlOp.transferOwnership.name,
        'target': nextOwner.hex,
        'pv': policyVersion,
        'ts': transferredAtMs,
      }),
    ),
  );

  bool verifyFor({
    required NodeId spaceId,
    required NodeId expectedPreviousOwner,
    required int descriptorIssuedAtMs,
    required SpacePublicSignatureVerifier verify,
  }) =>
      isStructurallyValid &&
      previousOwner == expectedPreviousOwner &&
      transferredAtMs <=
          descriptorIssuedAtMs + kSpacePublicClockSkew.inMilliseconds &&
      verify(
        signer: previousOwner,
        publicKey: previousOwnerPublicKey,
        message: transferCanonicalBytes(spaceId),
        signature: signature,
      );

  Map<String, dynamic> toJson() => {
    'v': version,
    'from': previousOwner.hex,
    'to': nextOwner.hex,
    'seq': authorSeq,
    'prev': authorPreviousHash,
    'pv': policyVersion,
    'ts': transferredAtMs,
    'key': base64Encode(previousOwnerPublicKey),
    'sig': base64Encode(signature),
  };

  static SpacePublicAuthorityLink? fromControlEntry(ControlEntry entry) {
    if (entry.version != 6 ||
        entry.op != ControlOp.transferOwnership ||
        entry.groupId == null ||
        entry.target == null ||
        !entry.isStructurallyValid ||
        entry.authorPubKey.length != 32 ||
        entry.signature.length != 64) {
      return null;
    }
    return SpacePublicAuthorityLink(
      previousOwner: entry.author,
      nextOwner: entry.target!,
      authorSeq: entry.seq,
      authorPreviousHash: entry.prevHash,
      policyVersion: entry.policyVersion,
      transferredAtMs: entry.createdAtMs,
      previousOwnerPublicKey: Uint8List.fromList(entry.authorPubKey),
      signature: Uint8List.fromList(entry.signature),
    );
  }

  static SpacePublicAuthorityLink? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'from',
          'to',
          'seq',
          'prev',
          'pv',
          'ts',
          'key',
          'sig',
        }) ||
        value['v'] != version ||
        value['from'] is! String ||
        value['to'] is! String ||
        value['seq'] is! int ||
        value['prev'] is! String ||
        value['pv'] is! int ||
        value['ts'] is! int ||
        value['key'] is! String ||
        value['sig'] is! String) {
      return null;
    }
    try {
      final link = SpacePublicAuthorityLink(
        previousOwner: NodeId.fromHex(value['from'] as String),
        nextOwner: NodeId.fromHex(value['to'] as String),
        authorSeq: value['seq'] as int,
        authorPreviousHash: value['prev'] as String,
        policyVersion: value['pv'] as int,
        transferredAtMs: value['ts'] as int,
        previousOwnerPublicKey: Uint8List.fromList(
          base64Decode(value['key'] as String),
        ),
        signature: Uint8List.fromList(base64Decode(value['sig'] as String)),
      );
      return link.isStructurallyValid ? link : null;
    } catch (_) {
      return null;
    }
  }
}

/// Independent upper bound for the complete descriptor + holder JSON payload.
///
/// The compact authority chain is bounded separately; the final payload check
/// remains authoritative because profile and capability fields are variable.
const int kSpacePublicDiscoveryPayloadMaxBytes = 16 * 1024;

// Hard causal-history bound. The final carrier still enforces its independent
// total payload budget above.
const int kSpacePublicAuthorityMaxLinks = 24;
const int _spacePublicAuthorityLinkBytes = 185;
const List<int> _spacePublicAuthorityMagic = <int>[0x58, 0x41, 0x01]; // XA1

/// Project the accepted ownership hand-offs in their causal fold order.
///
/// A mismatch means the supplied log cannot be represented as one public
/// genesis-rooted authority chain and therefore must fail closed.
List<SpacePublicAuthorityLink>? buildSpacePublicAuthorityChain({
  required NodeId spaceId,
  required NodeId genesisOwner,
  required Iterable<ControlEntry> acceptedControl,
}) {
  var currentOwner = genesisOwner;
  final result = <SpacePublicAuthorityLink>[];
  for (final entry in acceptedControl) {
    if (entry.op != ControlOp.transferOwnership) continue;
    if (entry.groupId != spaceId || entry.author != currentOwner) return null;
    final link = SpacePublicAuthorityLink.fromControlEntry(entry);
    if (link == null) return null;
    result.add(link);
    if (result.length > kSpacePublicAuthorityMaxLinks) return null;
    currentOwner = link.nextOwner;
  }
  return List<SpacePublicAuthorityLink>.unmodifiable(result);
}

/// Owner-published, allowlisted projection used by public Space discovery.
///
/// This is deliberately not a serialized [SpaceManifest] or control-log
/// snapshot. Discovery peers learn only the profile needed to render a search
/// result and the capability needed to ask for membership. In particular,
/// roster, roles, channels, category ids, epochs and key envelopes have no
/// representation in this wire type.
class SpacePublicDescriptor {
  SpacePublicDescriptor({
    this.wireVersion = version,
    required this.spaceId,
    required this.publisher,
    Uint8List? publisherPublicKey,
    Iterable<SpacePublicAuthorityLink> authorityChain = const [],
    required this.genesisManifest,
    required this.controlHeadHash,
    required this.revision,
    required this.publicFeedManifestHash,
    required this.publicFeedRevision,
    required this.publicFeedUpdatedAtMs,
    required this.publicPostCount,
    required this.name,
    required this.description,
    required this.avatarContentId,
    required this.coverContentId,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.issuedAtMs,
    required this.expiresAtMs,
    required this.joinCode,
    Uint8List? signature,
  }) : publisherPublicKey = Uint8List.fromList(
         publisherPublicKey ?? genesisManifest.genesisPubKey,
       ),
       authorityChain = List<SpacePublicAuthorityLink>.unmodifiable(
         authorityChain,
       ),
       signature = signature ?? Uint8List(0);

  static const int version = 3;
  static const String kind = 'xveil.space.public';

  final int wireVersion;
  final NodeId spaceId;
  final NodeId publisher;
  final Uint8List publisherPublicKey;
  final List<SpacePublicAuthorityLink> authorityChain;
  final SpaceManifest genesisManifest;
  final String controlHeadHash;
  final int revision;
  final String publicFeedManifestHash;
  final int publicFeedRevision;
  final int publicFeedUpdatedAtMs;
  final int publicPostCount;
  final String name;
  final String description;
  final String? avatarContentId;
  final String? coverContentId;
  final int createdAtMs;
  final int updatedAtMs;
  final int issuedAtMs;
  final int expiresAtMs;
  final String joinCode;
  final Uint8List signature;

  int get authorityGeneration => authorityChain.length;

  String get authorityHash => crypto.sha256
      .convert(_encodeSpacePublicAuthorityChain(authorityChain))
      .toString();

  bool isStructurallyValidAt(int nowMs) {
    if (wireVersion != version ||
        !genesisManifest.isSpace ||
        genesisManifest.groupId != spaceId ||
        genesisManifest.visibility != SpaceVisibility.public ||
        genesisManifest.discoverable != true ||
        genesisManifest.genesisPubKey.length != 32 ||
        genesisManifest.signature.length != 64 ||
        publisherPublicKey.length != 32 ||
        authorityChain.length > kSpacePublicAuthorityMaxLinks ||
        authorityChain.any((link) => !link.isStructurallyValid) ||
        !_validContentId(genesisManifest.avatarContentId) ||
        !_validContentId(genesisManifest.coverContentId) ||
        signature.length != 64 ||
        !_hex32Pattern.hasMatch(controlHeadHash) ||
        !_hex32Pattern.hasMatch(publicFeedManifestHash) ||
        revision < 0 ||
        publicFeedRevision < 0 ||
        publicFeedUpdatedAtMs < createdAtMs ||
        publicFeedUpdatedAtMs > issuedAtMs ||
        publicPostCount < 0 ||
        publicPostCount > 131072 ||
        name != name.trim() ||
        name.isEmpty ||
        name.length > 160 ||
        utf8.encode(name).length > 512 ||
        description.length > 4096 ||
        utf8.encode(description).length > 8192 ||
        !_validContentId(avatarContentId) ||
        !_validContentId(coverContentId) ||
        createdAtMs != genesisManifest.createdAtMs ||
        updatedAtMs < createdAtMs ||
        issuedAtMs < updatedAtMs ||
        expiresAtMs <= issuedAtMs ||
        expiresAtMs - issuedAtMs >
            kSpacePublicDescriptorLifetime.inMilliseconds ||
        issuedAtMs > nowMs + kSpacePublicClockSkew.inMilliseconds ||
        expiresAtMs <= nowMs) {
      return false;
    }
    try {
      final ticket = SpaceJoinCode.parse(joinCode);
      return ticket.spaceId == spaceId &&
          ticket.approver == publisher &&
          !ticket.isExpiredAt(nowMs) &&
          ticket.createdAtMs <= issuedAtMs &&
          ticket.expiresAtMs >= expiresAtMs;
    } catch (_) {
      return false;
    }
  }

  bool verifyAt(int nowMs, SpacePublicSignatureVerifier verify) =>
      isStructurallyValidAt(nowMs) &&
      verify(
        signer: genesisManifest.owner,
        publicKey: genesisManifest.genesisPubKey,
        message: genesisManifest.canonicalBytes(),
        signature: genesisManifest.signature,
      ) &&
      _verifyAuthorityChain(verify) &&
      verify(
        signer: publisher,
        publicKey: publisherPublicKey,
        message: canonicalBytes(),
        signature: signature,
      );

  bool _verifyAuthorityChain(SpacePublicSignatureVerifier verify) {
    var currentOwner = genesisManifest.owner;
    for (final link in authorityChain) {
      if (!link.verifyFor(
        spaceId: spaceId,
        expectedPreviousOwner: currentOwner,
        descriptorIssuedAtMs: issuedAtMs,
        verify: verify,
      )) {
        return false;
      }
      currentOwner = link.nextOwner;
    }
    return currentOwner == publisher;
  }

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': wireVersion,
        'kind': kind,
        'space': spaceId.hex,
        'publisher': publisher.hex,
        'publisherKey': base64Encode(publisherPublicKey),
        'authority': base64Encode(
          _encodeSpacePublicAuthorityChain(authorityChain),
        ),
        'genesis': genesisManifest.toJson(),
        'controlHeadHash': controlHeadHash,
        'revision': revision,
        'publicFeedManifestHash': publicFeedManifestHash,
        'publicFeedRevision': publicFeedRevision,
        'publicFeedUpdatedAt': publicFeedUpdatedAtMs,
        'publicPostCount': publicPostCount,
        'name': name,
        'description': description,
        if (avatarContentId != null) 'avatar': avatarContentId,
        if (coverContentId != null) 'cover': coverContentId,
        'createdAt': createdAtMs,
        'updatedAt': updatedAtMs,
        'issuedAt': issuedAtMs,
        'expiresAt': expiresAtMs,
        'joinCode': joinCode,
      }),
    ),
  );

  String get descriptorHash {
    final bytes = BytesBuilder(copy: false)
      ..add(canonicalBytes())
      ..add(signature);
    return crypto.sha256.convert(bytes.toBytes()).toString();
  }

  SpacePublicDescriptor withSignature(Uint8List value) => SpacePublicDescriptor(
    wireVersion: wireVersion,
    spaceId: spaceId,
    publisher: publisher,
    publisherPublicKey: publisherPublicKey,
    authorityChain: authorityChain,
    genesisManifest: genesisManifest,
    controlHeadHash: controlHeadHash,
    revision: revision,
    publicFeedManifestHash: publicFeedManifestHash,
    publicFeedRevision: publicFeedRevision,
    publicFeedUpdatedAtMs: publicFeedUpdatedAtMs,
    publicPostCount: publicPostCount,
    name: name,
    description: description,
    avatarContentId: avatarContentId,
    coverContentId: coverContentId,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs,
    issuedAtMs: issuedAtMs,
    expiresAtMs: expiresAtMs,
    joinCode: joinCode,
    signature: value,
  );

  Map<String, dynamic> toJson() => {
    ...jsonDecode(utf8.decode(canonicalBytes())) as Map<String, dynamic>,
    'signature': base64Encode(signature),
  };

  static SpacePublicDescriptor? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'kind',
          'space',
          'publisher',
          'publisherKey',
          'authority',
          'genesis',
          'controlHeadHash',
          'revision',
          'publicFeedManifestHash',
          'publicFeedRevision',
          'publicFeedUpdatedAt',
          'publicPostCount',
          'name',
          'description',
          'avatar',
          'cover',
          'createdAt',
          'updatedAt',
          'issuedAt',
          'expiresAt',
          'joinCode',
          'signature',
        }) ||
        value['v'] != version ||
        value['kind'] != kind ||
        value['space'] is! String ||
        value['publisher'] is! String ||
        value['genesis'] is! Map ||
        value['controlHeadHash'] is! String ||
        value['revision'] is! int ||
        value['publicFeedManifestHash'] is! String ||
        value['publicFeedRevision'] is! int ||
        value['publicFeedUpdatedAt'] is! int ||
        value['publicPostCount'] is! int ||
        value['name'] is! String ||
        value['description'] is! String ||
        (value['avatar'] != null && value['avatar'] is! String) ||
        (value['cover'] != null && value['cover'] is! String) ||
        value['createdAt'] is! int ||
        value['updatedAt'] is! int ||
        value['issuedAt'] is! int ||
        value['expiresAt'] is! int ||
        value['joinCode'] is! String ||
        value['signature'] is! String) {
      return null;
    }
    final wireVersion = value['v'] as int;
    if (value['publisherKey'] is! String || value['authority'] is! String) {
      return null;
    }
    try {
      final genesisJson = value['genesis'] as Map;
      if (!_hasOnlyKeys(genesisJson, const {
        'v',
        'kind',
        'gid',
        'owner',
        'gpk',
        'name',
        'ts',
        'alg',
        'desc',
        'avatar',
        'cover',
        'visibility',
        'discoverable',
        'msig',
      })) {
        return null;
      }
      final genesis = SpaceManifest.fromJson(genesisJson);
      if (genesis == null) return null;
      final authority = _decodeSpacePublicAuthorityChain(
        Uint8List.fromList(base64Decode(value['authority'] as String)),
        genesis.owner,
      );
      if (authority == null) return null;
      final signature = Uint8List.fromList(
        base64Decode(value['signature'] as String),
      );
      return SpacePublicDescriptor(
        wireVersion: wireVersion,
        spaceId: NodeId.fromHex(value['space'] as String),
        publisher: NodeId.fromHex(value['publisher'] as String),
        publisherPublicKey: Uint8List.fromList(
          base64Decode(value['publisherKey'] as String),
        ),
        authorityChain: authority,
        genesisManifest: genesis,
        controlHeadHash: value['controlHeadHash'] as String,
        revision: value['revision'] as int,
        publicFeedManifestHash: value['publicFeedManifestHash'] as String,
        publicFeedRevision: value['publicFeedRevision'] as int,
        publicFeedUpdatedAtMs: value['publicFeedUpdatedAt'] as int,
        publicPostCount: value['publicPostCount'] as int,
        name: value['name'] as String,
        description: value['description'] as String,
        avatarContentId: value['avatar'] as String?,
        coverContentId: value['cover'] as String?,
        createdAtMs: value['createdAt'] as int,
        updatedAtMs: value['updatedAt'] as int,
        issuedAtMs: value['issuedAt'] as int,
        expiresAtMs: value['expiresAt'] as int,
        joinCode: value['joinCode'] as String,
        signature: signature,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Short-lived proof that a peer currently offers one exact public descriptor.
///
/// Holder records are separate from owner metadata so availability can rotate
/// without letting a relay rewrite the Space profile or join capability.
class SpacePublicHolderAnnouncement {
  SpacePublicHolderAnnouncement({
    required this.spaceId,
    required this.descriptorHash,
    required this.publicFeedManifestHash,
    required this.holder,
    required this.holderPublicKey,
    required this.issuedAtMs,
    required this.expiresAtMs,
    Uint8List? signature,
  }) : signature = signature ?? Uint8List(0);

  static const int version = 2;
  static const String kind = 'xveil.space.public-holder';

  final NodeId spaceId;
  final String descriptorHash;
  final String publicFeedManifestHash;
  final NodeId holder;
  final Uint8List holderPublicKey;
  final int issuedAtMs;
  final int expiresAtMs;
  final Uint8List signature;

  bool isStructurallyValidAt(int nowMs) =>
      _hex32Pattern.hasMatch(descriptorHash) &&
      _hex32Pattern.hasMatch(publicFeedManifestHash) &&
      holderPublicKey.length == 32 &&
      signature.length == 64 &&
      issuedAtMs >= 0 &&
      expiresAtMs > issuedAtMs &&
      expiresAtMs - issuedAtMs <= kSpacePublicHolderLifetime.inMilliseconds &&
      issuedAtMs <= nowMs + kSpacePublicClockSkew.inMilliseconds &&
      expiresAtMs > nowMs;

  bool verifyAt(int nowMs, SpacePublicSignatureVerifier verify) =>
      isStructurallyValidAt(nowMs) &&
      verify(
        signer: holder,
        publicKey: holderPublicKey,
        message: canonicalBytes(),
        signature: signature,
      );

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': version,
        'kind': kind,
        'space': spaceId.hex,
        'descriptorHash': descriptorHash,
        'publicFeedManifestHash': publicFeedManifestHash,
        'holder': holder.hex,
        'holderKey': base64Encode(holderPublicKey),
        'issuedAt': issuedAtMs,
        'expiresAt': expiresAtMs,
      }),
    ),
  );

  SpacePublicHolderAnnouncement withSignature(Uint8List value) =>
      SpacePublicHolderAnnouncement(
        spaceId: spaceId,
        descriptorHash: descriptorHash,
        publicFeedManifestHash: publicFeedManifestHash,
        holder: holder,
        holderPublicKey: holderPublicKey,
        issuedAtMs: issuedAtMs,
        expiresAtMs: expiresAtMs,
        signature: value,
      );

  Map<String, dynamic> toJson() => {
    ...jsonDecode(utf8.decode(canonicalBytes())) as Map<String, dynamic>,
    'signature': base64Encode(signature),
  };

  static SpacePublicHolderAnnouncement? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {
          'v',
          'kind',
          'space',
          'descriptorHash',
          'publicFeedManifestHash',
          'holder',
          'holderKey',
          'issuedAt',
          'expiresAt',
          'signature',
        }) ||
        value['v'] != version ||
        value['kind'] != kind ||
        value['space'] is! String ||
        value['descriptorHash'] is! String ||
        value['publicFeedManifestHash'] is! String ||
        value['holder'] is! String ||
        value['holderKey'] is! String ||
        value['issuedAt'] is! int ||
        value['expiresAt'] is! int ||
        value['signature'] is! String) {
      return null;
    }
    try {
      return SpacePublicHolderAnnouncement(
        spaceId: NodeId.fromHex(value['space'] as String),
        descriptorHash: value['descriptorHash'] as String,
        publicFeedManifestHash: value['publicFeedManifestHash'] as String,
        holder: NodeId.fromHex(value['holder'] as String),
        holderPublicKey: Uint8List.fromList(
          base64Decode(value['holderKey'] as String),
        ),
        issuedAtMs: value['issuedAt'] as int,
        expiresAtMs: value['expiresAt'] as int,
        signature: Uint8List.fromList(
          base64Decode(value['signature'] as String),
        ),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Exact application payload carried inside one native `XS` DHT record.
///
/// The native layer authenticates the short-lived holder carrier; this layer
/// independently authenticates both the owner descriptor and the holder's
/// attestation of its exact hash.
class SpacePublicDiscoveryPayload {
  const SpacePublicDiscoveryPayload({
    required this.descriptor,
    required this.holder,
  });

  final SpacePublicDescriptor descriptor;
  final SpacePublicHolderAnnouncement holder;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'descriptor': descriptor.toJson(),
    'holder': holder.toJson(),
  };

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  bool verifyAt(int nowMs, SpacePublicSignatureVerifier verify) =>
      descriptor.verifyAt(nowMs, verify) &&
      holder.spaceId == descriptor.spaceId &&
      holder.descriptorHash == descriptor.descriptorHash &&
      holder.publicFeedManifestHash == descriptor.publicFeedManifestHash &&
      holder.verifyAt(nowMs, verify);

  static SpacePublicDiscoveryPayload? fromJson(Object? value) {
    if (value is! Map ||
        !_hasOnlyKeys(value, const {'v', 'descriptor', 'holder'}) ||
        value['v'] != 1) {
      return null;
    }
    final descriptor = SpacePublicDescriptor.fromJson(value['descriptor']);
    final holder = SpacePublicHolderAnnouncement.fromJson(value['holder']);
    if (descriptor == null ||
        holder == null ||
        holder.spaceId != descriptor.spaceId ||
        holder.descriptorHash != descriptor.descriptorHash ||
        holder.publicFeedManifestHash != descriptor.publicFeedManifestHash) {
      return null;
    }
    return SpacePublicDiscoveryPayload(descriptor: descriptor, holder: holder);
  }

  static SpacePublicDiscoveryPayload? fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > kSpacePublicDiscoveryPayloadMaxBytes) {
      return null;
    }
    try {
      return fromJson(jsonDecode(utf8.decode(bytes, allowMalformed: false)));
    } catch (_) {
      return null;
    }
  }
}

/// Verifies and merges independently fetched descriptor/holder candidates.
///
/// The merge never trusts a descriptor just because it occupied a DHT key.
/// At least [minimumIndependentHolders] distinct, valid holder signatures must
/// attest the exact descriptor hash. Callers can require a larger quorum for
/// global search while still permitting a one-holder bootstrap by exact link.
List<SpacePublicDescriptor> mergeSpacePublicDiscovery({
  required Iterable<SpacePublicDescriptor> descriptors,
  required Iterable<SpacePublicHolderAnnouncement> holders,
  required int nowMs,
  required SpacePublicSignatureVerifier verify,
  int minimumIndependentHolders = 1,
  String query = '',
}) {
  if (minimumIndependentHolders < 1) {
    throw ArgumentError.value(
      minimumIndependentHolders,
      'minimumIndependentHolders',
      'must be at least one',
    );
  }
  final validDescriptors = <String, SpacePublicDescriptor>{};
  for (final descriptor in descriptors) {
    if (!descriptor.verifyAt(nowMs, verify)) continue;
    validDescriptors[descriptor.descriptorHash] = descriptor;
  }
  final holdersByDescriptor = <String, Set<NodeId>>{};
  for (final holder in holders) {
    final descriptor = validDescriptors[holder.descriptorHash];
    if (descriptor == null ||
        holder.spaceId != descriptor.spaceId ||
        holder.publicFeedManifestHash != descriptor.publicFeedManifestHash ||
        !holder.verifyAt(nowMs, verify)) {
      continue;
    }
    holdersByDescriptor
        .putIfAbsent(holder.descriptorHash, () => <NodeId>{})
        .add(holder.holder);
  }
  final normalizedQuery = normalizeSpaceDiscoverySearchText(query);
  final bestBySpace = <NodeId, SpacePublicDescriptor>{};
  for (final entry in validDescriptors.entries) {
    if ((holdersByDescriptor[entry.key]?.length ?? 0) <
        minimumIndependentHolders) {
      continue;
    }
    final descriptor = entry.value;
    if (normalizedQuery.isNotEmpty &&
        !normalizeSpaceDiscoverySearchText(
          descriptor.name,
        ).contains(normalizedQuery) &&
        !normalizeSpaceDiscoverySearchText(
          descriptor.description,
        ).contains(normalizedQuery)) {
      continue;
    }
    final current = bestBySpace[descriptor.spaceId];
    if (current == null ||
        compareSpacePublicDescriptors(descriptor, current) > 0) {
      bestBySpace[descriptor.spaceId] = descriptor;
    }
  }
  final result = bestBySpace.values.toList()
    ..sort((left, right) {
      final byUpdated = right.updatedAtMs.compareTo(left.updatedAtMs);
      if (byUpdated != 0) return byUpdated;
      return left.spaceId.hex.compareTo(right.spaceId.hex);
    });
  return List<SpacePublicDescriptor>.unmodifiable(result);
}

/// Deterministic newest-authority-first order shared by discovery, caches and
/// durable public-only rollback protection.
int compareSpacePublicDescriptors(
  SpacePublicDescriptor left,
  SpacePublicDescriptor right,
) {
  final byAuthorityGeneration = left.authorityGeneration.compareTo(
    right.authorityGeneration,
  );
  if (byAuthorityGeneration != 0) return byAuthorityGeneration;
  final byAuthorityHash = left.authorityHash.compareTo(right.authorityHash);
  if (byAuthorityHash != 0) return byAuthorityHash;
  final byFeedRevision = left.publicFeedRevision.compareTo(
    right.publicFeedRevision,
  );
  if (byFeedRevision != 0) return byFeedRevision;
  final byFeedUpdated = left.publicFeedUpdatedAtMs.compareTo(
    right.publicFeedUpdatedAtMs,
  );
  if (byFeedUpdated != 0) return byFeedUpdated;
  final byRevision = left.revision.compareTo(right.revision);
  if (byRevision != 0) return byRevision;
  final byIssue = left.issuedAtMs.compareTo(right.issuedAtMs);
  if (byIssue != 0) return byIssue;
  return left.descriptorHash.compareTo(right.descriptorHash);
}

Uint8List _encodeSpacePublicAuthorityChain(
  Iterable<SpacePublicAuthorityLink> links,
) {
  final rows = links.toList(growable: false);
  if (rows.length > kSpacePublicAuthorityMaxLinks) {
    throw ArgumentError.value(
      rows.length,
      'links',
      'exceeds public authority limit',
    );
  }
  final bytes = BytesBuilder(copy: false)
    ..add(_spacePublicAuthorityMagic)
    ..addByte(rows.length);
  for (final link in rows) {
    bytes
      ..add(link.nextOwner.bytes)
      ..add(_u64le(link.authorSeq))
      ..addByte(link.authorPreviousHash.isEmpty ? 0 : 1)
      ..add(
        link.authorPreviousHash.isEmpty
            ? Uint8List(32)
            : _hexToBytes(link.authorPreviousHash),
      )
      ..add(_u64le(link.policyVersion))
      ..add(_u64le(link.transferredAtMs))
      ..add(link.previousOwnerPublicKey)
      ..add(link.signature);
  }
  return bytes.toBytes();
}

List<SpacePublicAuthorityLink>? _decodeSpacePublicAuthorityChain(
  Uint8List bytes,
  NodeId genesisOwner,
) {
  if (bytes.length < 4 ||
      !_sameBytes(bytes.sublist(0, 3), _spacePublicAuthorityMagic)) {
    return null;
  }
  final count = bytes[3];
  if (count > kSpacePublicAuthorityMaxLinks ||
      bytes.length != 4 + count * _spacePublicAuthorityLinkBytes) {
    return null;
  }
  var offset = 4;
  var previousOwner = genesisOwner;
  final result = <SpacePublicAuthorityLink>[];
  for (var index = 0; index < count; index++) {
    final nextOwner = NodeId(
      Uint8List.fromList(bytes.sublist(offset, offset + 32)),
    );
    offset += 32;
    final authorSeq = _readU64le(bytes, offset);
    offset += 8;
    final hasPrevious = bytes[offset++];
    if (hasPrevious != 0 && hasPrevious != 1) return null;
    final previousBytes = bytes.sublist(offset, offset + 32);
    offset += 32;
    if (hasPrevious == 0 && previousBytes.any((byte) => byte != 0)) {
      return null;
    }
    final policyVersion = _readU64le(bytes, offset);
    offset += 8;
    final transferredAtMs = _readU64le(bytes, offset);
    offset += 8;
    final publicKey = Uint8List.fromList(bytes.sublist(offset, offset + 32));
    offset += 32;
    final signature = Uint8List.fromList(bytes.sublist(offset, offset + 64));
    offset += 64;
    final link = SpacePublicAuthorityLink(
      previousOwner: previousOwner,
      nextOwner: nextOwner,
      authorSeq: authorSeq,
      authorPreviousHash: hasPrevious == 0 ? '' : _bytesToHex(previousBytes),
      policyVersion: policyVersion,
      transferredAtMs: transferredAtMs,
      previousOwnerPublicKey: publicKey,
      signature: signature,
    );
    if (!link.isStructurallyValid) return null;
    result.add(link);
    previousOwner = nextOwner;
  }
  return List<SpacePublicAuthorityLink>.unmodifiable(result);
}

Uint8List _u64le(int value) {
  if (value < 0) throw ArgumentError.value(value, 'value', 'must be positive');
  final data = ByteData(8)..setUint64(0, value, Endian.little);
  return data.buffer.asUint8List();
}

int _readU64le(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 8).getUint64(0, Endian.little);

Uint8List _hexToBytes(String value) => Uint8List.fromList([
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
]);

String _bytesToHex(List<int> value) =>
    value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

bool _validContentId(String? value) =>
    value == null || _hex32Pattern.hasMatch(value);

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

bool _hasOnlyKeys(Map<dynamic, dynamic> value, Set<String> allowed) {
  for (final key in value.keys) {
    if (key is! String || !allowed.contains(key)) return false;
  }
  return true;
}
