// Group service (groups epic, phase 0, brick 3): create groups, sign + append
// control-log ops and messages, persist everything in the deniable store, and
// expose the folded state + validated message list. No wire/DHT yet — this is
// the local substance a peer-sync brick will later drive.
//
// Persistence (settings JSON in the deniable store):
//   'groups.index'      -> ["<groupId hex>", ...]
//   'group:<id>'        -> {"m": manifest, "c": [controlEntry...], "g": [msg...]}
//
// The identity crypto (native ed25519) sits behind an injectable [GroupSigner]
// so the whole service is unit-tested with a fake — the real signer wraps
// group_crypto + the app's deniable identity TOML.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;

import '../core/ids.dart';
import '../domain/chat.dart' show MessageDirection;
import '../domain/device_sync.dart';
import '../domain/device_link.dart';
import '../domain/group.dart';
import '../domain/group_content.dart';
import '../domain/group_message.dart';
import '../domain/group_policy.dart';
import '../domain/group_reaction.dart';
import '../data/node/embedded_node.dart';
import '../data/transport/bootstrap_invite.dart';
import '../data/storage/storage.dart';
import 'app_controller.dart';
import 'group_crypto.dart';
import 'messaging.dart';
import 'providers.dart';

/// The identity operations the service needs — injectable for tests.
abstract class GroupSigner {
  /// Our own node id + public key (the genesis material when we create).
  NodeId get selfId;
  Uint8List get selfPubKey;

  ControlEntry signControl(ControlEntry unsigned);
  GroupMessage signMessage(GroupMessage unsigned);
  GroupReaction signReaction(GroupReaction unsigned);
  GroupContentRequest signContentRequest(GroupContentRequest unsigned);
  bool verifyControl(ControlEntry e);
  bool verifyMessage(GroupMessage m);
  bool verifyReaction(GroupReaction r);
  bool verifyContentRequest(GroupContentRequest r);
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  });
}

abstract class SovereignGroupSigner {
  String get algorithm;
  NodeId get nodeId;
  Uint8List get publicKey;
  Uint8List sign(Uint8List message);
  void close();
}

/// Opaque native recovery signer. The eventual normal path decrypts the local
/// sovereign bundle; this phrase-derived path remains the recovery bootstrap.
final class NativeSovereignGroupSigner implements SovereignGroupSigner {
  NativeSovereignGroupSigner._(this._inner);
  final veil.VeilSovereignSigner _inner;

  factory NativeSovereignGroupSigner.openRecoveryPhrase(String phrase) =>
      NativeSovereignGroupSigner._(veil.VeilSovereignSigner.open(phrase));

  factory NativeSovereignGroupSigner.openBundle(
    Uint8List bundle,
    String phrase,
  ) => NativeSovereignGroupSigner._(
    veil.VeilSovereignSigner.openBundle(bundle, phrase),
  );

  factory NativeSovereignGroupSigner.openRecoveryCertificate(
    Uint8List certificate,
    String recoveryCode,
  ) => NativeSovereignGroupSigner._(
    veil.VeilSovereignSigner.openRecoveryCertificate(certificate, recoveryCode),
  );

  @override
  String get algorithm => _inner.algorithm;
  @override
  NodeId get nodeId => NodeId(Uint8List.fromList(_inner.nodeId));
  @override
  Uint8List get publicKey => Uint8List.fromList(_inner.publicKey);
  @override
  Uint8List sign(Uint8List message) => _inner.sign(message);
  @override
  void close() => _inner.close();
}

/// Real signer: native ed25519 over the deniable identity TOML.
class NativeGroupSigner implements GroupSigner {
  NativeGroupSigner({
    required this.identityToml,
    required NodeId selfId,
    required Uint8List selfPubKey,
    this.lib,
  }) : _selfId = selfId,
       _selfPubKey = selfPubKey;

  final String identityToml;
  final DynamicLibrary? lib;
  final NodeId _selfId;
  final Uint8List _selfPubKey;

  @override
  NodeId get selfId => _selfId;
  @override
  Uint8List get selfPubKey => _selfPubKey;

  @override
  ControlEntry signControl(ControlEntry unsigned) => signControlEntry(
    identityToml: identityToml,
    unsigned: unsigned,
    lib: lib,
  );
  @override
  GroupMessage signMessage(GroupMessage unsigned) => signGroupMessage(
    identityToml: identityToml,
    unsigned: unsigned,
    lib: lib,
  );
  @override
  GroupReaction signReaction(GroupReaction unsigned) => signGroupReaction(
    identityToml: identityToml,
    unsigned: unsigned,
    lib: lib,
  );
  @override
  GroupContentRequest signContentRequest(GroupContentRequest unsigned) =>
      signGroupContentRequest(
        identityToml: identityToml,
        unsigned: unsigned,
        lib: lib,
      );
  @override
  bool verifyControl(ControlEntry e) => verifyControlEntry(e, lib: lib);
  @override
  bool verifyMessage(GroupMessage m) => verifyGroupMessage(m, lib: lib);
  @override
  bool verifyReaction(GroupReaction r) => verifyGroupReaction(r, lib: lib);
  @override
  bool verifyContentRequest(GroupContentRequest r) =>
      verifyGroupContentRequest(r, lib: lib);
  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) {
    return veil.verifySovereignSignature(
      algorithm: algorithm,
      nodeId: nodeId.bytes,
      publicKey: publicKey,
      message: message,
      signature: signature,
    );
  }
}

/// One group's stored data.
class GroupBundle {
  GroupBundle({
    required this.manifest,
    required this.control,
    required this.messages,
    this.reactions = const [],
    this.sovereignBundle,
  });
  final GroupManifest manifest;
  final List<ControlEntry> control;
  final List<GroupMessage> messages;
  final List<GroupReaction> reactions;
  final Uint8List? sovereignBundle;
}

class GroupLogCompaction {
  const GroupLogCompaction({
    required this.messagesBefore,
    required this.messagesAfter,
    required this.controlBefore,
    required this.controlAfter,
    required this.reactionsBefore,
    required this.reactionsAfter,
  });

  final int messagesBefore;
  final int messagesAfter;
  final int controlBefore;
  final int controlAfter;
  final int reactionsBefore;
  final int reactionsAfter;

  bool get changed =>
      messagesBefore != messagesAfter ||
      controlBefore != controlAfter ||
      reactionsBefore != reactionsAfter;
}

/// Ships a group snapshot [bundleJson] durably to [peer] (direct fanout, v1).
typedef GroupSnapshotSender =
    Future<void> Function(NodeId peer, NodeId groupId, String bundleJson);

class GroupService {
  GroupService(
    this._storage,
    this._signer, {
    GroupSnapshotSender? send,
    this.sendContentRequest,
    this.grantContentServe,
    this.startContentPull,
  }) : _send = send;
  final Storage _storage;
  final GroupSigner _signer;
  final GroupSnapshotSender? _send;

  /// Ships a signed content-fetch request to the holder (wire layer).
  final Future<void> Function(NodeId holder, String requestJson)?
  sendContentRequest;

  /// Opens the serve gate for an authorized member (wire layer grant).
  final void Function(NodeId peer, String cid)? grantContentServe;

  /// Starts the standard content pull of [cid] from a holder (wire layer).
  final Future<void> Function(NodeId holder, String cid)? startContentPull;

  /// Bumped on every persisted mutation (local op/post OR an ingested
  /// snapshot) so open group screens re-fetch. Cheap: the UI reads on change.
  final ValueNotifier<int> changes = ValueNotifier(0);

  /// Our own node id — the composer uses it to align outgoing bubbles.
  NodeId get selfId => _signer.selfId;

  int _now() => DateTime.now().millisecondsSinceEpoch;

  bool _validManifest(GroupManifest manifest) {
    if (manifest.version == 1) return manifest.genesisPubKey.length == 32;
    if (!manifest.isSovereignDevice ||
        manifest.name != kDeviceGroupName ||
        manifest.signatureAlgorithm == null) {
      return false;
    }
    if (manifest.signatureAlgorithm != 'ed25519' &&
        manifest.sovereignBundleHash == null) {
      return false;
    }
    return _signer.verifySovereign(
      algorithm: manifest.signatureAlgorithm!,
      nodeId: manifest.owner,
      publicKey: manifest.genesisPubKey,
      message: manifest.canonicalBytes(),
      signature: manifest.signature,
    );
  }

  bool _validSovereignBundle(
    GroupManifest manifest,
    Uint8List? encryptedBundle,
  ) {
    final expected = manifest.sovereignBundleHash;
    if (expected == null) return encryptedBundle == null;
    if (encryptedBundle == null || encryptedBundle.length > 16 * 1024) {
      return false;
    }
    return listEquals(veil.VeilCrypto.sha256(encryptedBundle), expected);
  }

  bool _validControlFor(GroupManifest manifest, ControlEntry e) {
    if (manifest.isSovereignDevice) {
      final membershipOp =
          e.op == ControlOp.addMember || e.op == ControlOp.removeMember;
      final shapeOk =
          e.target != null &&
          (e.op != ControlOp.addMember || e.role == GroupRole.member) &&
          (e.op != ControlOp.removeMember || e.role == null);
      return _validManifest(manifest) &&
          e.groupId == manifest.groupId &&
          e.author == manifest.owner &&
          listEquals(e.authorPubKey, manifest.genesisPubKey) &&
          membershipOp &&
          shapeOk &&
          _signer.verifySovereign(
            algorithm: manifest.signatureAlgorithm!,
            nodeId: e.author,
            publicKey: e.authorPubKey,
            message: e.canonicalBytes(),
            signature: e.signature,
          );
    }
    return (e.groupId == null || e.groupId == manifest.groupId) &&
        _signer.verifyControl(e);
  }

  bool _validMessageFor(NodeId groupId, GroupMessage m) =>
      m.groupId == groupId && _signer.verifyMessage(m);

  bool _validReactionFor(NodeId groupId, GroupReaction r) =>
      r.groupId == groupId && _signer.verifyReaction(r);

  List<GroupReaction> _compactReactions(
    NodeId groupId,
    List<GroupReaction> input,
  ) {
    final latest = <String, GroupReaction>{};
    final heads = <String, GroupReaction>{};
    for (final r in input) {
      if (!_validReactionFor(groupId, r)) continue;
      final key = '${r.author.hex}|${r.target}';
      final current = latest[key];
      if (current == null || isNewerGroupReaction(r, current)) {
        latest[key] = r;
      }
      final head = heads[r.author.hex];
      if (head == null || r.seq > head.seq) heads[r.author.hex] = r;
    }
    final keep = <String>{
      for (final r in latest.values) '${r.author.hex}:${r.seq}',
      for (final r in heads.values) '${r.author.hex}:${r.seq}',
    };
    return [
      for (final r in input)
        if (_validReactionFor(groupId, r) &&
            keep.contains('${r.author.hex}:${r.seq}'))
          r,
    ];
  }

  List<GroupMessage> _compactDeviceMessages(
    NodeId groupId,
    List<GroupMessage> input,
  ) {
    final latest =
        <
          (DeviceSyncKind, String),
          ({DeviceSyncEvent event, GroupMessage message})
        >{};
    final heads = <String, GroupMessage>{};
    final unknown = <String>{};
    for (final m in input) {
      if (!_validMessageFor(groupId, m)) continue;
      final head = heads[m.author.hex];
      if (head == null || m.seq > head.seq) heads[m.author.hex] = m;
      final event = DeviceSyncEvent.fromBody(m.body);
      if (event == null) {
        // Forward-compatible: an older build must not erase a newer event kind.
        unknown.add(m.ref);
        continue;
      }
      final key = (event.kind, event.key);
      final current = latest[key];
      if (current == null ||
          isNewerDeviceSync(event, current.event) ||
          (!isNewerDeviceSync(current.event, event) &&
              _messageIdentityCompare(m, current.message) > 0)) {
        latest[key] = (event: event, message: m);
      }
    }
    final keep = <String>{
      ...unknown,
      for (final v in latest.values) v.message.ref,
      for (final m in heads.values) m.ref,
    };
    return [
      for (final m in input)
        if (_validMessageFor(groupId, m) && keep.contains(m.ref)) m,
    ];
  }

  int _messageIdentityCompare(GroupMessage a, GroupMessage b) {
    final author = a.author.hex.compareTo(b.author.hex);
    return author != 0 ? author : a.seq.compareTo(b.seq);
  }

  /// Compact only logs whose old entries are superseded state. Ordinary group
  /// messages are chat history and are never removed. Reaction winners and
  /// device-sync LWW winners are retained together with each author's max-seq
  /// row, preserving the current fold, next-seq allocation, and gap-fill
  /// high-water. Invalid/cross-group rows are scrubbed as part of the rewrite.
  Future<GroupLogCompaction?> compactStateLogs(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return null;
    final control = [
      for (final e in b.control)
        if (_validControlFor(b.manifest, e)) e,
    ];
    final messages = b.manifest.name == kDeviceGroupName
        ? _compactDeviceMessages(groupId, b.messages)
        : [
            for (final m in b.messages)
              if (_validMessageFor(groupId, m)) m,
          ];
    final reactions = _compactReactions(groupId, b.reactions);
    final result = GroupLogCompaction(
      messagesBefore: b.messages.length,
      messagesAfter: messages.length,
      controlBefore: b.control.length,
      controlAfter: control.length,
      reactionsBefore: b.reactions.length,
      reactionsAfter: reactions.length,
    );
    if (result.changed) {
      await _save(
        GroupBundle(
          manifest: b.manifest,
          control: control,
          messages: messages,
          reactions: reactions,
          sovereignBundle: b.sovereignBundle,
        ),
      );
    }
    return result;
  }

  Future<List<String>> _index() async {
    final raw = await _storage.getSetting('groups.index');
    if (raw == null || raw.isEmpty) return [];
    try {
      final d = jsonDecode(raw);
      return d is List ? d.whereType<String>().toList() : [];
    } catch (_) {
      return [];
    }
  }

  Future<void> _setIndex(List<String> ids) =>
      _storage.putSetting('groups.index', jsonEncode(ids));

  String _key(NodeId groupId) => 'group:${groupId.hex}';

  /// Read a group's serialized bundle. It lives in the CHUNKED file-store, not a
  /// single setting: an inline image attachment can push the JSON well past the
  /// ~4 KB single-setting cap (HvException.PayloadTooLarge). Falls back to the
  /// legacy settings key for groups written before the store moved.
  Future<String?> _loadBundleRaw(NodeId groupId) async {
    final blob = await _storage.loadFile(_key(groupId));
    if (blob != null) return utf8.decode(blob);
    return _storage.getSetting(_key(groupId));
  }

  Future<GroupBundle?> load(NodeId groupId) async {
    final raw = await _loadBundleRaw(groupId);
    if (raw == null) return null;
    try {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      final manifest = GroupManifest.fromJson(d['m']);
      if (manifest == null || !_validManifest(manifest)) return null;
      final control = (d['c'] as List? ?? const [])
          .map(ControlEntry.fromJson)
          .whereType<ControlEntry>()
          .toList();
      final messages = (d['g'] as List? ?? const [])
          .map(GroupMessage.fromJson)
          .whereType<GroupMessage>()
          .toList();
      final reactions = (d['r'] as List? ?? const [])
          .map(GroupReaction.fromJson)
          .whereType<GroupReaction>()
          .toList();
      final sovereignBundle = d['s'] is String
          ? Uint8List.fromList(base64Decode(d['s'] as String))
          : null;
      if (!_validSovereignBundle(manifest, sovereignBundle)) return null;
      return GroupBundle(
        manifest: manifest,
        control: control,
        messages: messages,
        reactions: reactions,
        sovereignBundle: sovereignBundle,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(GroupBundle b) async {
    // Chunked file-store (not putSetting): the bundle carries inline media that
    // overflows the single-setting cap. storeFile replaces the prior blob (or
    // no-ops if byte-identical) and chunks large values across commits.
    final json = jsonEncode({
      'm': b.manifest.toJson(),
      'c': b.control.map((e) => e.toJson()).toList(),
      'g': b.messages.map((m) => m.toJson()).toList(),
      'r': b.reactions.map((x) => x.toJson()).toList(),
      if (b.sovereignBundle != null) 's': base64Encode(b.sovereignBundle!),
    });
    await _storage.storeFile(
      _key(b.manifest.groupId),
      Uint8List.fromList(utf8.encode(json)),
      name: 'group',
    );
    changes.value++;
  }

  /// The groups we are STILL A MEMBER of, newest-created last. A group we left
  /// (or were never/no-longer a member of, per the folded control-log) is hidden
  /// without deleting its blob — the stored data lingers deniably and a fresh
  /// re-add simply folds us back in. (An admin-removal we never received doesn't
  /// hide the group on our side: we don't learn we were removed — no oracle.)
  Future<
    List<
      ({
        NodeId groupId,
        String name,
        int unread,
        bool muted,
        String preview,
        int lastTs,
      })
    >
  >
  listGroups() async {
    final out =
        <
          ({
            NodeId groupId,
            String name,
            int unread,
            bool muted,
            String preview,
            int lastTs,
          })
        >[];
    for (final hex in await _index()) {
      try {
        final b = await load(NodeId.fromHex(hex));
        if (b == null) continue;
        final state = foldControlLog(
          owner: b.manifest.owner,
          entries: b.control,
          verify: (e) => _validControlFor(b.manifest, e),
          initialName: b.manifest.name,
        ).state;
        if (!state.isMember(_signer.selfId)) continue;
        // Device groups are infrastructure, not chats — never listed.
        if (b.manifest.name == kDeviceGroupName) continue;
        final gid = b.manifest.groupId;
        // One validated pass powers unread AND the last-message preview.
        final wm =
            int.tryParse(await _storage.getSetting('group.seen:$hex') ?? '') ??
            0;
        final msgs = await messagesOf(gid);
        final last = msgs.isEmpty ? null : msgs.last;
        out.add((
          groupId: gid,
          name: state.name,
          unread: msgs
              .where((m) => m.createdAtMs > wm && m.author != _signer.selfId)
              .length,
          muted: await isGroupMuted(gid),
          preview: last == null ? '' : previewOf(last),
          lastTs: last?.createdAtMs ?? 0,
        ));
      } catch (_) {}
    }
    return out;
  }

  /// Create a group named [name] with us as the sole owner. Returns its id.
  Future<NodeId> createGroup(String name) async {
    final gid = _randomGroupId();
    final manifest = GroupManifest(
      groupId: gid,
      owner: _signer.selfId,
      genesisPubKey: _signer.selfPubKey,
      name: name,
      createdAtMs: _now(),
    );
    await _save(GroupBundle(manifest: manifest, control: [], messages: []));
    final idx = await _index();
    idx.add(gid.hex);
    await _setIndex(idx);
    return gid;
  }

  NodeId _randomGroupId() {
    final rnd = Random.secure();
    return NodeId(
      Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256))),
    );
  }

  /// The current folded state of [groupId], or null if unknown.
  Future<GroupState?> stateOf(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return null;
    return foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
      initialName: b.manifest.name,
    ).state;
  }

  /// The next per-author seq for [author] in a list of entries carrying seq.
  int _nextSeq(Iterable<int> seqs) {
    var max = -1;
    for (final s in seqs) {
      if (s > max) max = s;
    }
    return max + 1;
  }

  /// Append a control op authored by us. Returns true if it was valid (signed,
  /// permitted against the current state) and persisted; false otherwise.
  Future<bool> addControlOp(
    NodeId groupId,
    ControlOp op, {
    NodeId? target,
    GroupRole? role,
    String? text,
  }) async {
    final b = await load(groupId);
    if (b == null) return false;
    if (b.manifest.name == kDeviceGroupName) return false;
    final mySeq = _nextSeq(
      b.control
          .where(
            (e) =>
                e.author == _signer.selfId && _validControlFor(b.manifest, e),
          )
          .map((e) => e.seq),
    );
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final pv = state.policyVersion;
    final unsigned = ControlEntry(
      groupId: groupId,
      author: _signer.selfId,
      seq: mySeq,
      prevHash: '',
      op: op,
      target: target,
      role: role,
      text: text,
      policyVersion: pv,
      createdAtMs: _now(),
      signature: Uint8List(0),
    );
    final signed = _signer.signControl(unsigned);
    // Validate against a fold INCLUDING the new entry: if it's rejected (no
    // permission), don't persist — we never commit an op that wouldn't apply.
    final candidate = [...b.control, signed];
    final folded = foldControlLog(
      owner: b.manifest.owner,
      entries: candidate,
      verify: (e) => _validControlFor(b.manifest, e),
    );
    if (folded.rejected.any(
      (e) =>
          identical(e, signed) ||
          (e.author == signed.author && e.seq == signed.seq),
    )) {
      return false;
    }
    await _save(
      GroupBundle(
        manifest: b.manifest,
        control: candidate,
        messages: b.messages,
        reactions: b.reactions,
        sovereignBundle: b.sovereignBundle,
      ),
    );
    // Adding a member: that peer needs the WHOLE history → full snapshot to all
    // (idempotent for existing members). Every other op ships as a delta so we
    // don't re-send the group's messages/images on a mute/role/policy change.
    if (op == ControlOp.addMember) {
      unawaited(broadcast(groupId));
    } else {
      unawaited(broadcastDelta(groupId, control: [signed]));
    }
    return true;
  }

  /// Rename [groupId] (admins+). The name folds into every member's view via a
  /// signed `setName` op (delta-broadcast). Returns false if we lack permission.
  Future<bool> renameGroup(NodeId groupId, String name) =>
      addControlOp(groupId, ControlOp.setName, text: name.trim());

  /// Leave [groupId]: append a signed `leave` op (removes only us), tell the
  /// remaining members, and let [listGroups] hide it (the fold drops us). Idempotent
  /// if we already aren't a member; false for the owner (who cannot leave, v1).
  Future<bool> leaveGroup(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return false;
    if (b.manifest.name == kDeviceGroupName) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final me = state.memberOf(_signer.selfId);
    if (me == null) return true; // already gone
    if (me.role == GroupRole.owner) return false; // owner can't leave (v1)
    final mySeq = _nextSeq(
      b.control
          .where(
            (e) =>
                e.author == _signer.selfId && _validControlFor(b.manifest, e),
          )
          .map((e) => e.seq),
    );
    final unsigned = ControlEntry(
      groupId: groupId,
      author: _signer.selfId,
      seq: mySeq,
      prevHash: '',
      op: ControlOp.leave,
      target: null,
      role: null,
      policyVersion: state.policyVersion,
      createdAtMs: _now(),
      signature: Uint8List(0),
    );
    final signed = _signer.signControl(unsigned);
    final candidate = [...b.control, signed];
    final folded = foldControlLog(
      owner: b.manifest.owner,
      entries: candidate,
      verify: (e) => _validControlFor(b.manifest, e),
    );
    if (folded.rejected.any(
      (e) => e.author == signed.author && e.seq == signed.seq,
    )) {
      return false;
    }
    await _save(
      GroupBundle(
        manifest: b.manifest,
        control: candidate,
        messages: b.messages,
        reactions: b.reactions,
        sovereignBundle: b.sovereignBundle,
      ),
    );
    // Tell the members who remain (broadcastDelta folds AFTER the leave, so it
    // fans out to them and never to us). They drop us from their roster.
    await broadcastDelta(groupId, control: [signed]);
    return true;
  }

  /// Post a message to [groupId]. Rejected (returns false) if we are not a
  /// non-muted member. An optional inline [attachment] rides inside the signed
  /// message (groups media brick 1) — no separate content fetch.
  Future<bool> postMessage(
    NodeId groupId,
    String body, {
    GroupAttachment? attachment,
    String? replyTo,
    // Test/repro-only escape hatch: append WITHOUT the delta fanout —
    // simulates a delta lost in transit (total-outage class), so the
    // gap-fill path has a deterministic stand target.
    bool broadcast = true,
  }) async {
    final b = await load(groupId);
    if (b == null) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final me = state.memberOf(_signer.selfId);
    if (me == null || me.muted) return false;
    final mySeq = _nextSeq(
      b.messages
          .where(
            (m) =>
                m.author == _signer.selfId &&
                _validMessageFor(b.manifest.groupId, m),
          )
          .map((m) => m.seq),
    );
    final unsigned = GroupMessage(
      groupId: groupId,
      author: _signer.selfId,
      seq: mySeq,
      prevHash: '',
      body: body,
      policyVersion: state.policyVersion,
      createdAtMs: _now(),
      signature: Uint8List(0),
      attachment: attachment,
      replyTo: replyTo,
    );
    final signed = _signer.signMessage(unsigned);
    await _save(
      GroupBundle(
        manifest: b.manifest,
        control: b.control,
        messages: [...b.messages, signed],
        reactions: b.reactions,
        sovereignBundle: b.sovereignBundle,
      ),
    );
    // Ship only the NEW message (delta), not the whole log — a post to a group
    // that already holds an image must not re-chunk that image over the wire.
    if (broadcast) unawaited(broadcastDelta(groupId, messages: [signed]));
    return true;
  }

  // ── Group log gap-fill (reliability brick G1) ─────────────────────────────
  // A delta that dies while EVERY entry node is down is lost for good — the
  // full snapshot only ships on join. Each device therefore fans a compact
  // per-author high-water VECTOR of both logs to a few members on boot; a
  // member that holds more replies with ONLY the missing entries. Bandwidth
  // is one small JSON each way when in sync; convergence is eventual (a
  // sampled member that is itself behind just yields nothing this round).

  /// How many members a boot sync-vector is sent to per group.
  static const int kGroupSyncFanout = 3;

  /// The compact "what I hold" vector for [groupId], or null when unknown.
  Future<Map<String, dynamic>?> buildGroupSyncRequest(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return null;
    Map<String, int> vector(Iterable<(NodeId, int)> entries) {
      final v = <String, int>{};
      for (final (a, s) in entries) {
        // Seqs start at 0 (_nextSeq), so the floor is -1 — with a 0 floor an
        // author whose ONLY entry is seq 0 was absent from the vector and the
        // responder (old default 0) never shipped seq-0 entries at all: the
        // FIRST lost entry of any author was unrecoverable (latent G1 bug,
        // caught by the reaction remainder).
        if (s > (v[a.hex] ?? -1)) v[a.hex] = s;
      }
      return v;
    }

    return {
      'sreq': 1,
      'gid': groupId.hex,
      'g': vector(
        b.messages
            .where((m) => _validMessageFor(groupId, m))
            .map((m) => (m.author, m.seq)),
      ),
      'c': vector(
        b.control
            .where((e) => _validControlFor(b.manifest, e))
            .map((e) => (e.author, e.seq)),
      ),
      // Reactions ride the same per-author high-water scheme (each author's
      // reaction seq is monotonic). An older responder just ignores the key.
      'r': vector(
        b.reactions
            .where((r) => _validReactionFor(groupId, r))
            .map((r) => (r.author, r.seq)),
      ),
    };
  }

  /// Answer a member's sync vector: ship ONLY the entries [peer] lacks (their
  /// vector's high-water per author, unseen author = everything). Non-members
  /// are dropped silently — no membership oracle. Returns whether a reply
  /// delta was sent.
  Future<bool> handleGroupSyncRequest(NodeId peer, Map req) async {
    final send = _send;
    if (send == null) return false;
    final gidHex = req['gid'];
    if (gidHex is! String || !(await _index()).contains(gidHex)) return false;
    final NodeId gid;
    try {
      gid = NodeId.fromHex(gidHex);
    } catch (_) {
      return false;
    }
    final b = await load(gid);
    if (b == null) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    if (!state.isMember(peer)) {
      debugPrint('xVeil[groups]: sync request from non-member — drop');
      return false;
    }
    // -1, not 0: seqs start at 0, so "never seen this author" must sit BELOW
    // the first seq or seq-0 entries can never gap-fill (see [vector]).
    int seen(Object? vec, NodeId author) =>
        (vec is Map && vec[author.hex] is int) ? vec[author.hex] as int : -1;
    final missingMsgs = [
      for (final m in b.messages)
        if (_validMessageFor(gid, m) && m.seq > seen(req['g'], m.author)) m,
    ];
    final missingCtl = [
      for (final e in b.control)
        if (_validControlFor(b.manifest, e) && e.seq > seen(req['c'], e.author))
          e,
    ];
    // A requester from before the 'r' vector sends none — `seen` reads 0 and
    // every held reaction ships; the ingest dedup by (author, seq) makes the
    // over-send harmless.
    final missingRx = [
      for (final r in b.reactions)
        if (_validReactionFor(gid, r) && r.seq > seen(req['r'], r.author)) r,
    ];
    if (missingMsgs.isEmpty && missingCtl.isEmpty && missingRx.isEmpty) {
      return false;
    }
    await send(
      peer,
      gid,
      jsonEncode({
        'm': b.manifest.toJson(),
        'c': [for (final e in missingCtl) e.toJson()],
        'g': [for (final m in missingMsgs) m.toJson()],
        'r': [for (final r in missingRx) r.toJson()],
      }),
    );
    return true;
  }

  /// Route one inbound group-entry payload from [peer]: a sync VECTOR is
  /// answered (membership-gated), anything else is the normal idempotent
  /// snapshot/delta ingest. The wire wiring points here instead of calling
  /// [ingestSnapshot] directly.
  Future<bool> ingestGroupEntry(NodeId peer, String json) async {
    try {
      final d = jsonDecode(json);
      if (d is Map && d['sreq'] == 1) return handleGroupSyncRequest(peer, d);
    } catch (_) {
      return false; // malformed — drop
    }
    final pending = await _tryPendingDeviceSnapshot(peer, json);
    if (pending != null) return pending;
    return ingestSnapshot(json);
  }

  /// The NON-contact variant of [ingestGroupEntry]: a member's sync vector is
  /// answered (the handler's own membership gate is the same admission), a
  /// bundle goes through the stranger-guarded ingest.
  Future<bool> ingestGroupEntryFromStranger(NodeId peer, String json) async {
    try {
      final d = jsonDecode(json);
      if (d is Map && d['sreq'] == 1) return handleGroupSyncRequest(peer, d);
    } catch (_) {
      return false; // malformed — drop
    }
    return ingestSnapshotFromStranger(peer, json);
  }

  /// Boot catch-up for EVERY group: fan my sync vector to up to
  /// [kGroupSyncFanout] members per group. Cheap when in sync (one small
  /// JSON), and the reply path ships only what this device actually lacks.
  Future<void> nudgeGroupSyncAll() async {
    final send = _send;
    if (send == null) return;
    for (final gidHex in await _index()) {
      final NodeId gid;
      try {
        gid = NodeId.fromHex(gidHex);
      } catch (_) {
        continue;
      }
      await compactStateLogs(gid);
      final bundle = await load(gid);
      final req = await buildGroupSyncRequest(gid);
      final st = await stateOf(gid);
      if (bundle == null || req == null || st == null) continue;
      final others = [
        for (final m in st.members.values)
          if (m.nodeId != _signer.selfId &&
              (!bundle.manifest.isSovereignDevice ||
                  m.nodeId != bundle.manifest.owner))
            m.nodeId,
      ]..shuffle(Random());
      for (final peer in others.take(kGroupSyncFanout)) {
        await send(peer, gid, jsonEncode(req));
      }
    }
  }

  /// The VALIDATED, time-ordered messages of [groupId]: signature ok AND the
  /// author is a non-muted member of the current state. (A finer per-message
  /// membership-at-its-policy-version check is a later refinement.)
  Future<List<GroupMessage>> messagesOf(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return const [];
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final out = <GroupMessage>[];
    for (final m in b.messages) {
      if (!_validMessageFor(groupId, m)) continue;
      final mem = state.memberOf(m.author);
      if (mem == null || mem.muted) continue;
      out.add(m);
    }
    out.sort((a, b) {
      final t = a.createdAtMs.compareTo(b.createdAtMs);
      if (t != 0) return t;
      final h = a.author.hex.compareTo(b.author.hex);
      if (h != 0) return h;
      return a.seq.compareTo(b.seq);
    });
    return out;
  }

  /// Toggle our reaction [emoji] on the message [msgRef] ("<authorHex>:<seq>"):
  /// reacting with the emoji we already have removes it. Rejected (false) if we
  /// are not a non-muted member. The signed reaction is delta-broadcast.
  /// [broadcast]=false stores the signed reaction WITHOUT the delta fanout —
  /// the deterministic "lost reaction" for gap-fill tests (like
  /// [postMessage]'s flag).
  Future<bool> react(
    NodeId groupId,
    String msgRef,
    String emoji, {
    bool broadcast = true,
  }) async {
    final b = await load(groupId);
    if (b == null) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final me = state.memberOf(_signer.selfId);
    if (me == null || me.muted) return false;
    // My current reaction on this message (if any) → tapping it again clears it.
    final onMsg =
        foldGroupReactions(
          b.reactions.where((r) => _validReactionFor(groupId, r)),
          _signer.verifyReaction,
        )[msgRef] ??
        const <String, List<NodeId>>{};
    String? mine;
    for (final e in onMsg.entries) {
      if (e.value.any((n) => n == _signer.selfId)) {
        mine = e.key;
        break;
      }
    }
    final next = (mine == emoji) ? '' : emoji;
    final mySeq = _nextSeq(
      b.reactions
          .where(
            (r) =>
                r.author == _signer.selfId &&
                _validReactionFor(b.manifest.groupId, r),
          )
          .map((r) => r.seq),
    );
    final signed = _signer.signReaction(
      GroupReaction(
        groupId: groupId,
        author: _signer.selfId,
        seq: mySeq,
        target: msgRef,
        emoji: next,
        createdAtMs: _now(),
        signature: Uint8List(0),
      ),
    );
    await _save(
      GroupBundle(
        manifest: b.manifest,
        control: b.control,
        messages: b.messages,
        reactions: [...b.reactions, signed],
        sovereignBundle: b.sovereignBundle,
      ),
    );
    if (broadcast) unawaited(broadcastDelta(groupId, reactions: [signed]));
    return true;
  }

  /// The folded reactions of [groupId]: `messageRef -> emoji -> reactors`.
  Future<Map<String, MessageReactions>> reactionsOf(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return const {};
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    return foldGroupReactions(
      b.reactions.where(
        (r) => _validReactionFor(groupId, r) && state.isMember(r.author),
      ),
      _signer.verifyReaction,
    );
  }

  // ── Content path (doc/GROUPS-CONTENT-PATH.md) ─────────────────────────────

  /// Replay cache for inbound fetch requests (holder side), bounded FIFO.
  final Set<String> _seenContentNonces = <String>{};
  static const int _kMaxSeenNonces = 512;

  /// The contentIds referenced by [groupId]'s VALIDATED messages — the only
  /// content a membership grant may unlock (membership must not become a
  /// license to fetch arbitrary content this device holds).
  Future<Set<String>> referencedContentIds(NodeId groupId) async {
    final msgs = await messagesOf(groupId);
    return {
      for (final m in msgs)
        if (m.attachment?.cid != null) m.attachment!.cid!,
    };
  }

  /// Mint, sign and ship a fetch request for [cid] of [groupId] to [holder]
  /// (normally the message author). False when the wire sender isn't attached.
  Future<bool> requestGroupContent(
    NodeId groupId,
    String cid,
    NodeId holder,
  ) async {
    final send = sendContentRequest;
    if (send == null) return false;
    final rnd = Random.secure();
    final nonce = List<int>.generate(
      12,
      (_) => rnd.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final signed = _signer.signContentRequest(
      GroupContentRequest(
        groupId: groupId,
        contentId: cid,
        requester: _signer.selfId,
        nonce: nonce,
        tsMs: _now(),
        signature: Uint8List(0),
      ),
    );
    await send(holder, jsonEncode(signed.toJson()));
    return true;
  }

  /// Holder side: authorize an inbound signed request against OUR folded view
  /// and grant the serve when it passes. Unauthorized requests return false
  /// with only a local log line — the requester gets NOTHING back (no
  /// membership oracle, per canon).
  Future<bool> handleContentRequest(String requestJson) async {
    GroupContentRequest? r;
    try {
      r = GroupContentRequest.fromJson(jsonDecode(requestJson));
    } catch (_) {
      /* malformed → drop */
    }
    if (r == null) return false;
    final req = r;
    final st = await stateOf(req.groupId);
    if (st == null) {
      debugPrint('xVeil[groups]: content request for unknown group — drop');
      return false;
    }
    final denial = authorizeGroupContentRequest(
      req,
      state: st,
      referenced: await referencedContentIds(req.groupId),
      nowMs: _now(),
      seenNonces: _seenContentNonces,
      verify: _signer.verifyContentRequest,
    );
    if (denial != null) {
      debugPrint(
        'xVeil[groups]: content request DENIED (${denial.name}) — drop',
      );
      return false;
    }
    if (_seenContentNonces.length >= _kMaxSeenNonces) {
      _seenContentNonces.remove(_seenContentNonces.first);
    }
    _seenContentNonces.add(req.nonce);
    grantContentServe?.call(req.requester, req.contentId);
    return true;
  }

  /// Whether NON-contact [peer] may sync group [gidHex]: we already hold that
  /// group AND the peer is a current member per OUR fold. The admission the
  /// wire layer asks before spending reassembly RAM on a stranger's chunks.
  Future<bool> allowStrangerGroupSync(NodeId peer, String gidHex) async {
    if (!(await _index()).contains(gidHex)) return false;
    final NodeId gid;
    try {
      gid = NodeId.fromHex(gidHex);
    } catch (_) {
      return false;
    }
    final st = await stateOf(gid);
    return st != null && st.isMember(peer);
  }

  /// Ingest a snapshot from a NON-contact sender: merge ONLY into a group we
  /// already hold where [peer] is a current member — the scale-free log sync
  /// (members need no pairwise contact handshake). Never materializes a NEW
  /// group: a stranger's group-invite is spam until a consent surface exists,
  /// so that path stays contact-gated. Unauthorized bundles are dropped with
  /// nothing sent back (no membership oracle).
  Future<bool> ingestSnapshotFromStranger(
    NodeId peer,
    String bundleJson,
  ) async {
    String? gidHex;
    try {
      final d = jsonDecode(bundleJson);
      final m = d is Map ? d['m'] : null;
      final gid = m is Map ? m['gid'] : null;
      if (gid is String && gid.isNotEmpty) gidHex = gid;
    } catch (_) {
      /* malformed → drop below */
    }
    if (gidHex == null) return false;
    final pending = await _tryPendingDeviceSnapshot(peer, bundleJson);
    if (pending != null) return pending;
    if (!await allowStrangerGroupSync(peer, gidHex)) {
      debugPrint('xVeil[groups]: stranger snapshot DENIED — drop');
      return false;
    }
    return ingestSnapshot(bundleJson);
  }

  /// Returns null when [bundleJson] is unrelated to the pending ceremony,
  /// otherwise consumes it (true) or rejects it (false). Shared by contact and
  /// non-contact ingress: prior contact status must not change adoption rules.
  Future<bool?> _tryPendingDeviceSnapshot(
    NodeId peer,
    String bundleJson,
  ) async {
    final pending = await pendingDeviceAdoption();
    if (pending == null || peer != pending.source) return null;
    GroupManifest? manifest;
    try {
      final d = jsonDecode(bundleJson);
      manifest = GroupManifest.fromJson(d is Map ? d['m'] : null);
    } catch (_) {
      return false;
    }
    if (manifest == null || manifest.groupId != pending.groupId) return null;
    if (!listEquals(_manifestHash(manifest), pending.manifestHash))
      return false;
    if (!await ingestSnapshot(bundleJson)) return false;
    if (!await adoptDeviceGroup(pending.groupId)) return false;
    await cancelPendingDeviceAdoption();
    return true;
  }

  /// Fetch [cid] of [groupId] from [holder] (normally the message author):
  /// ship the signed membership request, give the grant a moment to land at
  /// the holder, then start the standard stream pull. For holders that are
  /// also accepted 1:1 contacts the pull would pass anyway; the request makes
  /// the same flow work for pure co-members. Fire-and-forget: progress /
  /// completion surface through the content providers like any 1:1 download.
  Future<bool> fetchGroupContent(
    NodeId groupId,
    String cid,
    NodeId holder,
  ) async {
    final pull = startContentPull;
    if (pull == null) return false;
    await requestGroupContent(groupId, cid, holder);
    // The durable request needs a wire round-trip before the grant exists —
    // pulling instantly would burn the first stream attempt on a DENIED. The
    // pull machinery retries, so this delay is a fast-path nicety, not a
    // correctness requirement.
    await Future<void>.delayed(const Duration(seconds: 4));
    await pull(holder, cid);
    return true;
  }

  /// Ingest an externally-received control entry (from a peer-sync brick, or a
  /// hook). Appends if it isn't already present; the fold decides validity on
  /// read, so a bogus entry simply never applies.
  Future<void> ingestControl(NodeId groupId, ControlEntry e) async {
    final b = await load(groupId);
    if (b == null) return;
    if (!_validControlFor(b.manifest, e)) return;
    if (b.control.any(
      (x) =>
          _validControlFor(b.manifest, x) &&
          x.author == e.author &&
          x.seq == e.seq,
    )) {
      return;
    }
    await _save(
      GroupBundle(
        manifest: b.manifest,
        control: [...b.control, e],
        messages: b.messages,
        reactions: b.reactions,
        sovereignBundle: b.sovereignBundle,
      ),
    );
  }

  /// Serialize a group's full snapshot (manifest + logs) for the wire.
  String snapshotJson(GroupBundle b) => jsonEncode({
    'm': b.manifest.toJson(),
    'c': b.control
        .where((e) => _validControlFor(b.manifest, e))
        .map((e) => e.toJson())
        .toList(),
    'g': b.messages
        .where((m) => _validMessageFor(b.manifest.groupId, m))
        .map((m) => m.toJson())
        .toList(),
    'r': b.reactions
        .where((r) => _validReactionFor(b.manifest.groupId, r))
        .map((r) => r.toJson())
        .toList(),
    if (b.sovereignBundle != null) 's': base64Encode(b.sovereignBundle!),
  });

  /// Ingest a received snapshot: materialize the group if new (manifest +
  /// index), then merge control + message entries (dedup by author+seq).
  /// Idempotent — re-delivery of the same snapshot is a no-op.
  Future<bool> ingestSnapshot(String bundleJson) async {
    Map<String, dynamic> d;
    try {
      d = jsonDecode(bundleJson) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }
    final manifest = GroupManifest.fromJson(d['m']);
    if (manifest == null || !_validManifest(manifest)) return false;
    final Uint8List? incomingSovereignBundle;
    try {
      incomingSovereignBundle = d['s'] is String
          ? Uint8List.fromList(base64Decode(d['s'] as String))
          : null;
    } catch (_) {
      return false;
    }
    final inControl = (d['c'] as List? ?? const [])
        .map(ControlEntry.fromJson)
        .whereType<ControlEntry>()
        .toList();
    final inMsgs = (d['g'] as List? ?? const [])
        .map(GroupMessage.fromJson)
        .whereType<GroupMessage>()
        .toList();
    final inReactions = (d['r'] as List? ?? const [])
        .map(GroupReaction.fromJson)
        .whereType<GroupReaction>()
        .toList();

    final existing = await load(manifest.groupId);
    if ((existing == null &&
            !_validSovereignBundle(manifest, incomingSovereignBundle)) ||
        (existing != null &&
            incomingSovereignBundle != null &&
            !_validSovereignBundle(manifest, incomingSovereignBundle))) {
      return false;
    }
    if (existing != null &&
        existing.manifest.isSovereignDevice &&
        !existing.manifest.sameGenesis(manifest)) {
      return false;
    }
    // Keep the manifest we already had (the authoritative genesis); only adopt
    // the incoming one when the group is new to us.
    final man = existing?.manifest ?? manifest;
    final control = [...(existing?.control ?? const <ControlEntry>[])];
    final messages = [...(existing?.messages ?? const <GroupMessage>[])];
    final reactions = [...(existing?.reactions ?? const <GroupReaction>[])];
    for (final e in inControl) {
      if (!_validControlFor(man, e)) continue;
      if (!control.any(
        (x) =>
            _validControlFor(man, x) && x.author == e.author && x.seq == e.seq,
      )) {
        control.add(e);
      }
    }
    final mergedState = foldControlLog(
      owner: man.owner,
      entries: control,
      verify: (e) => _validControlFor(man, e),
      initialName: man.name,
    ).state;
    final fresh = <GroupMessage>[];
    for (final m in inMsgs) {
      if (!_validMessageFor(manifest.groupId, m) ||
          !mergedState.isMember(m.author)) {
        continue;
      }
      if (!messages.any(
        (x) =>
            _validMessageFor(manifest.groupId, x) &&
            x.author == m.author &&
            x.seq == m.seq,
      )) {
        messages.add(m);
        // Feed the notification/unread layer: genuinely new, not ours, and
        // signature-verified (a forged entry must not buzz the phone even
        // though the fold would drop it on read anyway).
        if (m.author != _signer.selfId) {
          fresh.add(m);
        }
      }
    }
    for (final r in inReactions) {
      if (!_validReactionFor(manifest.groupId, r) ||
          !mergedState.isMember(r.author)) {
        continue;
      }
      if (!reactions.any(
        (x) =>
            _validReactionFor(manifest.groupId, x) &&
            x.author == r.author &&
            x.seq == r.seq,
      )) {
        reactions.add(r);
      }
    }
    await _save(
      GroupBundle(
        manifest: man,
        control: control,
        messages: messages,
        reactions: reactions,
        sovereignBundle: existing?.sovereignBundle ?? incomingSovereignBundle,
      ),
    );
    if (existing == null) {
      final idx = await _index();
      if (!idx.contains(man.groupId.hex)) {
        idx.add(man.groupId.hex);
        await _setIndex(idx);
      }
    }
    // Device-group traffic is sync machinery, not chat: it must never buzz
    // the notification layer or count as chat-unread. It routes to a SEPARATE
    // stream the multi-device bridge consumes (device-sync events).
    if (man.name == kDeviceGroupName) {
      // A marker snapshot is inert until the local handshake explicitly
      // adopts this exact gid. Otherwise any contact could plant a valid-
      // looking infrastructure group and drive sync apply side effects.
      if (await deviceGroupIdHex() == man.groupId.hex) {
        for (final m in fresh) {
          _deviceIncomingCtl.add(m);
        }
      }
    } else {
      for (final m in fresh) {
        _incomingCtl.add((groupId: man.groupId, message: m));
      }
    }
    return true;
  }

  /// Fresh (post-dedup, verified, not-self) messages of MY device group — the
  /// multi-device bridge folds these into DeviceSyncEvents and applies them.
  final StreamController<GroupMessage> _deviceIncomingCtl =
      StreamController.broadcast();
  Stream<GroupMessage> get deviceIncoming => _deviceIncomingCtl.stream;

  /// Genuinely-NEW inbound messages (post-dedup, signature-verified, not
  /// self-authored) — the notification/unread layer's feed, symmetric to
  /// MessagingService.incoming.
  final StreamController<({NodeId groupId, GroupMessage message})>
  _incomingCtl = StreamController.broadcast();
  Stream<({NodeId groupId, GroupMessage message})> get incoming =>
      _incomingCtl.stream;

  /// Attached by the multi-device bridge: a LOCAL group-seen advance (never
  /// fired from [applyMirroredGroupSeen]) — my other devices clear the badge.
  void Function(String gidHex, int tsMs)? onGroupSeen;

  /// Mark [groupId] read "as of now" — the unread watermark the open group
  /// screen advances. A local display preference, not group state.
  Future<void> markGroupSeen(NodeId groupId) async {
    final ts = _now();
    await _storage.putSetting('group.seen:${groupId.hex}', '$ts');
    onGroupSeen?.call(groupId.hex, ts);
  }

  /// Apply a group-seen watermark mirrored from ANOTHER of my devices —
  /// monotonic, straight to storage (no [onGroupSeen] echo). Returns whether
  /// the watermark advanced.
  Future<bool> applyMirroredGroupSeen(String gidHex, int tsMs) async {
    final cur =
        int.tryParse(await _storage.getSetting('group.seen:$gidHex') ?? '') ??
        0;
    if (cur >= tsMs) return false;
    await _storage.putSetting('group.seen:$gidHex', '$tsMs');
    changes.value++; // group list re-renders its badge
    return true;
  }

  /// How many VALIDATED messages of [groupId] are newer than the seen
  /// watermark and not self-authored.
  Future<int> unreadOf(NodeId groupId) async {
    final wm =
        int.tryParse(
          await _storage.getSetting('group.seen:${groupId.hex}') ?? '',
        ) ??
        0;
    final msgs = await messagesOf(groupId);
    return msgs.where((m) => m.createdAtMs > wm && m.author != selfId).length;
  }

  /// Local notification mute for [groupId] — a display preference like the
  /// unread watermark (never sent anywhere; distinct from the CONTROL-LOG
  /// member mute, which is about posting rights).
  Future<void> setGroupMuted(NodeId groupId, bool muted) async {
    await _storage.putSetting('group.muted:${groupId.hex}', muted ? '1' : '');
    changes.value++; // the group list re-renders its mute affordance
  }

  Future<bool> isGroupMuted(NodeId groupId) async =>
      (await _storage.getSetting('group.muted:${groupId.hex}')) == '1';

  // ── Device group (multi-device epic, doc/MULTIDEVICE-DESIGN.md) ──────────

  /// The reserved manifest name marking a DEVICE group (my devices' private
  /// sync group). Groups with this name are hidden from every user-facing
  /// list; the leading space cannot be produced through the create/rename
  /// dialogs (both trim their input).
  static const String kDeviceGroupName = ' xveil.devices';
  static const String kSovereignBundleSetting = 'devices.sovereign.bundle.v1';
  static const String kPendingDeviceAdoptionSetting =
      'devices.pending_adoption.v1';

  String? _deviceGidCache;

  /// My device group's id (hex), or null before the first link/adopt.
  Future<String?> deviceGroupIdHex() async {
    _deviceGidCache ??= await _storage.getSetting('devices.gid');
    return (_deviceGidCache?.isEmpty ?? true) ? null : _deviceGidCache;
  }

  Future<Uint8List?> localSovereignBundle() async {
    final raw = await _storage.getSetting(kSovereignBundleSetting);
    if (raw == null || raw.isEmpty) return null;
    try {
      final value = Uint8List.fromList(base64Decode(raw));
      return value.length <= 16 * 1024 ? value : null;
    } catch (_) {
      return null;
    }
  }

  /// Decrypt the persisted bundle in native RAM for one signing burst. The
  /// first phrase-backed operation creates and stores only an encrypted blob.
  Future<NativeSovereignGroupSigner> openLocalSovereign(
    String phrase, {
    bool createIfMissing = true,
  }) async {
    final stored = await _storage.getSetting(kSovereignBundleSetting);
    Uint8List? bundle;
    if (stored != null && stored.isNotEmpty) {
      try {
        bundle = Uint8List.fromList(base64Decode(stored));
        if (bundle.isEmpty || bundle.length > 16 * 1024) {
          throw const FormatException('sovereign bundle size');
        }
      } catch (_) {
        throw StateError('Local sovereign bundle is corrupt');
      }
    } else if (createIfMissing) {
      bundle = veil.createHybrid512SovereignBundle(phrase);
      await _storage.putSetting(kSovereignBundleSetting, base64Encode(bundle));
    }
    if (bundle == null) throw StateError('No local sovereign bundle');
    final magic = bundle.length >= 4
        ? ascii.decode(bundle.sublist(0, 4), allowInvalid: true)
        : '';
    return magic == 'XVRC'
        ? NativeSovereignGroupSigner.openRecoveryCertificate(bundle, phrase)
        : NativeSovereignGroupSigner.openBundle(bundle, phrase);
  }

  /// How the persisted sovereign material is unlocked. Missing/corrupt stays
  /// null; callers must not guess that a legacy identity has a phrase.
  Future<String?> sovereignCredentialKind() async {
    final bundle = await localSovereignBundle();
    if (bundle == null || bundle.length < 4) return null;
    final magic = ascii.decode(bundle.sublist(0, 4), allowInvalid: true);
    return switch (magic) {
      'XVSB' => 'phrase',
      'XVRC' => 'certificate',
      _ => null,
    };
  }

  /// Export a fresh XVRC + independent 256-bit code from the current XVSB or
  /// XVRC credential. Decrypted key bytes never enter Dart.
  Future<({Uint8List certificate, String code, NodeId nodeId})?>
  exportRecoveryCertificate(String currentSecret) async {
    var credential = await localSovereignBundle();
    if (credential == null) {
      // A phrase-backed identity may pre-issue its certificate BEFORE its first
      // device link. Provision the normal XVSB once, exactly as link would.
      final provisioned = await openLocalSovereign(currentSecret);
      provisioned.close();
      credential = await localSovereignBundle();
    }
    if (credential == null) return null;
    final code = veil.generateSovereignRecoveryCode();
    final certificate = veil.exportSovereignRecoveryCertificate(
      credential,
      currentSecret,
      code,
    );
    final signer = NativeSovereignGroupSigner.openRecoveryCertificate(
      certificate,
      code,
    );
    try {
      return (certificate: certificate, code: code, nodeId: signer.nodeId);
    } finally {
      signer.close();
    }
  }

  /// All-devices-lost recovery: install one XVRC only into a fresh local
  /// device-registry state, then mint a fresh gid owned by the SAME full hybrid
  /// public key/node id. Never overwrites a different credential or group.
  Future<NodeId?> recoverDeviceGroupFromCertificate(
    Uint8List certificate,
    String recoveryCode,
  ) async {
    if (await deviceGroupIdHex() != null) return null;
    final existing = await localSovereignBundle();
    if (existing != null && !listEquals(existing, certificate)) return null;
    final signer = NativeSovereignGroupSigner.openRecoveryCertificate(
      certificate,
      recoveryCode,
    );
    var installed = false;
    try {
      if (signer.algorithm != 'ed25519+falcon512') return null;
      if (existing == null) {
        await _storage.putSetting(
          kSovereignBundleSetting,
          base64Encode(certificate),
        );
        installed = true;
      }
      final gid = await _mintSovereignDeviceGroup(signer, const []);
      if (gid == null && installed) {
        await _storage.putSetting(kSovereignBundleSetting, '');
      }
      return gid;
    } catch (_) {
      if (installed) {
        await _storage.putSetting(kSovereignBundleSetting, '');
      }
      rethrow;
    } finally {
      signer.close();
    }
  }

  Uint8List _manifestHash(GroupManifest manifest) => veil.VeilCrypto.sha256(
    Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson()))),
  );

  Future<DeviceLinkToken?> pendingDeviceAdoption() async {
    final raw = await _storage.getSetting(kPendingDeviceAdoptionSetting);
    if (raw == null || raw.isEmpty) return null;
    try {
      final token = DeviceLinkToken.fromJson(jsonDecode(raw));
      if (token == null || token.isExpired(_now())) return null;
      return token;
    } catch (_) {
      return null;
    }
  }

  /// Explicit target-side consent. Until this token is stored, a stranger can
  /// never materialize a new marker group. The token pins source, gid and the
  /// exact signed manifest; the subsequent snapshot still passes all normal
  /// signature, bundle-hash and self-membership checks.
  Future<bool> prepareDeviceAdoption(DeviceLinkToken token) async {
    if (token.source == _signer.selfId || token.isExpired(_now())) return false;
    await _storage.putSetting(
      kPendingDeviceAdoptionSetting,
      jsonEncode(token.toJson()),
    );
    return true;
  }

  Future<void> cancelPendingDeviceAdoption() =>
      _storage.putSetting(kPendingDeviceAdoptionSetting, '');

  /// Build the short QR token after the source has sovereign-signed the target
  /// into the local registry but before it broadcasts the encrypted snapshot.
  Future<DeviceLinkToken?> createDeviceLinkToken(
    BootstrapInvite sourceInvite,
  ) async {
    if (sourceInvite.nodeId != _signer.selfId) return null;
    final gidHex = await deviceGroupIdHex();
    if (gidHex == null) return null;
    final bundle = await load(NodeId.fromHex(gidHex));
    if (bundle == null || !bundle.manifest.isSovereignDevice) return null;
    return DeviceLinkToken(
      groupId: bundle.manifest.groupId,
      source: _signer.selfId,
      manifestHash: _manifestHash(bundle.manifest),
      sourceInvite: sourceInvite,
      expiresAtMs: _now() + const Duration(minutes: 30).inMilliseconds,
    );
  }

  Future<int> broadcastDeviceGroup() async {
    final gidHex = await deviceGroupIdHex();
    if (gidHex == null) return 0;
    return broadcast(NodeId.fromHex(gidHex));
  }

  bool _sovereignMatches(
    GroupManifest manifest,
    SovereignGroupSigner sovereign,
  ) =>
      manifest.isSovereignDevice &&
      manifest.signatureAlgorithm == sovereign.algorithm &&
      manifest.owner == sovereign.nodeId &&
      listEquals(manifest.genesisPubKey, sovereign.publicKey);

  bool _canUpgradeSovereign(
    GroupManifest manifest,
    SovereignGroupSigner sovereign,
  ) =>
      manifest.isSovereignDevice &&
      manifest.signatureAlgorithm == 'ed25519' &&
      sovereign.algorithm == 'ed25519+falcon512' &&
      sovereign.publicKey.length == 929 &&
      listEquals(manifest.genesisPubKey, sovereign.publicKey.sublist(0, 32));

  Future<NodeId?> _mintSovereignDeviceGroup(
    SovereignGroupSigner sovereign,
    Iterable<NodeId> devices, {
    GroupBundle? migrateFrom,
    bool broadcastSnapshot = true,
  }) async {
    final encryptedSovereign = await localSovereignBundle();
    if (sovereign.algorithm != 'ed25519' && encryptedSovereign == null) {
      return null;
    }
    final gid = _randomGroupId();
    final unsignedManifest = GroupManifest(
      groupId: gid,
      owner: sovereign.nodeId,
      genesisPubKey: Uint8List.fromList(sovereign.publicKey),
      name: kDeviceGroupName,
      createdAtMs: _now(),
      version: GroupManifest.sovereignDeviceVersion,
      kind: GroupManifest.sovereignDeviceKind,
      signatureAlgorithm: sovereign.algorithm,
      sovereignBundleHash: encryptedSovereign == null
          ? null
          : veil.VeilCrypto.sha256(encryptedSovereign),
    );
    final manifest = unsignedManifest.withSignature(
      sovereign.sign(unsignedManifest.canonicalBytes()),
    );
    if (!_validManifest(manifest)) return null;

    final unique = <String, NodeId>{
      _signer.selfId.hex: _signer.selfId,
      for (final d in devices) d.hex: d,
    }..remove(sovereign.nodeId.hex);
    final ordered = unique.values.toList()
      ..sort((a, b) => a.hex.compareTo(b.hex));
    final control = <ControlEntry>[];
    final baseTs = _now();
    for (var seq = 0; seq < ordered.length; seq++) {
      final unsigned = ControlEntry(
        groupId: gid,
        author: sovereign.nodeId,
        seq: seq,
        prevHash: '',
        op: ControlOp.addMember,
        target: ordered[seq],
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: baseTs + seq,
        signature: Uint8List(0),
      );
      control.add(
        unsigned.withSignature(
          sovereign.sign(unsigned.canonicalBytes()),
          Uint8List.fromList(sovereign.publicKey),
        ),
      );
    }
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: control,
      verify: (e) => _validControlFor(manifest, e),
      initialName: manifest.name,
    );
    if (folded.rejected.isNotEmpty || !folded.state.isMember(_signer.selfId)) {
      return null;
    }

    final migratedMessages = <GroupMessage>[];
    if (migrateFrom != null) {
      final oldState = foldControlLog(
        owner: migrateFrom.manifest.owner,
        entries: migrateFrom.control,
        verify: (e) => _validControlFor(migrateFrom.manifest, e),
        initialName: migrateFrom.manifest.name,
      ).state;
      final compact =
          _compactDeviceMessages(migrateFrom.manifest.groupId, [
            for (final m in migrateFrom.messages)
              if (oldState.isMember(m.author)) m,
          ])..sort((a, b) {
            final ts = a.createdAtMs.compareTo(b.createdAtMs);
            return ts != 0 ? ts : _messageIdentityCompare(a, b);
          });
      for (var seq = 0; seq < compact.length; seq++) {
        final old = compact[seq];
        final unsigned = GroupMessage(
          groupId: gid,
          author: _signer.selfId,
          seq: seq,
          prevHash: '',
          body: old.body,
          policyVersion: 0,
          createdAtMs: old.createdAtMs,
          signature: Uint8List(0),
          attachment: old.attachment,
        );
        migratedMessages.add(_signer.signMessage(unsigned));
      }
    }

    await _save(
      GroupBundle(
        manifest: manifest,
        control: control,
        messages: migratedMessages,
        sovereignBundle: encryptedSovereign,
      ),
    );
    final idx = await _index();
    if (!idx.contains(gid.hex)) {
      idx.add(gid.hex);
      await _setIndex(idx);
    }
    await _storage.putSetting('devices.gid', gid.hex);
    _deviceGidCache = gid.hex;
    _deviceMembersCache = null;
    if (broadcastSnapshot) await broadcast(gid);
    return gid;
  }

  Future<NodeId?> ensureDeviceGroup(SovereignGroupSigner sovereign) async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return _mintSovereignDeviceGroup(sovereign, const []);
    final old = await load(NodeId.fromHex(hex));
    if (old == null) return null;
    if (old.manifest.isSovereignDevice) {
      if (_sovereignMatches(old.manifest, sovereign)) {
        return old.manifest.groupId;
      }
      if (!_canUpgradeSovereign(old.manifest, sovereign)) return null;
      final state = foldControlLog(
        owner: old.manifest.owner,
        entries: old.control,
        verify: (e) => _validControlFor(old.manifest, e),
        initialName: old.manifest.name,
      ).state;
      return _mintSovereignDeviceGroup(
        sovereign,
        state.members.values.map((m) => m.nodeId),
        migrateFrom: old,
      );
    }
    final state = foldControlLog(
      owner: old.manifest.owner,
      entries: old.control,
      verify: (e) => _validControlFor(old.manifest, e),
      initialName: old.manifest.name,
    ).state;
    return _mintSovereignDeviceGroup(
      sovereign,
      state.members.values.map((m) => m.nodeId),
      migrateFrom: old,
    );
  }

  /// ADOPT [groupId] as my device group — called by the NEW device during the
  /// link handshake (the QR channel carries the id out-of-band). Deliberately
  /// explicit: a device group is NEVER auto-adopted from an inbound snapshot,
  /// or any contact could plant a marker-named group and start receiving this
  /// device's sync events.
  Future<bool> adoptDeviceGroup(NodeId groupId) async {
    final bundle = await load(groupId);
    if (bundle == null ||
        !bundle.manifest.isSovereignDevice ||
        !_validManifest(bundle.manifest)) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (e) => _validControlFor(bundle.manifest, e),
      initialName: bundle.manifest.name,
    ).state;
    if (!state.isMember(_signer.selfId)) return false;
    await _storage.putSetting('devices.gid', groupId.hex);
    if (bundle.sovereignBundle != null) {
      await _storage.putSetting(
        kSovereignBundleSetting,
        base64Encode(bundle.sovereignBundle!),
      );
    }
    _deviceGidCache = groupId.hex;
    _deviceMembersCache = null;
    changes.value++;
    // Ingest deliberately kept the snapshot inert before adoption. Replay its
    // validated state now that gid + sovereign genesis + membership are bound.
    for (final message in await messagesOf(groupId)) {
      if (message.author != _signer.selfId) {
        _deviceIncomingCtl.add(message);
      }
    }
    return true;
  }

  Future<bool> _appendSovereignMembership(
    GroupBundle bundle,
    SovereignGroupSigner sovereign,
    ControlOp op,
    NodeId device, {
    bool broadcastSnapshot = true,
  }) async {
    if (!_sovereignMatches(bundle.manifest, sovereign)) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (e) => _validControlFor(bundle.manifest, e),
      initialName: bundle.manifest.name,
    ).state;
    if (op == ControlOp.addMember && state.isMember(device)) return true;
    if (op == ControlOp.removeMember && !state.isMember(device)) return true;
    if (device == bundle.manifest.owner) return false;
    final seq = _nextSeq(
      bundle.control
          .where(
            (e) =>
                e.author == sovereign.nodeId &&
                _validControlFor(bundle.manifest, e),
          )
          .map((e) => e.seq),
    );
    final unsigned = ControlEntry(
      groupId: bundle.manifest.groupId,
      author: sovereign.nodeId,
      seq: seq,
      prevHash: '',
      op: op,
      target: device,
      role: op == ControlOp.addMember ? GroupRole.member : null,
      policyVersion: state.policyVersion,
      createdAtMs: _now(),
      signature: Uint8List(0),
    );
    final signed = unsigned.withSignature(
      sovereign.sign(unsigned.canonicalBytes()),
      Uint8List.fromList(sovereign.publicKey),
    );
    final candidate = [...bundle.control, signed];
    final folded = foldControlLog(
      owner: bundle.manifest.owner,
      entries: candidate,
      verify: (e) => _validControlFor(bundle.manifest, e),
      initialName: bundle.manifest.name,
    );
    if (folded.rejected.any(
      (e) => e.author == signed.author && e.seq == signed.seq,
    )) {
      return false;
    }
    await _save(
      GroupBundle(
        manifest: bundle.manifest,
        control: candidate,
        messages: bundle.messages,
        reactions: bundle.reactions,
        sovereignBundle: bundle.sovereignBundle,
      ),
    );
    _deviceMembersCache = null;
    if (op == ControlOp.addMember && broadcastSnapshot) {
      await broadcast(bundle.manifest.groupId);
    } else if (op == ControlOp.removeMember) {
      await broadcastDelta(bundle.manifest.groupId, control: [signed]);
    }
    return true;
  }

  Future<bool> linkDevice(
    NodeId device, {
    required SovereignGroupSigner sovereign,
    bool broadcastSnapshot = true,
  }) async {
    final hex = await deviceGroupIdHex();
    if (hex == null) {
      return await _mintSovereignDeviceGroup(sovereign, [
            device,
          ], broadcastSnapshot: broadcastSnapshot) !=
          null;
    }
    final bundle = await load(NodeId.fromHex(hex));
    if (bundle == null) return false;
    if (!bundle.manifest.isSovereignDevice) {
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (e) => _validControlFor(bundle.manifest, e),
        initialName: bundle.manifest.name,
      ).state;
      return await _mintSovereignDeviceGroup(
            sovereign,
            [...state.members.values.map((m) => m.nodeId), device],
            migrateFrom: bundle,
            broadcastSnapshot: broadcastSnapshot,
          ) !=
          null;
    }
    if (!_sovereignMatches(bundle.manifest, sovereign) &&
        _canUpgradeSovereign(bundle.manifest, sovereign)) {
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (e) => _validControlFor(bundle.manifest, e),
        initialName: bundle.manifest.name,
      ).state;
      return await _mintSovereignDeviceGroup(
            sovereign,
            [...state.members.values.map((m) => m.nodeId), device],
            migrateFrom: bundle,
            broadcastSnapshot: broadcastSnapshot,
          ) !=
          null;
    }
    return _appendSovereignMembership(
      bundle,
      sovereign,
      ControlOp.addMember,
      device,
      broadcastSnapshot: broadcastSnapshot,
    );
  }

  /// Revoke [device]: removeMember — the fold rotates the epoch, so the
  /// removed device loses the future (already-synced history honestly stays).
  Future<bool> revokeDevice(
    NodeId device, {
    required SovereignGroupSigner sovereign,
  }) async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return false;
    final old = await load(NodeId.fromHex(hex));
    if (old == null) return false;
    if (!old.manifest.isSovereignDevice) {
      final state = foldControlLog(
        owner: old.manifest.owner,
        entries: old.control,
        verify: (e) => _validControlFor(old.manifest, e),
        initialName: old.manifest.name,
      ).state;
      return await _mintSovereignDeviceGroup(
            sovereign,
            state.members.values
                .map((m) => m.nodeId)
                .where((id) => id != device),
            migrateFrom: old,
          ) !=
          null;
    }
    if (!_sovereignMatches(old.manifest, sovereign) &&
        _canUpgradeSovereign(old.manifest, sovereign)) {
      final state = foldControlLog(
        owner: old.manifest.owner,
        entries: old.control,
        verify: (e) => _validControlFor(old.manifest, e),
        initialName: old.manifest.name,
      ).state;
      return await _mintSovereignDeviceGroup(
            sovereign,
            state.members.values
                .map((m) => m.nodeId)
                .where((id) => id != device),
            migrateFrom: old,
          ) !=
          null;
    }
    _deviceMembersCache = null;
    return _appendSovereignMembership(
      old,
      sovereign,
      ControlOp.removeMember,
      device,
    );
  }

  /// Catch-up for the device group (brick 4e): ship my FULL device-group
  /// snapshot to every other device. Deltas posted while every entry node was
  /// down can be lost for good (the join-time full broadcast is the only
  /// recovery today — found live in the 2026-07-11 seed outage), so each
  /// device nudges once per boot; [ingestSnapshot] merges by (author, seq),
  /// so a redundant nudge costs bandwidth, never correctness. Returns how
  /// many devices it was shipped to (0 = no device group / solo install).
  Future<int> nudgeDeviceSync() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return 0;
    return broadcast(NodeId.fromHex(hex));
  }

  /// Whether [peer] is a CURRENT member of my device group — i.e. another of
  /// my own devices. The mirror taps consult this per stored message, so the
  /// folded member set is cached briefly; link/adopt/revoke invalidate it.
  Future<bool> isMyDevice(NodeId peer) async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return false;
    final now = _now();
    var cached = _deviceMembersCache;
    if (cached == null || now - _deviceMembersCacheAtMs > 30000) {
      final bundle = await load(NodeId.fromHex(hex));
      final st = bundle == null
          ? null
          : foldControlLog(
              owner: bundle.manifest.owner,
              entries: bundle.control,
              verify: (e) => _validControlFor(bundle.manifest, e),
              initialName: bundle.manifest.name,
            ).state;
      cached = {
        for (final m in st?.members.values ?? const <GroupMember>[])
          if (m.nodeId != bundle?.manifest.owner) m.nodeId.hex,
      };
      _deviceMembersCache = cached;
      _deviceMembersCacheAtMs = now;
    }
    return cached.contains(peer.hex);
  }

  Set<String>? _deviceMembersCache;
  int _deviceMembersCacheAtMs = 0;

  /// Serializes [postDeviceEvent] appends: sync emits are fire-and-forget
  /// (message taps, settings toggles, journal rows), so two can race the
  /// group log's read-modify-write and the later save silently drops the
  /// earlier append. Caught live in the brick-4 device verify (pin landed,
  /// the same-call archive edit vanished from BOTH devices' folds).
  Future<void> _devicePostChain = Future.value();

  /// Append a sync event to my device group's log (no-op false when no
  /// device group exists yet). Concurrent calls are applied in order.
  ///
  /// [attachment] (brick 4b, lazy attachments): a mirrored FILE message posts
  /// its contentId as a real attachment ref, which puts the cid into
  /// [referencedContentIds] — that is what authorizes my other devices'
  /// membership pull of the bytes. The event body stays the JSON codec.
  Future<bool> postDeviceEvent(
    DeviceSyncEvent e, {
    GroupAttachment? attachment,
  }) {
    final done = _devicePostChain.then((_) async {
      final hex = await deviceGroupIdHex();
      if (hex == null) return false;
      return postMessage(
        NodeId.fromHex(hex),
        e.toBody(),
        attachment: attachment,
      );
    });
    _devicePostChain = done.then((_) {}, onError: (_) {});
    return done;
  }

  /// The folded device-sync state: newest event per (kind, key), from the
  /// VALIDATED device-group log. Empty before adoption.
  Future<Map<(DeviceSyncKind, String), DeviceSyncEvent>>
  deviceSyncState() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return const {};
    final msgs = await messagesOf(NodeId.fromHex(hex));
    return foldDeviceSync([
      for (final m in msgs) ?DeviceSyncEvent.fromBody(m.body),
    ]);
  }

  /// Every validated device-sync row with its signed message author retained.
  /// Most LWW kinds need only [deviceSyncState]; cloud replica claims must also
  /// prove `claimed device == author`, so discarding the author would turn the
  /// group into a replica-count spoofing oracle.
  Future<List<DeviceSyncRecord>> deviceSyncRecords() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return const [];
    final messages = await messagesOf(NodeId.fromHex(hex));
    return [
      for (final message in messages)
        if (DeviceSyncEvent.fromBody(message.body) case final event?)
          (event: event, author: message.author),
    ];
  }

  /// Current non-sovereign members of the device group (including self).
  Future<List<NodeId>> deviceMembers() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return const [];
    final bundle = await load(NodeId.fromHex(hex));
    if (bundle == null) return const [];
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
    ).state;
    return [
      for (final member in state.members.values)
        if (member.nodeId != bundle.manifest.owner) member.nodeId,
    ];
  }

  /// One-line preview of a validated message for list tiles / notifications.
  static String previewOf(GroupMessage m) {
    if (m.body.isNotEmpty) return m.body;
    switch (m.attachment?.kind) {
      case 'image':
        return '🖼';
      case 'sticker':
        return '😊';
      case 'voice':
        return '🎤';
      case 'vnote':
        return '📹';
    }
    return '…';
  }

  /// Fan the current FULL snapshot of [groupId] out to every OTHER member
  /// (direct delivery, v1). Used to sync a member joining (they need the whole
  /// history). No-op without an injected sender. Returns how many peers it was
  /// shipped to.
  Future<int> broadcast(NodeId groupId) async {
    final send = _send;
    final b = await load(groupId);
    if (send == null || b == null) return 0;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final json = snapshotJson(b);
    var n = 0;
    for (final m in state.members.values) {
      if (m.nodeId == _signer.selfId ||
          (b.manifest.isSovereignDevice && m.nodeId == b.manifest.owner)) {
        continue;
      }
      await send(m.nodeId, groupId, json);
      n++;
    }
    return n;
  }

  /// Fan a DELTA (only the just-added [control]/[messages] entries) out to every
  /// OTHER member — the hot path for posts and ops, so an established group does
  /// NOT re-ship its whole history (incl. inline images) on every change. A new
  /// member still gets a full [broadcast] on join. Convergence holds: each delta
  /// is a durable frame (retried until acked) and [ingestSnapshot] merges by
  /// (author, seq); the manifest rides along so a delta that races ahead of the
  /// join snapshot still materializes the group (its entries validate once the
  /// control-log catches up). Returns how many peers it was shipped to.
  Future<int> broadcastDelta(
    NodeId groupId, {
    List<ControlEntry> control = const [],
    List<GroupMessage> messages = const [],
    List<GroupReaction> reactions = const [],
  }) async {
    final send = _send;
    final b = await load(groupId);
    if (send == null || b == null) return 0;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final json = jsonEncode({
      'm': b.manifest.toJson(),
      'c': control.map((e) => e.toJson()).toList(),
      'g': messages.map((m) => m.toJson()).toList(),
      'r': reactions.map((x) => x.toJson()).toList(),
    });
    var n = 0;
    for (final m in state.members.values) {
      if (m.nodeId == _signer.selfId ||
          (b.manifest.isSovereignDevice && m.nodeId == b.manifest.owner)) {
        continue;
      }
      await send(m.nodeId, groupId, json);
      n++;
    }
    return n;
  }
}

/// One row of the user-facing group list (the shape [GroupService.listGroups]
/// returns) — named so the chats screen and providers can share it.
typedef GroupListEntry = ({
  NodeId groupId,
  String name,
  int unread,
  bool muted,
  String preview,
  int lastTs,
});

/// The group list as a stream: re-emits on every service change signal, so
/// the chats screen (which now inlines groups) rebuilds like any provider.
final groupListProvider = StreamProvider<List<GroupListEntry>>((ref) async* {
  final svc = ref.watch(groupServiceProvider);
  if (svc == null) {
    yield const [];
    return;
  }
  yield await svc.listGroups();
  final ticks = StreamController<void>();
  void onTick() {
    if (!ticks.isClosed) ticks.add(null);
  }

  svc.changes.addListener(onTick);
  ref.onDispose(() {
    svc.changes.removeListener(onTick);
    ticks.close();
  });
  await for (final _ in ticks.stream) {
    yield await svc.listGroups();
  }
});

/// Builds the real signer from the app's identity, or null before ready.
final groupSignerProvider = FutureProvider<GroupSigner?>((ref) async {
  // WATCH the identity: the eager app-scope bridge builds this at boot when the
  // identity is still null; without a watch the null result would cache forever
  // and no group would ever sign. Re-runs once the identity is ready.
  final selfId = ref.watch(
    appControllerProvider.select((s) => s.identity?.nodeId),
  );
  if (selfId == null) return null;
  final toml = await ref.read(storageProvider).loadNodeConfig();
  if (toml == null) return null;
  // Learn our public key by signing an empty probe (stateless native crypto);
  // the native verifier later re-binds it to selfId (node_id == BLAKE3(pk)).
  try {
    final res = EmbeddedNode.signMessage(toml, Uint8List(0));
    return NativeGroupSigner(
      identityToml: toml,
      selfId: selfId,
      selfPubKey: res.publicKey,
    );
  } catch (_) {
    return null;
  }
});

/// The service, or null until the signer is ready. Wires group snapshot
/// delivery to the messaging layer, and routes inbound snapshots back into
/// the service (idempotent ingest) — the direct-fanout transport (v1).
final groupServiceProvider = Provider<GroupService?>((ref) {
  final signer = ref.watch(groupSignerProvider).valueOrNull;
  if (signer == null) return null;
  final messaging = ref.read(messagingServiceProvider);
  final svc = GroupService(
    ref.read(storageProvider),
    signer,
    send: (peer, groupId, json) =>
        messaging.sendGroupSnapshot(peer, groupId.hex, json),
    sendContentRequest: (holder, json) =>
        messaging.sendGroupContentRequest(holder, json),
    grantContentServe: messaging.grantGroupContentServe,
    startContentPull: (holder, cid) async {
      await messaging.downloadContent(holder, cid);
    },
  );
  messaging.onGroupEntry = (peer, bundleJson) async {
    await svc.ingestGroupEntry(peer, bundleJson);
  };
  // Membership-authorized fetch requests (content path): judged entirely by
  // the service (signature + fold + referenced + replay).
  messaging.onGroupContentRequest = (peer, requestJson) {
    unawaited(svc.handleContentRequest(requestJson));
  };
  // Scale-free log sync: a NON-contact member's snapshot merges into groups
  // we hold (guarded); chunk reassembly asks the same admission up front.
  messaging.onGroupEntryFromStranger = (peer, bundleJson) {
    unawaited(svc.ingestGroupEntryFromStranger(peer, bundleJson));
  };
  messaging.allowStrangerGroupSync = svc.allowStrangerGroupSync;
  // Reliability brick G1: fan each group's sync VECTOR to a few members once
  // per boot — recovers deltas that died while every entry node was down.
  unawaited(svc.nudgeGroupSyncAll());

  // ── Multi-device mirror loop (doc/MULTIDEVICE-DESIGN.md, bricks 3+4b) ─────
  // EMIT: a stored 1:1 message becomes a msgMirror event on my device group.
  // Skip Saved Messages (peer == self, local-only). A FILE message (either
  // direction) mirrors LAZILY: the event carries name/size/cid and a real
  // attachment ref (micro-thumb + contentId) — never the bytes; the ref is
  // what authorizes the other device's membership pull when the user taps
  // download there. postDeviceEvent is a no-op until a device group exists,
  // so this is inert on a single-device install.
  messaging.onMessageStored = (peer, m) {
    if (peer == svc.selfId) return;
    unawaited(() async {
      // The device-PAIR conversation never mirrors: each side names it by the
      // OTHER device's id, so a mirrored row would land in the wrong (even
      // self-) conversation on the sibling. Intra-owner chat is local-only.
      if (await svc.isMyDevice(peer)) return;
      final cid = m.fileContentId ?? m.fileId;
      if (cid == null) {
        if (m.body.isEmpty) return;
        await svc.postDeviceEvent(
          DeviceSyncEvent(
            kind: DeviceSyncKind.msgMirror,
            key: m.id,
            tsMs: m.timestamp.millisecondsSinceEpoch,
            payload: {
              'peer': peer.hex,
              'dir': m.direction.name,
              'body': m.body,
            },
          ),
        );
        return;
      }
      await svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.msgMirror,
          key: m.id,
          tsMs: m.timestamp.millisecondsSinceEpoch,
          payload: {
            'peer': peer.hex,
            'dir': m.direction.name,
            'body': m.body,
            'cid': cid,
            'fname': m.fileName,
            'fsize': m.fileSize,
          },
        ),
        // The ref that puts cid into referencedContentIds. dataB64 must be
        // non-empty by the codec's contract — the micro-thumb when we have
        // one, a one-byte placeholder otherwise (w/h are meaningless here).
        attachment: GroupAttachment(
          kind: 'file',
          dataB64: (m.thumb?.isNotEmpty ?? false) ? m.thumb! : 'AA==',
          w: 1,
          h: 1,
          cid: cid,
        ),
      );
    }());
  };
  // APPLY: a device-group message from another device → fold → write the
  // mirrored 1:1 row (idempotent + deniability-safe in applyMirroredMessage).
  // A file mirror lands as an OFFER-shaped row (fileContentId, no bytes) —
  // the bytes arrive only when the user downloads, via the membership pull.
  svc.deviceIncoming.listen((gm) {
    final e = DeviceSyncEvent.fromBody(gm.body);
    if (e == null || e.kind != DeviceSyncKind.msgMirror) return;
    final peerHex = e.payload['peer'];
    final body = e.payload['body'];
    final dir = e.payload['dir'] == 'outgoing'
        ? MessageDirection.outgoing
        : MessageDirection.incoming;
    if (peerHex is! String || body is! String) return;
    // A mirror naming THIS device as the conversation peer would write a
    // conversation-with-myself row (the device-pair chat seen from the other
    // side) — drop it; the emit side skips device members too.
    if (peerHex == svc.selfId.hex) return;
    final cid = e.payload['cid'], fname = e.payload['fname'];
    final fsize = e.payload['fsize'];
    final thumb = gm.attachment?.dataB64;
    unawaited(
      messaging.applyMirroredMessage(
        peer: NodeId.fromHex(peerHex),
        msgId: e.key,
        direction: dir,
        body: body,
        tsMs: e.tsMs,
        fileContentId: cid is String && cid.isNotEmpty ? cid : null,
        fileName: fname is String ? fname : null,
        fileSize: fsize is int ? fsize : null,
        thumb: thumb != null && thumb != 'AA==' ? thumb : null,
      ),
    );
  });
  return svc;
});
