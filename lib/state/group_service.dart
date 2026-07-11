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
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../domain/group.dart';
import '../domain/group_content.dart';
import '../domain/group_message.dart';
import '../domain/group_policy.dart';
import '../domain/group_reaction.dart';
import '../data/node/embedded_node.dart';
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
}

/// Real signer: native ed25519 over the deniable identity TOML.
class NativeGroupSigner implements GroupSigner {
  NativeGroupSigner({
    required this.identityToml,
    required NodeId selfId,
    required Uint8List selfPubKey,
    this.lib,
  })  : _selfId = selfId,
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
  ControlEntry signControl(ControlEntry unsigned) =>
      signControlEntry(identityToml: identityToml, unsigned: unsigned, lib: lib);
  @override
  GroupMessage signMessage(GroupMessage unsigned) =>
      signGroupMessage(identityToml: identityToml, unsigned: unsigned, lib: lib);
  @override
  GroupReaction signReaction(GroupReaction unsigned) =>
      signGroupReaction(identityToml: identityToml, unsigned: unsigned, lib: lib);
  @override
  GroupContentRequest signContentRequest(GroupContentRequest unsigned) =>
      signGroupContentRequest(
          identityToml: identityToml, unsigned: unsigned, lib: lib);
  @override
  bool verifyControl(ControlEntry e) => verifyControlEntry(e, lib: lib);
  @override
  bool verifyMessage(GroupMessage m) => verifyGroupMessage(m, lib: lib);
  @override
  bool verifyReaction(GroupReaction r) => verifyGroupReaction(r, lib: lib);
  @override
  bool verifyContentRequest(GroupContentRequest r) =>
      verifyGroupContentRequest(r, lib: lib);
}

/// One group's stored data.
class GroupBundle {
  GroupBundle({
    required this.manifest,
    required this.control,
    required this.messages,
    this.reactions = const [],
  });
  final GroupManifest manifest;
  final List<ControlEntry> control;
  final List<GroupMessage> messages;
  final List<GroupReaction> reactions;
}

/// Ships a group snapshot [bundleJson] durably to [peer] (direct fanout, v1).
typedef GroupSnapshotSender = Future<void> Function(
    NodeId peer, NodeId groupId, String bundleJson);

class GroupService {
  GroupService(
    this._storage,
    this._signer, {
    GroupSnapshotSender? send,
    this.sendContentRequest,
    this.grantContentServe,
  }) : _send = send;
  final Storage _storage;
  final GroupSigner _signer;
  final GroupSnapshotSender? _send;

  /// Ships a signed content-fetch request to the holder (wire layer).
  final Future<void> Function(NodeId holder, String requestJson)?
      sendContentRequest;

  /// Opens the serve gate for an authorized member (wire layer grant).
  final void Function(NodeId peer, String cid)? grantContentServe;

  /// Bumped on every persisted mutation (local op/post OR an ingested
  /// snapshot) so open group screens re-fetch. Cheap: the UI reads on change.
  final ValueNotifier<int> changes = ValueNotifier(0);

  /// Our own node id — the composer uses it to align outgoing bubbles.
  NodeId get selfId => _signer.selfId;

  int _now() => DateTime.now().millisecondsSinceEpoch;

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
      if (manifest == null) return null;
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
      return GroupBundle(
          manifest: manifest,
          control: control,
          messages: messages,
          reactions: reactions);
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
  Future<List<({NodeId groupId, String name})>> listGroups() async {
    final out = <({NodeId groupId, String name})>[];
    for (final hex in await _index()) {
      try {
        final b = await load(NodeId.fromHex(hex));
        if (b == null) continue;
        final state = foldControlLog(
          owner: b.manifest.owner,
          entries: b.control,
          verify: _signer.verifyControl,
          initialName: b.manifest.name,
        ).state;
        if (state.isMember(_signer.selfId)) {
          out.add((groupId: b.manifest.groupId, name: state.name));
        }
      } catch (_) {}
    }
    return out;
  }

  /// Create a group named [name] with us as the sole owner. Returns its id.
  Future<NodeId> createGroup(String name) async {
    final rnd = Random.secure();
    final gid = NodeId(
        Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256))));
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

  /// The current folded state of [groupId], or null if unknown.
  Future<GroupState?> stateOf(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return null;
    return foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: _signer.verifyControl,
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
    final mySeq = _nextSeq(
        b.control.where((e) => e.author == _signer.selfId).map((e) => e.seq));
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: _signer.verifyControl,
    ).state;
    final pv = state.policyVersion;
    final unsigned = ControlEntry(
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
      verify: _signer.verifyControl,
    );
    if (folded.rejected.any((e) => identical(e, signed) ||
        (e.author == signed.author && e.seq == signed.seq))) {
      return false;
    }
    await _save(GroupBundle(
        manifest: b.manifest,
        control: candidate,
        messages: b.messages,
        reactions: b.reactions));
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
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: _signer.verifyControl,
    ).state;
    final me = state.memberOf(_signer.selfId);
    if (me == null) return true; // already gone
    if (me.role == GroupRole.owner) return false; // owner can't leave (v1)
    final mySeq = _nextSeq(
        b.control.where((e) => e.author == _signer.selfId).map((e) => e.seq));
    final unsigned = ControlEntry(
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
      verify: _signer.verifyControl,
    );
    if (folded.rejected
        .any((e) => e.author == signed.author && e.seq == signed.seq)) {
      return false;
    }
    await _save(GroupBundle(
        manifest: b.manifest,
        control: candidate,
        messages: b.messages,
        reactions: b.reactions));
    // Tell the members who remain (broadcastDelta folds AFTER the leave, so it
    // fans out to them and never to us). They drop us from their roster.
    await broadcastDelta(groupId, control: [signed]);
    return true;
  }

  /// Post a message to [groupId]. Rejected (returns false) if we are not a
  /// non-muted member. An optional inline [attachment] rides inside the signed
  /// message (groups media brick 1) — no separate content fetch.
  Future<bool> postMessage(NodeId groupId, String body,
      {GroupAttachment? attachment, String? replyTo}) async {
    final b = await load(groupId);
    if (b == null) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: _signer.verifyControl,
    ).state;
    final me = state.memberOf(_signer.selfId);
    if (me == null || me.muted) return false;
    final mySeq = _nextSeq(
        b.messages.where((m) => m.author == _signer.selfId).map((m) => m.seq));
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
    await _save(GroupBundle(
        manifest: b.manifest,
        control: b.control,
        messages: [...b.messages, signed],
        reactions: b.reactions));
    // Ship only the NEW message (delta), not the whole log — a post to a group
    // that already holds an image must not re-chunk that image over the wire.
    unawaited(broadcastDelta(groupId, messages: [signed]));
    return true;
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
      verify: _signer.verifyControl,
    ).state;
    final out = <GroupMessage>[];
    for (final m in b.messages) {
      if (!_signer.verifyMessage(m)) continue;
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
  Future<bool> react(NodeId groupId, String msgRef, String emoji) async {
    final b = await load(groupId);
    if (b == null) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: _signer.verifyControl,
    ).state;
    final me = state.memberOf(_signer.selfId);
    if (me == null || me.muted) return false;
    // My current reaction on this message (if any) → tapping it again clears it.
    final onMsg =
        foldGroupReactions(b.reactions, _signer.verifyReaction)[msgRef] ??
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
        b.reactions.where((r) => r.author == _signer.selfId).map((r) => r.seq));
    final signed = _signer.signReaction(GroupReaction(
      groupId: groupId,
      author: _signer.selfId,
      seq: mySeq,
      target: msgRef,
      emoji: next,
      createdAtMs: _now(),
      signature: Uint8List(0),
    ));
    await _save(GroupBundle(
        manifest: b.manifest,
        control: b.control,
        messages: b.messages,
        reactions: [...b.reactions, signed]));
    unawaited(broadcastDelta(groupId, reactions: [signed]));
    return true;
  }

  /// The folded reactions of [groupId]: `messageRef -> emoji -> reactors`.
  Future<Map<String, MessageReactions>> reactionsOf(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return const {};
    return foldGroupReactions(b.reactions, _signer.verifyReaction);
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
      NodeId groupId, String cid, NodeId holder) async {
    final send = sendContentRequest;
    if (send == null) return false;
    final rnd = Random.secure();
    final nonce = List<int>.generate(12, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final signed = _signer.signContentRequest(GroupContentRequest(
      groupId: groupId,
      contentId: cid,
      requester: _signer.selfId,
      nonce: nonce,
      tsMs: _now(),
      signature: Uint8List(0),
    ));
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
    } catch (_) {/* malformed → drop */}
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
          'xVeil[groups]: content request DENIED (${denial.name}) — drop');
      return false;
    }
    if (_seenContentNonces.length >= _kMaxSeenNonces) {
      _seenContentNonces.remove(_seenContentNonces.first);
    }
    _seenContentNonces.add(req.nonce);
    grantContentServe?.call(req.requester, req.contentId);
    return true;
  }

  /// Ingest an externally-received control entry (from a peer-sync brick, or a
  /// hook). Appends if it isn't already present; the fold decides validity on
  /// read, so a bogus entry simply never applies.
  Future<void> ingestControl(NodeId groupId, ControlEntry e) async {
    final b = await load(groupId);
    if (b == null) return;
    if (b.control.any((x) => x.author == e.author && x.seq == e.seq)) return;
    await _save(GroupBundle(
        manifest: b.manifest,
        control: [...b.control, e],
        messages: b.messages,
        reactions: b.reactions));
  }

  /// Serialize a group's full snapshot (manifest + logs) for the wire.
  String snapshotJson(GroupBundle b) => jsonEncode({
        'm': b.manifest.toJson(),
        'c': b.control.map((e) => e.toJson()).toList(),
        'g': b.messages.map((m) => m.toJson()).toList(),
        'r': b.reactions.map((x) => x.toJson()).toList(),
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
    if (manifest == null) return false;
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
    final control = [...(existing?.control ?? const <ControlEntry>[])];
    final messages = [...(existing?.messages ?? const <GroupMessage>[])];
    final reactions = [...(existing?.reactions ?? const <GroupReaction>[])];
    for (final e in inControl) {
      if (!control.any((x) => x.author == e.author && x.seq == e.seq)) {
        control.add(e);
      }
    }
    for (final m in inMsgs) {
      if (!messages.any((x) => x.author == m.author && x.seq == m.seq)) {
        messages.add(m);
      }
    }
    for (final r in inReactions) {
      if (!reactions.any((x) => x.author == r.author && x.seq == r.seq)) {
        reactions.add(r);
      }
    }
    // Keep the manifest we already had (the authoritative genesis); only adopt
    // the incoming one when the group is new to us.
    final man = existing?.manifest ?? manifest;
    await _save(GroupBundle(
        manifest: man,
        control: control,
        messages: messages,
        reactions: reactions));
    if (existing == null) {
      final idx = await _index();
      if (!idx.contains(man.groupId.hex)) {
        idx.add(man.groupId.hex);
        await _setIndex(idx);
      }
    }
    return true;
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
      verify: _signer.verifyControl,
    ).state;
    final json = snapshotJson(b);
    var n = 0;
    for (final m in state.members.values) {
      if (m.nodeId == _signer.selfId) continue;
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
      verify: _signer.verifyControl,
    ).state;
    final json = jsonEncode({
      'm': b.manifest.toJson(),
      'c': control.map((e) => e.toJson()).toList(),
      'g': messages.map((m) => m.toJson()).toList(),
      'r': reactions.map((x) => x.toJson()).toList(),
    });
    var n = 0;
    for (final m in state.members.values) {
      if (m.nodeId == _signer.selfId) continue;
      await send(m.nodeId, groupId, json);
      n++;
    }
    return n;
  }
}

/// Builds the real signer from the app's identity, or null before ready.
final groupSignerProvider = FutureProvider<GroupSigner?>((ref) async {
  // WATCH the identity: the eager app-scope bridge builds this at boot when the
  // identity is still null; without a watch the null result would cache forever
  // and no group would ever sign. Re-runs once the identity is ready.
  final selfId =
      ref.watch(appControllerProvider.select((s) => s.identity?.nodeId));
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
  );
  messaging.onGroupEntry = (peer, bundleJson) async {
    await svc.ingestSnapshot(bundleJson);
  };
  // Membership-authorized fetch requests (content path): judged entirely by
  // the service (signature + fold + referenced + freshness + replay).
  messaging.onGroupContentRequest = (peer, requestJson) {
    unawaited(svc.handleContentRequest(requestJson));
  };
  return svc;
});
