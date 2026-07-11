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
  const GroupManifest({
    required this.groupId,
    required this.owner,
    required this.genesisPubKey,
    required this.name,
    required this.createdAtMs,
  });

  final NodeId groupId; // opaque 32-byte group id (random at creation)
  final NodeId owner; // the genesis owner's node id = BLAKE3(genesisPubKey)
  final Uint8List genesisPubKey; // 32-byte ed25519 owner key
  final String name;
  final int createdAtMs;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'gid': groupId.hex,
        'owner': owner.hex,
        'gpk': base64Encode(genesisPubKey),
        'name': name,
        'ts': createdAtMs,
      };

  static GroupManifest? fromJson(Object? j) {
    if (j is! Map) return null;
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
      if (pk.length != 32) return null;
      return GroupManifest(
        groupId: NodeId.fromHex(gid),
        owner: NodeId.fromHex(owner),
        genesisPubKey: Uint8List.fromList(pk),
        name: name,
        createdAtMs: ts,
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
  setPolicy;

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
    required this.author,
    required this.seq,
    required this.prevHash,
    required this.op,
    required this.target,
    required this.role,
    required this.policyVersion,
    required this.createdAtMs,
    required this.signature,
    Uint8List? authorPubKey,
  }) : authorPubKey = authorPubKey ?? Uint8List(0);

  final NodeId author;
  final int seq;
  final String prevHash; // hex of the author's previous entry hash, or ''
  final ControlOp op;
  final NodeId? target; // member the op acts on (null for rotateEpoch/setPolicy)
  final GroupRole? role; // for setRole/addMember
  final int policyVersion;
  final int createdAtMs;
  final Uint8List signature; // ed25519 over canonicalBytes (verified app-side)

  /// The author's 32-byte ed25519 public key, carried so a receiver can
  /// verify (the verifier binds it: node_id == BLAKE3(authorPubKey)). NOT part
  /// of [canonicalBytes] — the binding is enforced outside the signed payload.
  final Uint8List authorPubKey;

  ControlEntry withSignature(Uint8List sig, Uint8List pubKey) => ControlEntry(
        author: author,
        seq: seq,
        prevHash: prevHash,
        op: op,
        target: target,
        role: role,
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
      'author': author.hex,
      'seq': seq,
      'prev': prevHash,
      'op': op.name,
      if (target != null) 'target': target!.hex,
      if (role != null) 'role': role!.name,
      'pv': policyVersion,
      'ts': createdAtMs,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
  }

  Map<String, dynamic> toJson() => {
        'author': author.hex,
        'seq': seq,
        'prev': prevHash,
        'op': op.name,
        if (target != null) 'target': target!.hex,
        if (role != null) 'role': role!.name,
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
      return ControlEntry(
        author: NodeId.fromHex(author),
        seq: seq,
        prevHash: prev,
        op: op,
        target: j['target'] is String
            ? NodeId.fromHex(j['target'] as String)
            : null,
        role: GroupRole.fromName(j['role'] as String?),
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
