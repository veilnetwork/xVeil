import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import 'group.dart';
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

/// Owner-published, allowlisted projection used by public Space discovery.
///
/// This is deliberately not a serialized [SpaceManifest] or control-log
/// snapshot. Discovery peers learn only the profile needed to render a search
/// result and the capability needed to ask for membership. In particular,
/// roster, roles, channels, category ids, epochs and key envelopes have no
/// representation in this wire type.
class SpacePublicDescriptor {
  SpacePublicDescriptor({
    required this.spaceId,
    required this.publisher,
    required this.genesisManifest,
    required this.controlHeadHash,
    required this.revision,
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
  }) : signature = signature ?? Uint8List(0);

  static const int version = 1;
  static const String kind = 'xveil.space.public';

  final NodeId spaceId;
  final NodeId publisher;
  final SpaceManifest genesisManifest;
  final String controlHeadHash;
  final int revision;
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

  bool isStructurallyValidAt(int nowMs) {
    if (!genesisManifest.isSpace ||
        genesisManifest.groupId != spaceId ||
        genesisManifest.owner != publisher ||
        genesisManifest.visibility != SpaceVisibility.public ||
        genesisManifest.discoverable != true ||
        genesisManifest.genesisPubKey.length != 32 ||
        genesisManifest.signature.length != 64 ||
        !_validContentId(genesisManifest.avatarContentId) ||
        !_validContentId(genesisManifest.coverContentId) ||
        signature.length != 64 ||
        !_hex32Pattern.hasMatch(controlHeadHash) ||
        revision < 0 ||
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
      verify(
        signer: publisher,
        publicKey: genesisManifest.genesisPubKey,
        message: canonicalBytes(),
        signature: signature,
      );

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': version,
        'kind': kind,
        'space': spaceId.hex,
        'publisher': publisher.hex,
        'genesis': genesisManifest.toJson(),
        'controlHeadHash': controlHeadHash,
        'revision': revision,
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
    spaceId: spaceId,
    publisher: publisher,
    genesisManifest: genesisManifest,
    controlHeadHash: controlHeadHash,
    revision: revision,
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
          'genesis',
          'controlHeadHash',
          'revision',
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
      final signature = Uint8List.fromList(
        base64Decode(value['signature'] as String),
      );
      return SpacePublicDescriptor(
        spaceId: NodeId.fromHex(value['space'] as String),
        publisher: NodeId.fromHex(value['publisher'] as String),
        genesisManifest: genesis,
        controlHeadHash: value['controlHeadHash'] as String,
        revision: value['revision'] as int,
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
    required this.holder,
    required this.holderPublicKey,
    required this.issuedAtMs,
    required this.expiresAtMs,
    Uint8List? signature,
  }) : signature = signature ?? Uint8List(0);

  static const int version = 1;
  static const String kind = 'xveil.space.public-holder';

  final NodeId spaceId;
  final String descriptorHash;
  final NodeId holder;
  final Uint8List holderPublicKey;
  final int issuedAtMs;
  final int expiresAtMs;
  final Uint8List signature;

  bool isStructurallyValidAt(int nowMs) =>
      _hex32Pattern.hasMatch(descriptorHash) &&
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
        !holder.verifyAt(nowMs, verify)) {
      continue;
    }
    holdersByDescriptor
        .putIfAbsent(holder.descriptorHash, () => <NodeId>{})
        .add(holder.holder);
  }
  final normalizedQuery = query.trim().toLowerCase();
  final bestBySpace = <NodeId, SpacePublicDescriptor>{};
  for (final entry in validDescriptors.entries) {
    if ((holdersByDescriptor[entry.key]?.length ?? 0) <
        minimumIndependentHolders) {
      continue;
    }
    final descriptor = entry.value;
    if (normalizedQuery.isNotEmpty &&
        !descriptor.name.toLowerCase().contains(normalizedQuery) &&
        !descriptor.description.toLowerCase().contains(normalizedQuery)) {
      continue;
    }
    final current = bestBySpace[descriptor.spaceId];
    if (current == null || _descriptorOrder(descriptor, current) > 0) {
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

int _descriptorOrder(SpacePublicDescriptor left, SpacePublicDescriptor right) {
  final byRevision = left.revision.compareTo(right.revision);
  if (byRevision != 0) return byRevision;
  final byIssue = left.issuedAtMs.compareTo(right.issuedAtMs);
  if (byIssue != 0) return byIssue;
  return left.descriptorHash.compareTo(right.descriptorHash);
}

bool _validContentId(String? value) =>
    value == null || _hex32Pattern.hasMatch(value);

bool _hasOnlyKeys(Map<dynamic, dynamic> value, Set<String> allowed) {
  for (final key in value.keys) {
    if (key is! String || !allowed.contains(key)) return false;
  }
  return true;
}
