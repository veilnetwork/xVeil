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

import 'package:crypto/crypto.dart' as crypto;

import '../core/ids.dart';
import 'group_epoch.dart';
import 'space_channel.dart';
import 'space_moderation.dart';
import 'space_post.dart';
import 'space_rules.dart';

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

/// Network visibility of a user-facing [SpaceManifest]. Secret spaces never
/// publish a discovery record; possession of an invite is required to learn
/// even their metadata.
enum SpaceVisibility {
  public,
  private,
  secret;

  static SpaceVisibility? fromName(String? value) {
    for (final visibility in values) {
      if (visibility.name == value) return visibility;
    }
    return null;
  }
}

/// Shared immutable wire root for a group chat, a user-facing Space, or an
/// infrastructure device group. The explicit version/kind is the domain
/// boundary; sharing a container does not make group chats into Spaces.
class SpaceManifest {
  SpaceManifest({
    required this.groupId,
    required this.owner,
    required this.genesisPubKey,
    required this.name,
    required this.createdAtMs,
    this.version = 1,
    this.kind,
    this.signatureAlgorithm,
    this.sovereignBundleHash,
    this.description,
    this.avatarContentId,
    this.coverContentId,
    this.visibility,
    this.discoverable,
    Uint8List? signature,
  }) : signature = signature ?? Uint8List(0);

  factory SpaceManifest.space({
    required NodeId spaceId,
    required NodeId owner,
    required Uint8List genesisPubKey,
    required String name,
    required int createdAtMs,
    String description = '',
    String? avatarContentId,
    String? coverContentId,
    SpaceVisibility visibility = SpaceVisibility.private,
    bool? discoverable,
  }) => SpaceManifest(
    groupId: spaceId,
    owner: owner,
    genesisPubKey: genesisPubKey,
    name: name,
    description: description,
    avatarContentId: avatarContentId,
    coverContentId: coverContentId,
    visibility: visibility,
    discoverable: visibility == SpaceVisibility.secret
        ? false
        : discoverable ?? false,
    createdAtMs: createdAtMs,
    version: spaceVersion,
    kind: spaceKind,
    signatureAlgorithm: 'ed25519',
  );

  final NodeId groupId; // opaque 32-byte group id (random at creation)
  NodeId get spaceId => groupId;
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

  /// Optional immutable genesis profile. Later changes are signed control-log
  /// entries rather than manifest rewrites.
  final String? description;
  final String? avatarContentId;
  final String? coverContentId;
  final SpaceVisibility? visibility;
  final bool? discoverable;

  /// SHA-256 of the encrypted sovereign bundle replicated with this device
  /// group. Its signed hash prevents a member device from replacing the blob.
  final Uint8List? sovereignBundleHash;
  final Uint8List signature;

  static const int sovereignDeviceVersion = 2;
  static const String sovereignDeviceKind = 'xveil.devices';
  static const int spaceVersion = 3;
  static const String spaceKind = 'xveil.space';

  bool get isLegacyGroup => version == 1;

  bool get isSpace =>
      version == spaceVersion &&
      kind == spaceKind &&
      signatureAlgorithm == 'ed25519' &&
      name.trim().isNotEmpty &&
      name.length <= 160 &&
      description != null &&
      description!.length <= 4096 &&
      (avatarContentId == null || avatarContentId!.length <= 512) &&
      (coverContentId == null || coverContentId!.length <= 512) &&
      visibility != null &&
      discoverable != null &&
      (visibility != SpaceVisibility.secret || !discoverable!) &&
      signature.isNotEmpty;

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
        if (version == spaceVersion) ...{
          'desc': description ?? '',
          if (avatarContentId != null) 'avatar': avatarContentId,
          if (coverContentId != null) 'cover': coverContentId,
          'visibility': visibility?.name,
          'discoverable': discoverable,
        },
        if (sovereignBundleHash != null)
          'sbh': base64Encode(sovereignBundleHash!),
      }),
    ),
  );

  SpaceManifest withSignature(Uint8List value) => SpaceManifest(
    groupId: groupId,
    owner: owner,
    genesisPubKey: genesisPubKey,
    name: name,
    createdAtMs: createdAtMs,
    version: version,
    kind: kind,
    signatureAlgorithm: signatureAlgorithm,
    sovereignBundleHash: sovereignBundleHash,
    description: description,
    avatarContentId: avatarContentId,
    coverContentId: coverContentId,
    visibility: visibility,
    discoverable: discoverable,
    signature: value,
  );

  bool sameGenesis(SpaceManifest other) =>
      base64Encode(canonicalBytes()) == base64Encode(other.canonicalBytes()) &&
      base64Encode(signature) == base64Encode(other.signature);

  /// Root fields that an owner-signed legacy -> Space upgrade may not change.
  /// Profile extensions are intentionally excluded; ids, keys, creation time
  /// and the original name continue to bind the existing logs.
  bool sameImmutableRoot(SpaceManifest other) =>
      groupId == other.groupId &&
      owner == other.owner &&
      base64Encode(genesisPubKey) == base64Encode(other.genesisPubKey) &&
      name == other.name &&
      createdAtMs == other.createdAtMs;

  Map<String, dynamic> toJson() => {
    'v': version,
    if (kind != null) 'kind': kind,
    'gid': groupId.hex,
    'owner': owner.hex,
    'gpk': base64Encode(genesisPubKey),
    'name': name,
    'ts': createdAtMs,
    if (signatureAlgorithm != null) 'alg': signatureAlgorithm,
    if (version == spaceVersion) ...{
      'desc': description ?? '',
      if (avatarContentId != null) 'avatar': avatarContentId,
      if (coverContentId != null) 'cover': coverContentId,
      'visibility': visibility?.name,
      'discoverable': discoverable,
    },
    if (sovereignBundleHash != null) 'sbh': base64Encode(sovereignBundleHash!),
    if (signature.isNotEmpty) 'msig': base64Encode(signature),
  };

  static SpaceManifest? fromJson(Object? j) {
    if (j is! Map) return null;
    final version = j['v'] is int ? j['v'] as int : 1;
    if (version != 1 &&
        version != sovereignDeviceVersion &&
        version != spaceVersion) {
      return null;
    }
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
      final visibility = SpaceVisibility.fromName(
        j['visibility'] is String ? j['visibility'] as String : null,
      );
      final description = j['desc'];
      final avatar = j['avatar'];
      final cover = j['cover'];
      final discoverable = j['discoverable'];
      if (version == spaceVersion &&
          (j['kind'] != spaceKind ||
              j['alg'] != 'ed25519' ||
              pk.length != 32 ||
              signature.length != 64 ||
              name.trim().isEmpty ||
              name.length > 160 ||
              visibility == null ||
              discoverable is! bool ||
              (visibility == SpaceVisibility.secret && discoverable) ||
              description is! String ||
              description.length > 4096 ||
              (avatar != null && (avatar is! String || avatar.length > 512)) ||
              (cover != null && (cover is! String || cover.length > 512)))) {
        return null;
      }
      return SpaceManifest(
        groupId: NodeId.fromHex(gid),
        owner: NodeId.fromHex(owner),
        genesisPubKey: Uint8List.fromList(pk),
        name: name,
        createdAtMs: ts,
        version: version,
        kind: j['kind'] is String ? j['kind'] as String : null,
        signatureAlgorithm: j['alg'] is String ? j['alg'] as String : null,
        sovereignBundleHash: bundleHash,
        description: description is String ? description : null,
        avatarContentId: avatar is String ? avatar : null,
        coverContentId: cover is String ? cover : null,
        visibility: visibility,
        discoverable: discoverable is bool ? discoverable : null,
        signature: signature,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Source compatibility for the established group-chat APIs. Group and Space
/// share a wire container/store, but remain distinct user-facing entities.
@Deprecated('Use SpaceManifest')
typedef GroupManifest = SpaceManifest;

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
  setDescription, // update Space description (payload in ControlEntry.text)
  publishRules,
  acceptRules,
  moderate,
  revokeModeration,
  createChannel,
  updateChannel,
  transferOwnership,
  checkpoint,
  leave; // the author removes THEMSELVES (any member may leave)

  static ControlOp? fromName(String? s) {
    for (final o in ControlOp.values) {
      if (o.name == s) return o;
    }
    return null;
  }
}

/// Signed terminal of one member's publication chain at the instant their
/// publishing authority is revoked. `seq == -1` means that the member had no
/// accepted publications; otherwise [hash] binds the exact terminal row.
class SpacePostBoundary {
  const SpacePostBoundary({required this.seq, required this.hash});

  final int seq;
  final String hash;

  bool get isStructurallyValid =>
      (seq == -1 && hash.isEmpty) ||
      (seq >= 0 && RegExp(r'^[0-9a-f]{64}$').hasMatch(hash));

  Map<String, dynamic> toJson() => {'seq': seq, 'hash': hash};

  static SpacePostBoundary? fromJson(Object? value) {
    if (value is! Map || value['seq'] is! int || value['hash'] is! String) {
      return null;
    }
    final boundary = SpacePostBoundary(
      seq: value['seq'] as int,
      hash: value['hash'] as String,
    );
    return boundary.isStructurallyValid ? boundary : null;
  }
}

/// One entry in a group's control-log: an [op] by [author] at their own
/// monotonic [seq], chained by [prevHash] (hash of the author's previous
/// entry, or empty for their first), bound to the [policyVersion] it was
/// authored against, and signed ([signature] over [canonicalBytes]).
class ControlEntry {
  ControlEntry({
    this.version = 1,
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
    this.channel,
    this.channelControl,
    this.postBoundary,
    this.controlCheckpoint,
    this.rules,
    this.rulesAcceptance,
    this.moderationAction,
    this.moderationRevocation,
    Uint8List? authorPubKey,
  }) : authorPubKey = authorPubKey ?? Uint8List(0);

  /// V1 is the deployed legacy row whose `prev` field was informational.
  /// V2 makes `(seq, prevHash)` a strict per-author signed hash chain. V3 adds
  /// a signed publication revocation boundary. V4 carries a reusable Merkle
  /// control checkpoint. V5 carries an opaque restricted/secret channel
  /// control revision. V6 atomically transfers the one effective owner role;
  /// the immutable manifest owner remains the genesis trust root. V7 carries
  /// a versioned Space rules document or one member's acknowledgement. V8
  /// carries an immutable moderation action or a signed revocation of one.
  final int version;

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
  final SpaceChannel? channel; // typed payload for nested channel mutations
  final SpaceChannelControlEnvelope? channelControl;
  final SpacePostBoundary? postBoundary;
  final SpaceControlCheckpoint? controlCheckpoint;
  final SpaceRulesVersion? rules;
  final SpaceRulesAcceptance? rulesAcceptance;
  final SpaceModerationAction? moderationAction;
  final SpaceModerationRevocation? moderationRevocation;

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

  bool get isStructurallyValid =>
      (version == 1 ||
          version == 2 ||
          version == 3 ||
          version == 4 ||
          version == 5 ||
          version == 6 ||
          version == 7 ||
          version == 8) &&
      seq >= 0 &&
      policyVersion >= 0 &&
      createdAtMs >= 0 &&
      (version == 1
          ? prevHash.length <= 128
          : (seq == 0
                ? prevHash.isEmpty
                : RegExp(r'^[0-9a-f]{64}$').hasMatch(prevHash))) &&
      signature.length <= 16384 &&
      authorPubKey.length <= 16384 &&
      (op == ControlOp.setName
          ? text != null &&
                text!.trim().isNotEmpty &&
                text == text!.trim() &&
                text!.length <= 160
          : op == ControlOp.setDescription
          ? text != null && text!.length <= 4096
          : true) &&
      (version == 4
          ? op == ControlOp.checkpoint
          : op != ControlOp.checkpoint) &&
      (version == 5
          ? (op == ControlOp.createChannel || op == ControlOp.updateChannel) &&
                channel == null &&
                channelControl != null &&
                channelControl!.isStructurallyValid
          : channelControl == null) &&
      (version == 6
          ? op == ControlOp.transferOwnership &&
                groupId != null &&
                target != null &&
                role == null &&
                text == null &&
                epochDescriptor == null &&
                channel == null &&
                channelControl == null &&
                postBoundary == null &&
                controlCheckpoint == null
          : op != ControlOp.transferOwnership) &&
      (version == 7
          ? ((op == ControlOp.publishRules &&
                        rules != null &&
                        rules!.isStructurallyValid &&
                        rulesAcceptance == null) ||
                    (op == ControlOp.acceptRules &&
                        rules == null &&
                        rulesAcceptance != null &&
                        rulesAcceptance!.isStructurallyValid)) &&
                groupId != null &&
                target == null &&
                role == null &&
                text == null &&
                epochDescriptor == null &&
                channel == null &&
                channelControl == null &&
                postBoundary == null &&
                controlCheckpoint == null
          : rules == null &&
                rulesAcceptance == null &&
                op != ControlOp.publishRules &&
                op != ControlOp.acceptRules) &&
      (version == 8
          ? ((op == ControlOp.moderate &&
                        moderationAction != null &&
                        moderationAction!.isStructurallyValid &&
                        moderationRevocation == null &&
                        target == moderationAction!.target &&
                        (moderationAction!.kind.removesMembership
                            ? postBoundary != null
                            : epochDescriptor == null &&
                                  (!moderationAction!.kind.blocksPosts ||
                                      postBoundary != null))) ||
                    (op == ControlOp.revokeModeration &&
                        moderationAction == null &&
                        moderationRevocation != null &&
                        moderationRevocation!.isStructurallyValid &&
                        epochDescriptor == null &&
                        postBoundary == null)) &&
                groupId != null &&
                target != null &&
                role == null &&
                text == null &&
                channel == null &&
                channelControl == null &&
                controlCheckpoint == null &&
                rules == null &&
                rulesAcceptance == null
          : moderationAction == null &&
                moderationRevocation == null &&
                op != ControlOp.moderate &&
                op != ControlOp.revokeModeration) &&
      (controlCheckpoint == null
          ? op != ControlOp.checkpoint
          : version == 4 &&
                op == ControlOp.checkpoint &&
                controlCheckpoint!.isStructurallyValid &&
                target == null &&
                role == null &&
                text == null &&
                epochDescriptor == null &&
                channel == null &&
                channelControl == null &&
                postBoundary == null) &&
      (postBoundary == null ||
          (version >= 3 &&
              postBoundary!.isStructurallyValid &&
              (op == ControlOp.mute ||
                  op == ControlOp.removeMember ||
                  op == ControlOp.ban ||
                  (op == ControlOp.moderate &&
                      moderationAction?.kind.blocksPosts == true) ||
                  op == ControlOp.leave) &&
              (op == ControlOp.leave ? target == null : target != null)));

  ControlEntry withSignature(Uint8List sig, Uint8List pubKey) => ControlEntry(
    version: version,
    groupId: groupId,
    author: author,
    seq: seq,
    prevHash: prevHash,
    op: op,
    target: target,
    role: role,
    text: text,
    epochDescriptor: epochDescriptor,
    channel: channel,
    channelControl: channelControl,
    postBoundary: postBoundary,
    controlCheckpoint: controlCheckpoint,
    rules: rules,
    rulesAcceptance: rulesAcceptance,
    moderationAction: moderationAction,
    moderationRevocation: moderationRevocation,
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
      if (version >= 2) 'v': version,
      if (groupId != null) 'gid': groupId!.hex,
      'author': author.hex,
      'seq': seq,
      'prev': prevHash,
      'op': op.name,
      if (target != null) 'target': target!.hex,
      if (role != null) 'role': role!.name,
      if (text != null) 'text': text,
      if (epochDescriptor != null) 'ek': epochDescriptor!.toJson(),
      if (channel != null) 'channel': channel!.toJson(),
      if (channelControl != null) 'channelControl': channelControl!.toJson(),
      if (postBoundary != null) 'postBoundary': postBoundary!.toJson(),
      if (controlCheckpoint != null)
        'controlCheckpoint': controlCheckpoint!.toJson(),
      if (rules != null) 'rules': rules!.toJson(),
      if (rulesAcceptance != null) 'rulesAcceptance': rulesAcceptance!.toJson(),
      if (moderationAction != null)
        'moderationAction': moderationAction!.toJson(),
      if (moderationRevocation != null)
        'moderationRevocation': moderationRevocation!.toJson(),
      'pv': policyVersion,
      'ts': createdAtMs,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
  }

  Map<String, dynamic> toJson() => {
    if (version >= 2) 'v': version,
    if (groupId != null) 'gid': groupId!.hex,
    'author': author.hex,
    'seq': seq,
    'prev': prevHash,
    'op': op.name,
    if (target != null) 'target': target!.hex,
    if (role != null) 'role': role!.name,
    if (text != null) 'text': text,
    if (epochDescriptor != null) 'ek': epochDescriptor!.toJson(),
    if (channel != null) 'channel': channel!.toJson(),
    if (channelControl != null) 'channelControl': channelControl!.toJson(),
    if (postBoundary != null) 'postBoundary': postBoundary!.toJson(),
    if (controlCheckpoint != null)
      'controlCheckpoint': controlCheckpoint!.toJson(),
    if (rules != null) 'rules': rules!.toJson(),
    if (rulesAcceptance != null) 'rulesAcceptance': rulesAcceptance!.toJson(),
    if (moderationAction != null)
      'moderationAction': moderationAction!.toJson(),
    if (moderationRevocation != null)
      'moderationRevocation': moderationRevocation!.toJson(),
    'pv': policyVersion,
    'ts': createdAtMs,
    'sig': base64Encode(signature),
    if (authorPubKey.isNotEmpty) 'apk': base64Encode(authorPubKey),
  };

  static ControlEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final version = j['v'] ?? 1;
    final author = j['author'], seq = j['seq'], prev = j['prev'];
    final opName = j['op'], pv = j['pv'], ts = j['ts'], sig = j['sig'];
    if (version is! int ||
        (version != 1 &&
            version != 2 &&
            version != 3 &&
            version != 4 &&
            version != 5 &&
            version != 6 &&
            version != 7 &&
            version != 8) ||
        author is! String ||
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
      final channel = j.containsKey('channel')
          ? SpaceChannel.fromJson(j['channel'])
          : null;
      if (j.containsKey('channel') && channel == null) return null;
      final channelControl = j.containsKey('channelControl')
          ? SpaceChannelControlEnvelope.fromJson(j['channelControl'])
          : null;
      if (j.containsKey('channelControl') && channelControl == null) {
        return null;
      }
      final postBoundary = j.containsKey('postBoundary')
          ? SpacePostBoundary.fromJson(j['postBoundary'])
          : null;
      if (j.containsKey('postBoundary') && postBoundary == null) return null;
      final controlCheckpoint = j.containsKey('controlCheckpoint')
          ? SpaceControlCheckpoint.fromJson(j['controlCheckpoint'])
          : null;
      if (j.containsKey('controlCheckpoint') && controlCheckpoint == null) {
        return null;
      }
      final rules = j.containsKey('rules')
          ? SpaceRulesVersion.fromJson(j['rules'])
          : null;
      if (j.containsKey('rules') && rules == null) return null;
      final rulesAcceptance = j.containsKey('rulesAcceptance')
          ? SpaceRulesAcceptance.fromJson(j['rulesAcceptance'])
          : null;
      if (j.containsKey('rulesAcceptance') && rulesAcceptance == null) {
        return null;
      }
      final moderationAction = j.containsKey('moderationAction')
          ? SpaceModerationAction.fromJson(j['moderationAction'])
          : null;
      if (j.containsKey('moderationAction') && moderationAction == null) {
        return null;
      }
      final moderationRevocation = j.containsKey('moderationRevocation')
          ? SpaceModerationRevocation.fromJson(j['moderationRevocation'])
          : null;
      if (j.containsKey('moderationRevocation') &&
          moderationRevocation == null) {
        return null;
      }
      final entry = ControlEntry(
        version: version,
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
        channel: channel,
        channelControl: channelControl,
        postBoundary: postBoundary,
        controlCheckpoint: controlCheckpoint,
        rules: rules,
        rulesAcceptance: rulesAcceptance,
        moderationAction: moderationAction,
        moderationRevocation: moderationRevocation,
        policyVersion: pv,
        createdAtMs: ts,
        signature: Uint8List.fromList(base64Decode(sig)),
        authorPubKey: j['apk'] is String
            ? Uint8List.fromList(base64Decode(j['apk'] as String))
            : null,
      );
      return entry.isStructurallyValid ? entry : null;
    } catch (_) {
      return null;
    }
  }
}

/// Digest used both by V2 `prevHash` and deterministic same-seq fork choice.
/// The signature is included: the predecessor is the exact accepted signed
/// row, not merely an unsigned payload that could carry another signature.
String controlEntryHash(ControlEntry entry) => crypto.sha256.convert(<int>[
  ...entry.canonicalBytes(),
  ...entry.signature,
]).toString();

/// A member's current standing in the group (the folded result of the log).
class GroupMember {
  const GroupMember({
    required this.nodeId,
    required this.role,
    this.muted = false,
    this.joinedAtMs = 0,
  });

  final NodeId nodeId;
  final GroupRole role;
  final bool muted;
  final int joinedAtMs;

  GroupMember copyWith({GroupRole? role, bool? muted}) => GroupMember(
    nodeId: nodeId,
    role: role ?? this.role,
    muted: muted ?? this.muted,
    joinedAtMs: joinedAtMs,
  );
}
