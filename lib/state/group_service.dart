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
import '../domain/group_message.dart';
import '../domain/group_policy.dart';
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
  bool verifyControl(ControlEntry e);
  bool verifyMessage(GroupMessage m);
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
  bool verifyControl(ControlEntry e) => verifyControlEntry(e, lib: lib);
  @override
  bool verifyMessage(GroupMessage m) => verifyGroupMessage(m, lib: lib);
}

/// One group's stored data.
class GroupBundle {
  GroupBundle({required this.manifest, required this.control, required this.messages});
  final GroupManifest manifest;
  final List<ControlEntry> control;
  final List<GroupMessage> messages;
}

/// Ships a group snapshot [bundleJson] durably to [peer] (direct fanout, v1).
typedef GroupSnapshotSender = Future<void> Function(
    NodeId peer, NodeId groupId, String bundleJson);

class GroupService {
  GroupService(this._storage, this._signer, {GroupSnapshotSender? send})
      : _send = send;
  final Storage _storage;
  final GroupSigner _signer;
  final GroupSnapshotSender? _send;

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

  Future<GroupBundle?> load(NodeId groupId) async {
    final raw = await _storage.getSetting(_key(groupId));
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
      return GroupBundle(
          manifest: manifest, control: control, messages: messages);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(GroupBundle b) async {
    await _storage.putSetting(
          _key(b.manifest.groupId),
          jsonEncode({
            'm': b.manifest.toJson(),
            'c': b.control.map((e) => e.toJson()).toList(),
            'g': b.messages.map((m) => m.toJson()).toList(),
          }),
        );
  }

  /// All groups we hold, newest-created last.
  Future<List<GroupManifest>> listGroups() async {
    final out = <GroupManifest>[];
    for (final hex in await _index()) {
      try {
        final b = await load(NodeId.fromHex(hex));
        if (b != null) out.add(b.manifest);
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
        manifest: b.manifest, control: candidate, messages: b.messages));
    return true;
  }

  /// Post a message to [groupId]. Rejected (returns false) if we are not a
  /// non-muted member.
  Future<bool> postMessage(NodeId groupId, String body) async {
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
    );
    final signed = _signer.signMessage(unsigned);
    await _save(GroupBundle(
        manifest: b.manifest,
        control: b.control,
        messages: [...b.messages, signed]));
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
        messages: b.messages));
  }

  /// Serialize a group's full snapshot (manifest + logs) for the wire.
  String snapshotJson(GroupBundle b) => jsonEncode({
        'm': b.manifest.toJson(),
        'c': b.control.map((e) => e.toJson()).toList(),
        'g': b.messages.map((m) => m.toJson()).toList(),
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

    final existing = await load(manifest.groupId);
    final control = [...(existing?.control ?? const <ControlEntry>[])];
    final messages = [...(existing?.messages ?? const <GroupMessage>[])];
    bool has(List l, Object e) {
      if (e is ControlEntry) {
        return control.any((x) => x.author == e.author && x.seq == e.seq);
      }
      if (e is GroupMessage) {
        return messages.any((x) => x.author == e.author && x.seq == e.seq);
      }
      return false;
    }

    for (final e in inControl) {
      if (!has(control, e)) control.add(e);
    }
    for (final m in inMsgs) {
      if (!has(messages, m)) messages.add(m);
    }
    // Keep the manifest we already had (the authoritative genesis); only adopt
    // the incoming one when the group is new to us.
    final man = existing?.manifest ?? manifest;
    await _save(
        GroupBundle(manifest: man, control: control, messages: messages));
    if (existing == null) {
      final idx = await _index();
      if (!idx.contains(man.groupId.hex)) {
        idx.add(man.groupId.hex);
        await _setIndex(idx);
      }
    }
    return true;
  }

  /// Fan the current snapshot of [groupId] out to every OTHER member (direct
  /// delivery, v1). No-op without an injected sender. Returns how many peers
  /// it was shipped to.
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
  );
  messaging.onGroupEntry = (peer, bundleJson) async {
    await svc.ingestSnapshot(bundleJson);
  };
  return svc;
});
