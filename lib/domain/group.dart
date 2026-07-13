// Group domain core (groups epic, phase 0, brick 1): the pure data model for
// a group — the manifest + the signed CONTROL-LOG that mutates membership,
// roles and policy. No wire, no DHT, no crypto side effects here; signatures
// are canonical bytes the app signs/verifies with the veil identity elsewhere.
//
// This mirrors the agreed design (ROADMAP "группы и каналы"): a group is a
// manifest (genesis key, id, policy) plus an append-only control-log of
// author-signed ops. Policy is evaluated LOCALLY and deterministically (see
// group_policy.dart): an op that its author lacks permission for is rejected
// — never applied, never shown.

import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import 'group_epoch.dart';

/// A member's role. Higher [rank] can manage lower ranks (see policy).
enum GroupRole {
  owner(3),
  admin(2),
  member(1);

  const GroupRole(this.rank);
  final int rank;

  static GroupRole? fromName(String? s) {
    for (final r in GroupRole.values) {
      if (r.name == s) return r;
    }
    return null;
  }
}

/// The immutable group root: created once by the genesis (owner) key. The
/// [groupId] is BLAKE3(genesisPubKey)-derived app-side; here it is an opaque
/// 32-byte id carried so the manifest is self-contained.
class GroupManifest {
  GroupManifest({
    required this.groupId,
    required this.owner,
    required this.genesisPubKey,
    required this.name,
    required this.createdAtMs,
    this.version = 1,
    this.kind,
    this.signatureAlgorithm,
    this.sovereignBundleHash,
    Uint8List? signature,
  }) : signature = signature ?? Uint8List(0);

  final NodeId groupId; // opaque 32-byte group id (random at creation)
  final NodeId owner; // the genesis owner's node id = BLAKE3(genesisPubKey)
  /// Legacy manifests carry a 32-byte Ed25519 key. Sovereign device
  /// manifests are algorithm-tagged and permit variable key sizes so a
  /// Falcon/hybrid bundle does not require another wire migration.
  final Uint8List genesisPubKey;
  final String name;
  final int createdAtMs;
  final int version;
  final String? kind;
  final String? signatureAlgorithm;

  /// SHA-256 of the encrypted sovereign bundle replicated with this device
  /// group. Its signed hash prevents a member device from replacing the blob.
  final Uint8List? sovereignBundleHash;
  final Uint8List signature;

  static const int sovereignDeviceVersion = 2;
  static const String sovereignDeviceKind = 'xveil.devices';

  bool get isSovereignDevice =>
      version == sovereignDeviceVersion &&
      kind == sovereignDeviceKind &&
      signatureAlgorithm != null &&
      signature.isNotEmpty;

  Uint8List canonicalBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': version,
        if (kind != null) 'kind': kind,
        'gid': groupId.hex,
        'owner': owner.hex,
        'gpk': base64Encode(genesisPubKey),
        'name': name,
        'ts': createdAtMs,
        if (signatureAlgorithm != null) 'alg': signatureAlgorithm,
        if (sovereignBundleHash != null)
          'sbh': base64Encode(sovereignBundleHash!),
      }),
    ),
  );

  GroupManifest withSignature(Uint8List value) => GroupManifest(
    groupId: groupId,
    owner: owner,
    genesisPubKey: genesisPubKey,
    name: name,
    createdAtMs: createdAtMs,
    version: version,
    kind: kind,
    signatureAlgorithm: signatureAlgorithm,
    sovereignBundleHash: sovereignBundleHash,
    signature: value,
  );

  bool sameGenesis(GroupManifest other) =>
      base64Encode(canonicalBytes()) == base64Encode(other.canonicalBytes()) &&
      base64Encode(signature) == base64Encode(other.signature);

  Map<String, dynamic> toJson() => {
    'v': version,
    if (kind != null) 'kind': kind,
    'gid': groupId.hex,
    'owner': owner.hex,
    'gpk': base64Encode(genesisPubKey),
    'name': name,
    'ts': createdAtMs,
    if (signatureAlgorithm != null) 'alg': signatureAlgorithm,
    if (sovereignBundleHash != null) 'sbh': base64Encode(sovereignBundleHash!),
    if (signature.isNotEmpty) 'msig': base64Encode(signature),
  };

  static GroupManifest? fromJson(Object? j) {
    if (j is! Map) return null;
    final version = j['v'] is int ? j['v'] as int : 1;
    if (version != 1 && version != sovereignDeviceVersion) return null;
    final gid = j['gid'], owner = j['owner'];
    final gpk = j['gpk'], name = j['name'], ts = j['ts'];
    if (gid is! String ||
        owner is! String ||
        gpk is! String ||
        name is! String ||
        ts is! int) {
      return null;
    }
    try {
      final pk = base64Decode(gpk);
      final signature = j['msig'] is String
          ? Uint8List.fromList(base64Decode(j['msig'] as String))
          : Uint8List(0);
      final bundleHash = j['sbh'] is String
          ? Uint8List.fromList(base64Decode(j['sbh'] as String))
          : null;
      if (pk.isEmpty || pk.length > 16384 || signature.length > 16384) {
        return null;
      }
      if (bundleHash != null && bundleHash.length != 32) return null;
      if (version == 1 && pk.length != 32) return null;
      if (version == sovereignDeviceVersion &&
          (j['kind'] != sovereignDeviceKind ||
              j['alg'] is! String ||
              (j['alg'] as String).isEmpty ||
              signature.isEmpty)) {
        return null;
      }
      return GroupManifest(
        groupId: NodeId.fromHex(gid),
        owner: NodeId.fromHex(owner),
        genesisPubKey: Uint8List.fromList(pk),
        name: name,
        createdAtMs: ts,
        version: version,
        kind: j['kind'] is String ? j['kind'] as String : null,
        signatureAlgorithm: j['alg'] is String ? j['alg'] as String : null,
        sovereignBundleHash: bundleHash,
        signature: signature,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The kinds of control-log op. Kept versioned/extensible from day one.
enum ControlOp {
  addMember,
  removeMember,
  setRole,
  mute,
  unmute,
  ban,
  rotateEpoch,
  setPolicy,
  setName, // rename the group (payload in ControlEntry.text)
  leave; // the author removes THEMSELVES (any member may leave)

  static ControlOp? fromName(String? s) {
    for (final o in ControlOp.values) {
      if (o.name == s) return o;
    }
    return null;
  }
}

/// One entry in a group's control-log: an [op] by [author] at their own
/// monotonic [seq], chained by [prevHash] (hash of the author's previous
/// entry, or empty for their first), bound to the [policyVersion] it was
/// authored against, and signed ([signature] over [canonicalBytes]).
class ControlEntry {
  ControlEntry({
    this.groupId,
    required this.author,
    required this.seq,
    required this.prevHash,
    required this.op,
    required this.target,
    required this.role,
    required this.policyVersion,
    required this.createdAtMs,
    required this.signature,
    this.text,
    this.epochDescriptor,
    Uint8List? authorPubKey,
  }) : authorPubKey = authorPubKey ?? Uint8List(0);

  /// Group binding for replay resistance. Legacy entries omit it and retain
  /// their old canonical bytes; every newly-authored entry includes it.
  final NodeId? groupId;
  final NodeId author;
  final int seq;
  final String prevHash; // hex of the author's previous entry hash, or ''
  final ControlOp op;
  final NodeId?
  target; // member the op acts on (null for rotateEpoch/setPolicy)
  final GroupRole? role; // for setRole/addMember
  final String? text; // string payload (the new name for setName)
  /// Optional scale-free recipient-envelope root for the epoch established by
  /// this control entry. Legacy entries omit it and keep identical bytes.
  final GroupEpochDescriptor? epochDescriptor;
  final int policyVersion;
  final int createdAtMs;
  final Uint8List signature; // ed25519 over canonicalBytes (verified app-side)

  /// The author's 32-byte ed25519 public key, carried so a receiver can
  /// verify (the verifier binds it: node_id == BLAKE3(authorPubKey)). NOT part
  /// of [canonicalBytes] — the binding is enforced outside the signed payload.
  final Uint8List authorPubKey;

  ControlEntry withSignature(Uint8List sig, Uint8List pubKey) => ControlEntry(
    groupId: groupId,
    author: author,
    seq: seq,
    prevHash: prevHash,
    op: op,
    target: target,
    role: role,
    text: text,
    epochDescriptor: epochDescriptor,
    policyVersion: policyVersion,
    createdAtMs: createdAtMs,
    signature: sig,
    authorPubKey: pubKey,
  );

  /// The exact bytes the author signs — a canonical (stable field order) JSON
  /// of everything BUT the signature. Both ends must reproduce this identically
  /// for the signature to verify, so field order and encoding are fixed here.
  Uint8List canonicalBytes() {
    final map = {
      if (groupId != null) 'gid': groupId!.hex,
      'author': author.hex,
      'seq': seq,
      'prev': prevHash,
      'op': op.name,
      if (target != null) 'target': target!.hex,
      if (role != null) 'role': role!.name,
      if (text != null) 'text': text,
      if (epochDescriptor != null) 'ek': epochDescriptor!.toJson(),
      'pv': policyVersion,
      'ts': createdAtMs,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
  }

  Map<String, dynamic> toJson() => {
    if (groupId != null) 'gid': groupId!.hex,
    'author': author.hex,
    'seq': seq,
    'prev': prevHash,
    'op': op.name,
    if (target != null) 'target': target!.hex,
    if (role != null) 'role': role!.name,
    if (text != null) 'text': text,
    if (epochDescriptor != null) 'ek': epochDescriptor!.toJson(),
    'pv': policyVersion,
    'ts': createdAtMs,
    'sig': base64Encode(signature),
    if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
  };

  static ControlEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final author = j['author'], seq = j['seq'], prev = j['prev'];
    final opName = j['op'], pv = j['pv'], ts = j['ts'], sig = j['sig'];
    if (author is! String ||
        seq is! int ||
        prev is! String ||
        opName is! String ||
        pv is! int ||
        ts is! int ||
        sig is! String) {
      return null;
    }
    final op = ControlOp.fromName(opName);
    if (op == null || seq < 0 || pv < 0) return null;
    try {
      final epochDescriptor = j.containsKey('ek')
          ? GroupEpochDescriptor.fromJson(j['ek'])
          : null;
      if (j.containsKey('ek') && epochDescriptor == null) return null;
      return ControlEntry(
        groupId: j['gid'] is String ? NodeId.fromHex(j['gid'] as String) : null,
        author: NodeId.fromHex(author),
        seq: seq,
        prevHash: prev,
        op: op,
        target: j['target'] is String
            ? NodeId.fromHex(j['target'] as String)
            : null,
        role: GroupRole.fromName(j['role'] as String?),
        text: j['text'] is String ? j['text'] as String : null,
        epochDescriptor: epochDescriptor,
        policyVersion: pv,
        createdAtMs: ts,
        signature: Uint8List.fromList(base64Decode(sig)),
        authorPubKey: j['apk'] is String
            ? Uint8List.fromList(base64Decode(j['apk'] as String))
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// A member's current standing in the group (the folded result of the log).
class GroupMember {
  const GroupMember({
    required this.nodeId,
    required this.role,
    this.muted = false,
  });

  final NodeId nodeId;
  final GroupRole role;
  final bool muted;

  GroupMember copyWith({GroupRole? role, bool? muted}) => GroupMember(
    nodeId: nodeId,
    role: role ?? this.role,
    muted: muted ?? this.muted,
  );
}
