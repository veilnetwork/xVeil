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
import 'package:crypto/crypto.dart' as crypto;
import 'package:veil_flutter/veil_ffi.dart' as veil;

import '../core/ids.dart';
import '../core/log.dart';
import '../domain/call_signal.dart';
import '../domain/device_sync.dart';
import '../domain/device_link.dart';
import '../domain/group.dart';
import '../domain/group_call.dart';
import '../domain/group_content.dart';
import '../domain/group_epoch.dart';
import '../domain/group_message.dart';
import '../domain/group_payload.dart';
import '../domain/group_policy.dart';
import '../domain/group_reaction.dart';
import '../data/transport/bootstrap_invite.dart';
import '../data/storage/storage.dart';
import 'group_crypto.dart';
import 'group_epoch_service.dart';

bool _listEquals<T>(List<T>? left, List<T>? right) {
  if (identical(left, right)) return true;
  if (left == null || right == null || left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

int _compareXorDistance(NodeId origin, NodeId left, NodeId right) {
  for (var i = 0; i < origin.bytes.length; i++) {
    final l = origin.bytes[i] ^ left.bytes[i];
    final r = origin.bytes[i] ^ right.bytes[i];
    if (l != r) return l.compareTo(r);
  }
  return left.hex.compareTo(right.hex);
}

/// Deterministically selects the [k] node ids closest to [self] by XOR
/// distance. Duplicate ids and [self] are ignored; callers do not need to
/// preserve any particular membership iteration order.
List<NodeId> nearestGroupNodesByXor(
  NodeId self,
  Iterable<NodeId> members, {
  int k = GroupService.kGroupSyncNeighbors,
}) {
  if (k <= 0) return const [];
  final unique = <String, NodeId>{
    for (final member in members)
      if (member != self) member.hex: member,
  }.values.toList();
  unique.sort((left, right) => _compareXorDistance(self, left, right));
  return unique.length <= k ? unique : unique.sublist(0, k);
}

/// Flutter-free change signal used by both the GUI provider and headless host.
/// It intentionally mirrors the tiny `ValueNotifier<int>` surface the group
/// list needs without pulling the Flutter engine into the group core.
final class GroupChangeSignal {
  int _value = 0;
  bool _disposed = false;
  final List<void Function()> _listeners = <void Function()>[];
  final StreamController<int> _controller = StreamController<int>.broadcast(
    sync: true,
  );

  int get value => _value;
  Stream<int> get stream => _controller.stream;

  set value(int next) {
    if (_disposed || next == _value) return;
    _value = next;
    _controller.add(next);
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void addListener(void Function() listener) {
    if (_disposed) return;
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
    unawaited(_controller.close());
  }
}

/// The identity operations the service needs — injectable for tests.
abstract class GroupSigner {
  /// Our own node id + public key (the genesis material when we create).
  NodeId get selfId;
  Uint8List get selfPubKey;

  ControlEntry signControl(ControlEntry unsigned);
  GroupMessage signMessage(GroupMessage unsigned);
  GroupReaction signReaction(GroupReaction unsigned);
  GroupContentRequest signContentRequest(GroupContentRequest unsigned);
  GroupCallSignal signCallSignal(GroupCallSignal unsigned);
  bool verifyControl(ControlEntry e);
  bool verifyMessage(GroupMessage m);
  bool verifyReaction(GroupReaction r);
  bool verifyContentRequest(GroupContentRequest r);
  bool verifyCallSignal(GroupCallSignal signal);
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
  GroupCallSignal signCallSignal(GroupCallSignal unsigned) =>
      signGroupCallSignal(
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
  bool verifyCallSignal(GroupCallSignal signal) =>
      verifyGroupCallSignal(signal, lib: lib);
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
    this.epochEnvelopes = const [],
    this.localEpochKeys = const {},
    this.sovereignBundle,
  });
  final GroupManifest manifest;
  final List<ControlEntry> control;
  final List<GroupMessage> messages;
  final List<GroupReaction> reactions;

  /// Recipient-specific ML-KEM records. A creator keeps every record it
  /// minted so direct fanout can be tailored per recipient; a receiver stores
  /// only records addressed to itself. These are sealed and safe to persist.
  final List<GroupEpochRecipientEnvelope> epochEnvelopes;

  /// Decrypted epoch keys live only in the deniable hidden-volume bundle.
  /// They are deliberately omitted from every wire snapshot/delta.
  final Map<int, Uint8List> localEpochKeys;
  final Uint8List? sovereignBundle;

  GroupBundle copyWith({
    GroupManifest? manifest,
    List<ControlEntry>? control,
    List<GroupMessage>? messages,
    List<GroupReaction>? reactions,
    List<GroupEpochRecipientEnvelope>? epochEnvelopes,
    Map<int, Uint8List>? localEpochKeys,
    Uint8List? sovereignBundle,
  }) => GroupBundle(
    manifest: manifest ?? this.manifest,
    control: control ?? this.control,
    messages: messages ?? this.messages,
    reactions: reactions ?? this.reactions,
    epochEnvelopes: epochEnvelopes ?? this.epochEnvelopes,
    localEpochKeys: localEpochKeys ?? this.localEpochKeys,
    sovereignBundle: sovereignBundle ?? this.sovereignBundle,
  );
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

typedef GroupCallFrameSender =
    Future<void> Function(
      NodeId peer,
      GroupCallSignal signal,
      String frameJson,
    );

class GroupService {
  GroupService(
    this._storage,
    this._signer, {
    GroupSnapshotSender? send,
    GroupEpochService? epochService,
    this.ourCertVersion = 1,
    this.sendContentRequest,
    this.sendGroupCallFrame,
    this.grantContentServe,
    this.startContentPull,
    this.startContentPullFromAny,
    this.contentRequestFanoutTimeout = const Duration(seconds: 8),
    this.contentGrantDelay = const Duration(seconds: 4),
  }) : _send = send,
       // Named public constructor parameter cannot use a private initializing
       // formal; keep the externally-used `epochService:` API.
       // ignore: prefer_initializing_formals
       _epochService = epochService;
  final Storage _storage;
  final GroupSigner _signer;
  final GroupSnapshotSender? _send;
  final GroupEpochService? _epochService;
  final int ourCertVersion;

  /// Ships a signed content-fetch request to the holder (wire layer).
  final Future<void> Function(NodeId holder, String requestJson)?
  sendContentRequest;

  /// Ships a short-lived encrypted call-control frame to one current member.
  final GroupCallFrameSender? sendGroupCallFrame;

  /// Opens the serve gate for an authorized member (wire layer grant).
  final void Function(NodeId peer, String cid)? grantContentServe;

  /// Starts the standard content pull of [cid] from a holder (wire layer).
  final Future<void> Function(NodeId holder, String cid)? startContentPull;

  /// Starts a membership-scoped pull from every current candidate member.
  /// The messaging layer tries holders until one actually has the verified
  /// blob; no persistent/read-receipt holder advertisement is created.
  final Future<void> Function(List<NodeId> holders, String cid)?
  startContentPullFromAny;

  /// Bounds only the foreground wait for durable request fanout. The durable
  /// sends keep running after this deadline; an offline member must not delay
  /// a reachable seeder indefinitely.
  final Duration contentRequestFanoutTimeout;

  /// Gives durable membership requests time to reach candidate holders before
  /// the first stream open. Injectable so closed-loop tests need no wall clock.
  final Duration contentGrantDelay;

  /// Bumped on every persisted mutation (local op/post OR an ingested
  /// snapshot) so open group screens re-fetch. Cheap: the UI reads on change.
  final GroupChangeSignal changes = GroupChangeSignal();

  /// Our own node id — the composer uses it to align outgoing bubbles.
  NodeId get selfId => _signer.selfId;

  final Map<String, Future<void>> _mutationTails = <String, Future<void>>{};

  // Overlay deltas are flooded transitively across each node's sparse XOR
  // links. This bounded RAM set makes the flood exactly-once per live process;
  // the underlying log merge remains the durable/idempotent safety net.
  static const int _kSeenOverlayDeltaLimit = 4096;
  final Set<String> _seenOverlayDeltas = <String>{};

  final StreamController<GroupCallSignal> _groupCallIncomingCtl =
      StreamController.broadcast();
  Stream<GroupCallSignal> get groupCallIncoming => _groupCallIncomingCtl.stream;

  /// Replay ids are RAM-only: wire frame dedup is the first line, while this
  /// signed-signal set also catches a malicious re-wrapping under a fresh AEAD
  /// nonce/frame id. Signals expire quickly, so restart persistence is neither
  /// useful nor desirable.
  final Map<String, int> _seenGroupCallSignals = <String, int>{};

  /// Serialize every read-modify-write of one group. Wire ingest and local UI
  /// actions share this gate, so a concurrently arriving delta cannot restore
  /// an older bundle and erase a freshly persisted message/epoch key.
  Future<T> _serialized<T>(NodeId groupId, Future<T> Function() action) async {
    final id = groupId.hex;
    final previous = _mutationTails[id] ?? Future<void>.value();
    final gate = Completer<void>();
    _mutationTails[id] = gate.future;
    try {
      try {
        await previous;
      } catch (_) {
        // A prior mutation reports its own failure; the queue must keep moving.
      }
      return await action();
    } finally {
      gate.complete();
      if (identical(_mutationTails[id], gate.future)) {
        _mutationTails.remove(id);
      }
    }
  }

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
    return _listEquals(veil.VeilCrypto.sha256(encryptedBundle), expected);
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
          _listEquals(e.authorPubKey, manifest.genesisPubKey) &&
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

  bool _validGroupCallShape(GroupCallSignal signal) {
    switch (signal.type) {
      case GroupCallSignalType.announce:
      case GroupCallSignalType.join:
        // These establish the room capability for a newly-seeing peer.
        if (signal.media == null || signal.media!.isEmpty) return false;
        break;
      case GroupCallSignalType.renegotiate:
        // Current posture is required but may be all-off.
        if (signal.media == null) return false;
        break;
      case GroupCallSignalType.heartbeat:
        // Legacy heartbeats omit media; new ones repeat current posture so a
        // lost live renegotiation converges at the next tick.
        break;
      case GroupCallSignalType.leave:
      case GroupCallSignalType.end:
      case GroupCallSignalType.busy:
      case GroupCallSignalType.unknown:
        if (signal.media != null) return false;
        break;
    }
    return signal.isStructurallyValid;
  }

  String _freshGroupCallNonce() {
    final random = Random.secure();
    return List<int>.generate(
      12,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  void _pruneSeenGroupCallSignals(int nowMs) {
    _seenGroupCallSignals.removeWhere(
      (_, seenAt) => nowMs - seenAt > const Duration(minutes: 3).inMilliseconds,
    );
    while (_seenGroupCallSignals.length > 2048) {
      _seenGroupCallSignals.remove(_seenGroupCallSignals.keys.first);
    }
  }

  /// Sign, epoch-encrypt and fan one ephemeral call-control event to every
  /// other CURRENT member. No call plaintext or key is persisted.
  Future<GroupCallSignal?> broadcastGroupCallSignal(
    NodeId groupId, {
    required String callId,
    required GroupCallSignalType type,
    CallMedia? media,
    CallEndReason? reason,
  }) => _serialized(groupId, () async {
    final sender = sendGroupCallFrame;
    final bundle = await load(groupId);
    if (sender == null || bundle == null || bundle.manifest.isSovereignDevice) {
      return null;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (!state.isMember(_signer.selfId) ||
        !_encryptionEstablished(bundle.manifest, bundle.control)) {
      return null;
    }
    final descriptor = state.epochDescriptor;
    final key = bundle.localEpochKeys[state.epoch];
    if (descriptor == null ||
        descriptor.epoch != state.epoch ||
        key == null ||
        !_validLocalEpochKey(
          bundle.manifest,
          bundle.control,
          state.epoch,
          key,
        )) {
      return null;
    }
    final unsigned = GroupCallSignal(
      groupId: groupId,
      callId: callId,
      author: _signer.selfId,
      membershipEpoch: state.epoch,
      type: type,
      media: media,
      reason: reason,
      sentAtMs: _now(),
      nonce: _freshGroupCallNonce(),
      signature: Uint8List(0),
      authorPubKey: Uint8List(0),
    );
    if (!_validGroupCallShape(unsigned)) return null;
    final signed = _signer.signCallSignal(unsigned);
    if (!_validGroupCallShape(signed) || !_signer.verifyCallSignal(signed)) {
      return null;
    }
    final clear = Uint8List.fromList(utf8.encode(signed.encode()));
    try {
      final encrypted = await encryptGroupCallPayload(
        groupId: groupId,
        membershipEpoch: state.epoch,
        author: _signer.selfId,
        clearText: clear,
        epochKey: key,
      );
      final frame = GroupCallWireFrame(
        groupId: groupId,
        membershipEpoch: state.epoch,
        payload: encrypted,
      ).encode();
      for (final member in state.members.values) {
        if (member.nodeId == _signer.selfId) continue;
        await sender(member.nodeId, signed, frame);
      }
      return signed;
    } catch (_) {
      return null;
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  });

  /// Authenticate and decrypt an inbound group-call frame. Every refusal is a
  /// silent false: callers must not learn whether a gid, member or epoch exists.
  Future<bool> ingestGroupCallFrame(NodeId peer, String frameJson) async {
    final frame = GroupCallWireFrame.tryDecode(frameJson);
    if (frame == null) return false;
    return _serialized(frame.groupId, () async {
      final bundle = await load(frame.groupId);
      if (bundle == null || bundle.manifest.isSovereignDevice) return false;
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
      ).state;
      if (!state.isMember(peer) ||
          frame.membershipEpoch != state.epoch ||
          state.epochDescriptor?.epoch != state.epoch) {
        return false;
      }
      final key = bundle.localEpochKeys[state.epoch];
      if (key == null ||
          !_validLocalEpochKey(
            bundle.manifest,
            bundle.control,
            state.epoch,
            key,
          )) {
        return false;
      }
      Uint8List? clear;
      try {
        clear = await decryptGroupCallPayload(
          groupId: frame.groupId,
          membershipEpoch: frame.membershipEpoch,
          author: peer,
          payload: frame.payload,
          epochKey: key,
        );
        if (clear.length > maxGroupCallSignalBytes) return false;
        final signal = GroupCallSignal.tryDecode(utf8.decode(clear));
        if (signal == null ||
            signal.groupId != frame.groupId ||
            signal.membershipEpoch != frame.membershipEpoch ||
            signal.author != peer ||
            !_validGroupCallShape(signal) ||
            !_signer.verifyCallSignal(signal)) {
          return false;
        }
        final nowMs = _now();
        final ageMs = nowMs - signal.sentAtMs;
        if (ageMs < -const Duration(seconds: 30).inMilliseconds ||
            ageMs > const Duration(minutes: 2).inMilliseconds) {
          return false;
        }
        _pruneSeenGroupCallSignals(nowMs);
        final replayId =
            '${signal.author.hex}:${signal.callId}:${signal.nonce}';
        if (_seenGroupCallSignals.containsKey(replayId)) return false;
        _seenGroupCallSignals[replayId] = nowMs;
        if (!_groupCallIncomingCtl.isClosed) {
          _groupCallIncomingCtl.add(signal);
        }
        return true;
      } catch (_) {
        return false;
      } finally {
        clear?.fillRange(0, clear.length, 0);
      }
    });
  }

  bool _sameEpochDescriptor(
    GroupEpochDescriptor left,
    GroupEpochDescriptor right,
  ) =>
      left.groupId == right.groupId &&
      left.epoch == right.epoch &&
      left.keyCommitment == right.keyCommitment &&
      left.envelopeRoot == right.envelopeRoot &&
      left.recipientCount == right.recipientCount;

  List<ControlEntry> _acceptedControl(
    GroupManifest manifest,
    List<ControlEntry> control,
  ) {
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: control,
      verify: (entry) => _validControlFor(manifest, entry),
      initialName: manifest.name,
    );
    return [
      for (final entry in control)
        if (!folded.rejected.contains(entry)) entry,
    ];
  }

  ControlEntry? _descriptorEntry(
    GroupManifest manifest,
    List<ControlEntry> control,
    GroupEpochDescriptor descriptor,
  ) {
    for (final entry in _acceptedControl(manifest, control)) {
      final candidate = entry.epochDescriptor;
      if (candidate != null && _sameEpochDescriptor(candidate, descriptor)) {
        return entry;
      }
    }
    return null;
  }

  bool _encryptionEstablished(
    GroupManifest manifest,
    List<ControlEntry> control,
  ) => _acceptedControl(
    manifest,
    control,
  ).any((entry) => entry.epochDescriptor != null);

  bool _validLocalEpochKey(
    GroupManifest manifest,
    List<ControlEntry> control,
    int epoch,
    Uint8List key,
  ) {
    if (key.length != 32) return false;
    for (final entry in _acceptedControl(manifest, control)) {
      final descriptor = entry.epochDescriptor;
      if (descriptor == null || descriptor.epoch != epoch) continue;
      return descriptor.keyCommitment ==
          groupEpochKeyCommitment(
            groupId: manifest.groupId,
            epoch: epoch,
            key: key,
          );
    }
    return false;
  }

  Future<GroupMessage?> _materializeEncryptedMessage(
    GroupBundle bundle,
    GroupMessage message,
  ) async {
    if (!message.isEncrypted) return message;
    final epoch = message.membershipEpoch!;
    final key = bundle.localEpochKeys[epoch];
    if (key == null ||
        !_validLocalEpochKey(bundle.manifest, bundle.control, epoch, key)) {
      return null;
    }
    Uint8List? clear;
    try {
      clear = await decryptGroupPayload(
        groupId: bundle.manifest.groupId,
        membershipEpoch: epoch,
        author: message.author,
        seq: message.seq,
        prevHash: message.prevHash,
        policyVersion: message.policyVersion,
        createdAtMs: message.createdAtMs,
        payload: message.encryptedPayload!,
        epochKey: key,
      );
      final decoded = GroupMessageCleartext.decode(clear);
      return decoded == null ? null : message.withDecryptedContent(decoded);
    } catch (_) {
      return null;
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<GroupReaction?> _materializeEncryptedReaction(
    GroupBundle bundle,
    GroupReaction reaction,
  ) async {
    if (!reaction.isEncrypted) return reaction;
    final epoch = reaction.membershipEpoch!;
    final key = bundle.localEpochKeys[epoch];
    if (key == null ||
        !_validLocalEpochKey(bundle.manifest, bundle.control, epoch, key)) {
      return null;
    }
    Uint8List? clear;
    try {
      clear = await decryptGroupReactionPayload(
        groupId: bundle.manifest.groupId,
        membershipEpoch: epoch,
        author: reaction.author,
        seq: reaction.seq,
        createdAtMs: reaction.createdAtMs,
        payload: reaction.encryptedPayload!,
        epochKey: key,
      );
      final decoded = GroupReactionCleartext.decode(clear);
      return decoded == null ? null : reaction.withDecryptedContent(decoded);
    } catch (_) {
      return null;
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<
    ({List<GroupEpochRecipientEnvelope> envelopes, Map<int, Uint8List> keys})
  >
  _mergeEpochMaterial({
    required GroupManifest manifest,
    required List<ControlEntry> control,
    required List<GroupEpochRecipientEnvelope> existingEnvelopes,
    required Map<int, Uint8List> existingKeys,
    required List<GroupEpochRecipientEnvelope> incomingEnvelopes,
  }) async {
    final accepted = _acceptedControl(manifest, control);
    final keys = <int, Uint8List>{
      for (final entry in existingKeys.entries)
        if (_validLocalEpochKey(manifest, control, entry.key, entry.value))
          entry.key: entry.value,
    };
    final envelopes = <GroupEpochRecipientEnvelope>[];
    final seen = <String>{};

    void acceptEnvelope(
      GroupEpochRecipientEnvelope envelope, {
      required bool fromWire,
    }) {
      GroupEpochDescriptor? descriptor;
      for (final entry in accepted) {
        final candidate = entry.epochDescriptor;
        if (candidate != null &&
            candidate.groupId == envelope.groupId &&
            candidate.epoch == envelope.epoch &&
            candidate.keyCommitment == envelope.keyCommitment &&
            candidate.recipientCount == envelope.recipientCount &&
            verifyGroupEpochEnvelope(
              descriptor: candidate,
              envelope: envelope,
            )) {
          descriptor = candidate;
          break;
        }
      }
      if (descriptor == null ||
          (fromWire && envelope.recipient != _signer.selfId) ||
          !verifyGroupEpochEnvelope(
            descriptor: descriptor,
            envelope: envelope,
          )) {
        return;
      }
      final identity =
          '${envelope.epoch}:${envelope.recipient.hex}:${envelope.keyCommitment}';
      if (seen.add(identity)) envelopes.add(envelope);
    }

    for (final envelope in existingEnvelopes) {
      acceptEnvelope(envelope, fromWire: false);
    }
    for (final envelope in incomingEnvelopes) {
      acceptEnvelope(envelope, fromWire: true);
    }

    final opener = _epochService;
    if (opener != null) {
      for (final envelope in envelopes) {
        if (envelope.recipient != _signer.selfId ||
            keys.containsKey(envelope.epoch)) {
          continue;
        }
        GroupEpochDescriptor? descriptor;
        for (final entry in accepted) {
          final candidate = entry.epochDescriptor;
          if (candidate != null &&
              candidate.epoch == envelope.epoch &&
              candidate.keyCommitment == envelope.keyCommitment &&
              verifyGroupEpochEnvelope(
                descriptor: candidate,
                envelope: envelope,
              )) {
            descriptor = candidate;
            break;
          }
        }
        if (descriptor == null) continue;
        final issuer = _descriptorEntry(manifest, control, descriptor)?.author;
        if (issuer == null) continue;
        try {
          final opened = await opener.openEpoch(
            descriptor: descriptor,
            envelope: envelope,
            recipient: _signer.selfId,
            expectedIssuer: issuer,
            ourCertVersion: ourCertVersion,
          );
          keys[opened.epoch] = opened.key;
        } catch (_) {
          // Invalid, copied, stale or wrong-recipient epoch material is a
          // terminal silent drop: never reveal membership/key possession.
        }
      }
    }
    return (envelopes: envelopes, keys: keys);
  }

  Future<List<GroupReaction>> _compactReactions(GroupBundle bundle) async {
    final latest = <String, GroupReaction>{};
    final heads = <String, GroupReaction>{};
    for (final stored in bundle.reactions) {
      if (!_validReactionFor(bundle.manifest.groupId, stored)) continue;
      final r = await _materializeEncryptedReaction(bundle, stored);
      if (r == null) continue;
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
      for (final r in bundle.reactions)
        if (_validReactionFor(bundle.manifest.groupId, r) &&
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
    return _serialized(groupId, () => _compactStateLogs(groupId));
  }

  Future<GroupLogCompaction?> _compactStateLogs(NodeId groupId) async {
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
    final reactions = await _compactReactions(b);
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
        b.copyWith(control: control, messages: messages, reactions: reactions),
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
      final epochEnvelopes = (d['ke'] as List? ?? const [])
          .map(GroupEpochRecipientEnvelope.fromJson)
          .whereType<GroupEpochRecipientEnvelope>()
          .toList();
      final localEpochKeys = <int, Uint8List>{};
      final rawKeys = d['kk'];
      if (rawKeys is Map) {
        for (final entry in rawKeys.entries) {
          final epoch = int.tryParse('${entry.key}');
          if (epoch == null ||
              epoch < 0 ||
              epoch > 0xffffffff ||
              entry.value is! String) {
            continue;
          }
          try {
            final key = Uint8List.fromList(base64Decode(entry.value as String));
            if (key.length == 32) localEpochKeys[epoch] = key;
          } catch (_) {
            // Corrupt local key rows are ignored; the retained sealed envelope
            // can recover the key on a later load/ingest.
          }
        }
      }
      final sovereignBundle = d['s'] is String
          ? Uint8List.fromList(base64Decode(d['s'] as String))
          : null;
      if (!_validSovereignBundle(manifest, sovereignBundle)) return null;
      final material = await _mergeEpochMaterial(
        manifest: manifest,
        control: control,
        existingEnvelopes: epochEnvelopes,
        existingKeys: localEpochKeys,
        incomingEnvelopes: const [],
      );
      return GroupBundle(
        manifest: manifest,
        control: control,
        messages: messages,
        reactions: reactions,
        epochEnvelopes: material.envelopes,
        localEpochKeys: material.keys,
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
      if (b.epochEnvelopes.isNotEmpty)
        'ke': b.epochEnvelopes.map((entry) => entry.toJson()).toList(),
      if (b.localEpochKeys.isNotEmpty)
        'kk': {
          for (final entry in b.localEpochKeys.entries)
            '${entry.key}': base64Encode(entry.value),
        },
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
    var bundle = GroupBundle(manifest: manifest, control: [], messages: []);
    final epochService = _epochService;
    if (epochService != null) {
      final key = _randomEpochKey();
      try {
        final sealed = await epochService.sealEpoch(
          groupId: gid,
          epoch: 1,
          epochKey: key,
          recipients: [_signer.selfId],
        );
        final signed = _signer.signControl(
          ControlEntry(
            groupId: gid,
            author: _signer.selfId,
            seq: 0,
            prevHash: '',
            op: ControlOp.rotateEpoch,
            target: null,
            role: null,
            policyVersion: 0,
            createdAtMs: _now(),
            signature: Uint8List(0),
            epochDescriptor: sealed.descriptor,
          ),
        );
        final folded = foldControlLog(
          owner: manifest.owner,
          entries: [signed],
          verify: (entry) => _validControlFor(manifest, entry),
          initialName: manifest.name,
        );
        if (folded.rejected.isNotEmpty ||
            folded.state.epochDescriptor == null) {
          throw StateError('initial group epoch rejected');
        }
        bundle = GroupBundle(
          manifest: manifest,
          control: [signed],
          messages: const [],
          epochEnvelopes: sealed.envelopes,
          localEpochKeys: {1: Uint8List.fromList(key)},
        );
      } finally {
        key.fillRange(0, key.length, 0);
      }
    }
    await _save(bundle);
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

  Uint8List _randomEpochKey() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
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
  }) => _serialized(
    groupId,
    () => _addControlOp(groupId, op, target: target, role: role, text: text),
  );

  Future<bool> _addControlOp(
    NodeId groupId,
    ControlOp op, {
    NodeId? target,
    GroupRole? role,
    String? text,
  }) async {
    final b = await load(groupId);
    if (b == null) return false;
    if (b.manifest.name == kDeviceGroupName) return false;
    var mySeq = _nextSeq(
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
    final epochService = _epochService;
    final generatedKeys = <Uint8List>[];
    final controls = <ControlEntry>[];
    final envelopes = [...b.epochEnvelopes];
    final localKeys = <int, Uint8List>{
      for (final entry in b.localEpochKeys.entries) entry.key: entry.value,
    };
    try {
      GroupEpochSealSet? prepared;
      Uint8List? preparedKey;
      if (epochService != null &&
          (op == ControlOp.removeMember ||
              op == ControlOp.ban ||
              op == ControlOp.rotateEpoch)) {
        final recipients = [
          for (final member in state.members.values)
            if ((op != ControlOp.removeMember && op != ControlOp.ban) ||
                member.nodeId != target)
              member.nodeId,
        ];
        if (recipients.isEmpty) return false;
        preparedKey = _randomEpochKey();
        generatedKeys.add(preparedKey);
        prepared = await epochService.sealEpoch(
          groupId: groupId,
          epoch: state.epoch + 1,
          epochKey: preparedKey,
          recipients: recipients,
        );
      }

      final createdAt = _now();
      final signed = _signer.signControl(
        ControlEntry(
          groupId: groupId,
          author: _signer.selfId,
          seq: mySeq,
          prevHash: '',
          op: op,
          target: target,
          role: role,
          text: text,
          policyVersion: pv,
          createdAtMs: createdAt,
          signature: Uint8List(0),
          epochDescriptor: prepared?.descriptor,
        ),
      );
      controls.add(signed);
      var candidate = [...b.control, signed];
      var folded = foldControlLog(
        owner: b.manifest.owner,
        entries: candidate,
        verify: (entry) => _validControlFor(b.manifest, entry),
        initialName: b.manifest.name,
      );
      if (folded.rejected.any(
        (entry) =>
            identical(entry, signed) ||
            (entry.author == signed.author && entry.seq == signed.seq),
      )) {
        return false;
      }
      if (prepared != null && preparedKey != null) {
        envelopes.addAll(prepared.envelopes);
        localKeys[prepared.descriptor.epoch] = Uint8List.fromList(preparedKey);
      }

      // An add itself must remain readable by legacy peers, then an immediately
      // following signed rotate establishes a key for the post-add membership.
      // New members receive no older envelopes: forward secrecy is the default.
      if (op == ControlOp.addMember && epochService != null) {
        final key = _randomEpochKey();
        generatedKeys.add(key);
        final sealed = await epochService.sealEpoch(
          groupId: groupId,
          epoch: folded.state.epoch + 1,
          epochKey: key,
          recipients: folded.state.members.values.map(
            (member) => member.nodeId,
          ),
        );
        mySeq++;
        final rotate = _signer.signControl(
          ControlEntry(
            groupId: groupId,
            author: _signer.selfId,
            seq: mySeq,
            prevHash: '',
            op: ControlOp.rotateEpoch,
            target: null,
            role: null,
            policyVersion: folded.state.policyVersion,
            createdAtMs: createdAt + 1,
            signature: Uint8List(0),
            epochDescriptor: sealed.descriptor,
          ),
        );
        candidate = [...candidate, rotate];
        folded = foldControlLog(
          owner: b.manifest.owner,
          entries: candidate,
          verify: (entry) => _validControlFor(b.manifest, entry),
          initialName: b.manifest.name,
        );
        if (folded.rejected.any(
          (entry) =>
              identical(entry, rotate) ||
              (entry.author == rotate.author && entry.seq == rotate.seq),
        )) {
          return false;
        }
        controls.add(rotate);
        envelopes.addAll(sealed.envelopes);
        localKeys[sealed.descriptor.epoch] = Uint8List.fromList(key);
      }

      await _save(
        b.copyWith(
          control: candidate,
          epochEnvelopes: envelopes,
          localEpochKeys: localKeys,
        ),
      );
      // A join needs the whole log; every other mutation is a bounded delta.
      if (op == ControlOp.addMember) {
        unawaited(broadcast(groupId));
      } else {
        unawaited(broadcastDelta(groupId, control: controls));
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      for (final key in generatedKeys) {
        key.fillRange(0, key.length, 0);
      }
    }
  }

  /// Rename [groupId] (admins+). The name folds into every member's view via a
  /// signed `setName` op (delta-broadcast). Returns false if we lack permission.
  Future<bool> renameGroup(NodeId groupId, String name) =>
      addControlOp(groupId, ControlOp.setName, text: name.trim());

  /// Leave [groupId]: append a signed `leave` op (removes only us), tell the
  /// remaining members, and let [listGroups] hide it (the fold drops us). Idempotent
  /// if we already aren't a member; false for the owner (who cannot leave, v1).
  Future<bool> leaveGroup(NodeId groupId) =>
      _serialized(groupId, () => _leaveGroup(groupId));

  Future<bool> _leaveGroup(NodeId groupId) async {
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
    await _save(b.copyWith(control: candidate));
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
  }) => _serialized(
    groupId,
    () => _postMessage(
      groupId,
      body,
      attachment: attachment,
      replyTo: replyTo,
      broadcast: broadcast,
    ),
  );

  Future<bool> _postMessage(
    NodeId groupId,
    String body, {
    GroupAttachment? attachment,
    String? replyTo,
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
    final descriptor = state.epochDescriptor;
    final encryptionEstablished = _encryptionEstablished(b.manifest, b.control);
    final key = descriptor == null ? null : b.localEpochKeys[state.epoch];
    if (encryptionEstablished &&
        (descriptor == null ||
            key == null ||
            !_validLocalEpochKey(b.manifest, b.control, state.epoch, key))) {
      return false;
    }
    final createdAt = _now();
    late final GroupMessage unsigned;
    if (descriptor != null && key != null) {
      final clear = GroupMessageCleartext(
        body: body,
        attachment: attachment,
        replyTo: replyTo,
      ).encode();
      try {
        final encrypted = await encryptGroupPayload(
          groupId: groupId,
          membershipEpoch: state.epoch,
          author: _signer.selfId,
          seq: mySeq,
          prevHash: '',
          policyVersion: state.policyVersion,
          createdAtMs: createdAt,
          clearText: clear,
          epochKey: key,
        );
        unsigned = GroupMessage(
          groupId: groupId,
          author: _signer.selfId,
          seq: mySeq,
          prevHash: '',
          body: '',
          version: 2,
          membershipEpoch: state.epoch,
          encryptedPayload: encrypted,
          policyVersion: state.policyVersion,
          createdAtMs: createdAt,
          signature: Uint8List(0),
        );
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } else {
      unsigned = GroupMessage(
        groupId: groupId,
        author: _signer.selfId,
        seq: mySeq,
        prevHash: '',
        body: body,
        policyVersion: state.policyVersion,
        createdAtMs: createdAt,
        signature: Uint8List(0),
        attachment: attachment,
        replyTo: replyTo,
      );
    }
    final signed = _signer.signMessage(unsigned);
    await _save(b.copyWith(messages: [...b.messages, signed]));
    // Ship only the NEW message (delta), not the whole log — a post to a group
    // that already holds an image must not re-chunk that image over the wire.
    if (broadcast) unawaited(broadcastDelta(groupId, messages: [signed]));
    return true;
  }

  // ── Group log gap-fill (reliability brick G1) ─────────────────────────────
  // A delta that dies while EVERY entry node is down is lost for good — the
  // full snapshot only ships on join. Each device therefore sends a compact
  // per-author high-water VECTOR to its deterministic XOR neighbours on boot;
  // a
  // member that holds more replies with ONLY the missing entries. Bandwidth
  // is one small JSON each way when in sync; convergence is eventual (a
  // sampled member that is itself behind just yields nothing this round).

  /// Number of outbound XOR neighbours in the sparse chat-sync overlay.
  static const int kGroupSyncNeighbors = 5;
  static const int kMinGroupSyncNeighbors = 1;
  static const int kMaxGroupSyncNeighbors = 20;

  /// Compatibility name for debug/test callers from before the XOR overlay.
  @Deprecated('Use kGroupSyncNeighbors')
  static const int kGroupSyncFanout = kGroupSyncNeighbors;

  String _groupSyncNeighborsKey(NodeId groupId) =>
      'group.sync.neighbors:${groupId.hex}';

  /// Local outbound overlay degree for one chat. It is deliberately a local
  /// transport preference: each member may choose a different resource /
  /// redundancy trade-off without mutating the signed group policy.
  Future<int> groupSyncNeighborCount(NodeId groupId) async {
    final raw = await _storage.getSetting(_groupSyncNeighborsKey(groupId));
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null ||
        parsed < kMinGroupSyncNeighbors ||
        parsed > kMaxGroupSyncNeighbors) {
      return kGroupSyncNeighbors;
    }
    return parsed;
  }

  Future<void> setGroupSyncNeighborCount(NodeId groupId, int count) async {
    if (count < kMinGroupSyncNeighbors || count > kMaxGroupSyncNeighbors) {
      throw RangeError.range(
        count,
        kMinGroupSyncNeighbors,
        kMaxGroupSyncNeighbors,
        'count',
      );
    }
    await _storage.putSetting(
      _groupSyncNeighborsKey(groupId),
      count == kGroupSyncNeighbors ? '' : '$count',
    );
    changes.value++;
  }

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
      if (b.localEpochKeys.isNotEmpty)
        'ke': (b.localEpochKeys.keys.toList()..sort()),
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
      devLog(() => 'xVeil[groups]: sync request from non-member — drop');
      return false;
    }
    // -1, not 0: seqs start at 0, so "never seen this author" must sit BELOW
    // the first seq or seq-0 entries can never gap-fill (see [vector]).
    int seen(Object? vec, NodeId author) =>
        (vec is Map && vec[author.hex] is int) ? vec[author.hex] as int : -1;
    final heldEpochs = req['ke'] is List
        ? (req['ke'] as List).whereType<int>().toSet()
        : const <int>{};
    final missingEpochEnvelopes = [
      for (final envelope in _epochEnvelopesFor(b, peer))
        if (!heldEpochs.contains(envelope.epoch)) envelope,
    ];
    final missingMsgs = [
      for (final m in b.messages)
        if (_validMessageFor(gid, m) &&
            m.seq > seen(req['g'], m.author) &&
            (!_encryptionEstablished(b.manifest, b.control) ||
                (m.isEncrypted &&
                    _peerCanDecryptEpoch(b, peer, m.membershipEpoch!))))
          m,
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
        if (_validReactionFor(gid, r) &&
            r.seq > seen(req['r'], r.author) &&
            (!_encryptionEstablished(b.manifest, b.control) ||
                (r.isEncrypted &&
                    _peerCanDecryptEpoch(b, peer, r.membershipEpoch!))))
          r,
    ];
    if (missingMsgs.isEmpty &&
        missingCtl.isEmpty &&
        missingRx.isEmpty &&
        missingEpochEnvelopes.isEmpty) {
      return false;
    }
    final overlayId =
        b.manifest.name != kDeviceGroupName &&
            missingCtl.isEmpty &&
            (missingMsgs.isNotEmpty || missingRx.isNotEmpty)
        ? _overlayDeltaId(gid, missingMsgs, missingRx)
        : null;
    if (overlayId != null) _rememberOverlayDelta(overlayId);
    await send(
      peer,
      gid,
      jsonEncode({
        'm': b.manifest.toJson(),
        'c': [for (final e in missingCtl) e.toJson()],
        'g': [for (final m in missingMsgs) m.toJson()],
        'r': [for (final r in missingRx) r.toJson()],
        if (missingEpochEnvelopes.isNotEmpty)
          'ke': [
            for (final envelope in missingEpochEnvelopes) envelope.toJson(),
          ],
        if (overlayId != null) 'ov': overlayId,
      }),
    );
    return true;
  }

  /// Route one inbound group-entry payload from [peer]: a sync VECTOR is
  /// answered (membership-gated), anything else is the normal idempotent
  /// snapshot/delta ingest. The wire wiring points here instead of calling
  /// [ingestSnapshot] directly.
  Future<bool> ingestGroupEntry(NodeId peer, String json) async {
    Map? decoded;
    try {
      final d = jsonDecode(json);
      if (d is Map && d['sreq'] == 1) return handleGroupSyncRequest(peer, d);
      if (d is Map) decoded = d;
    } catch (_) {
      return false; // malformed — drop
    }
    final pending = await _tryPendingDeviceSnapshot(peer, json);
    if (pending != null) return pending;
    final accepted = await ingestSnapshot(json);
    if (accepted && decoded != null) {
      await _relayOverlayDelta(peer, decoded);
    }
    return accepted;
  }

  /// The NON-contact variant of [ingestGroupEntry]: a member's sync vector is
  /// answered (the handler's own membership gate is the same admission), a
  /// bundle goes through the stranger-guarded ingest.
  Future<bool> ingestGroupEntryFromStranger(NodeId peer, String json) async {
    Map? decoded;
    try {
      final d = jsonDecode(json);
      if (d is Map && d['sreq'] == 1) return handleGroupSyncRequest(peer, d);
      if (d is Map) decoded = d;
    } catch (_) {
      return false; // malformed — drop
    }
    final accepted = await ingestSnapshotFromStranger(peer, json);
    if (accepted && decoded != null) {
      await _relayOverlayDelta(peer, decoded);
    }
    return accepted;
  }

  Future<void> _relayOverlayDelta(NodeId source, Map wire) async {
    final overlayId = wire['ov'];
    if (overlayId is! String || overlayId.length != 64) return;
    final manifest = GroupManifest.fromJson(wire['m']);
    if (manifest == null ||
        wire['c'] is! List ||
        (wire['c'] as List).isNotEmpty) {
      return;
    }
    final messages = (wire['g'] as List? ?? const [])
        .map(GroupMessage.fromJson)
        .whereType<GroupMessage>()
        .toList();
    final reactions = (wire['r'] as List? ?? const [])
        .map(GroupReaction.fromJson)
        .whereType<GroupReaction>()
        .toList();
    if (messages.isEmpty && reactions.isEmpty) return;
    if (_overlayDeltaId(manifest.groupId, messages, reactions) != overlayId) {
      return;
    }
    // Relay the validated rows we actually persisted, never attacker-supplied
    // lookalikes that merely reuse a legitimate (author, seq) identity.
    final stored = await load(manifest.groupId);
    if (stored == null) return;
    GroupMessage? storedMessage(GroupMessage incoming) {
      for (final candidate in stored.messages) {
        if (candidate.author == incoming.author &&
            candidate.seq == incoming.seq &&
            jsonEncode(candidate.toJson()) == jsonEncode(incoming.toJson())) {
          return candidate;
        }
      }
      return null;
    }

    GroupReaction? storedReaction(GroupReaction incoming) {
      for (final candidate in stored.reactions) {
        if (candidate.author == incoming.author &&
            candidate.seq == incoming.seq &&
            jsonEncode(candidate.toJson()) == jsonEncode(incoming.toJson())) {
          return candidate;
        }
      }
      return null;
    }

    final validMessages = messages
        .map(storedMessage)
        .whereType<GroupMessage>()
        .toList();
    final validReactions = reactions
        .map(storedReaction)
        .whereType<GroupReaction>()
        .toList();
    if (validMessages.length != messages.length ||
        validReactions.length != reactions.length ||
        !_rememberOverlayDelta(overlayId)) {
      return;
    }
    await broadcastDelta(
      manifest.groupId,
      messages: validMessages,
      reactions: validReactions,
      exclude: {source},
      overlayId: overlayId,
    );
  }

  /// Boot catch-up for EVERY group. Chat groups use the same deterministic
  /// XOR neighbours as live deltas; device groups retain all-device delivery.
  /// Cheap when in sync (one small JSON), and the reply path ships only what
  /// this device actually lacks.
  Future<void> nudgeGroupSyncAll() async {
    for (final gidHex in await _index()) {
      final NodeId gid;
      try {
        gid = NodeId.fromHex(gidHex);
      } catch (_) {
        continue;
      }
      final beforeUpgrade = await load(gid);
      final beforeState = beforeUpgrade == null
          ? null
          : foldControlLog(
              owner: beforeUpgrade.manifest.owner,
              entries: beforeUpgrade.control,
              verify: (entry) =>
                  _validControlFor(beforeUpgrade.manifest, entry),
              initialName: beforeUpgrade.manifest.name,
            ).state;
      if (_epochService != null &&
          beforeUpgrade != null &&
          beforeUpgrade.manifest.name != kDeviceGroupName &&
          beforeUpgrade.manifest.owner == _signer.selfId &&
          beforeState != null &&
          !_encryptionEstablished(
            beforeUpgrade.manifest,
            beforeUpgrade.control,
          )) {
        // One-time migration for legacy groups: the genesis owner establishes
        // the first signed epoch and fans its recipient envelopes on boot.
        await addControlOp(gid, ControlOp.rotateEpoch);
      }
      await compactStateLogs(gid);
      await nudgeGroupSync(gid);
    }
  }

  /// Starts one compact anti-entropy exchange with this chat's current XOR
  /// neighbours. Used at boot and immediately after changing the local `k`.
  Future<int> nudgeGroupSync(NodeId groupId) async {
    final send = _send;
    if (send == null) return 0;
    final bundle = await load(groupId);
    final req = await buildGroupSyncRequest(groupId);
    final state = await stateOf(groupId);
    if (bundle == null || req == null || state == null) return 0;
    final others = <NodeId>[
      for (final member in state.members.values)
        if (member.nodeId != _signer.selfId &&
            (!bundle.manifest.isSovereignDevice ||
                member.nodeId != bundle.manifest.owner))
          member.nodeId,
    ];
    final peers = bundle.manifest.name == kDeviceGroupName
        ? others
        : nearestGroupNodesByXor(
            _signer.selfId,
            others,
            k: await groupSyncNeighborCount(groupId),
          );
    for (final peer in peers) {
      await send(peer, groupId, jsonEncode(req));
    }
    return peers.length;
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
      if (!m.isEncrypted) {
        final mem = state.memberOf(m.author);
        if (mem == null || mem.muted) continue;
        out.add(m);
        continue;
      }
      final materialized = await _materializeEncryptedMessage(b, m);
      if (materialized != null) out.add(materialized);
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
  }) => _serialized(
    groupId,
    () => _react(groupId, msgRef, emoji, broadcast: broadcast),
  );

  Future<bool> _react(
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
    final visibleReactions = <GroupReaction>[];
    for (final reaction in b.reactions) {
      if (!_validReactionFor(groupId, reaction) ||
          !state.isMember(reaction.author)) {
        continue;
      }
      final materialized = await _materializeEncryptedReaction(b, reaction);
      if (materialized != null) visibleReactions.add(materialized);
    }
    final onMsg =
        foldGroupReactions(visibleReactions, _signer.verifyReaction)[msgRef] ??
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
    final descriptor = state.epochDescriptor;
    final encryptionEstablished = _encryptionEstablished(b.manifest, b.control);
    final key = descriptor == null ? null : b.localEpochKeys[state.epoch];
    if (encryptionEstablished &&
        (descriptor == null ||
            key == null ||
            !_validLocalEpochKey(b.manifest, b.control, state.epoch, key))) {
      return false;
    }
    final createdAt = _now();
    late final GroupReaction unsigned;
    if (descriptor != null && key != null) {
      final clear = GroupReactionCleartext(
        target: msgRef,
        emoji: next,
      ).encode();
      try {
        final encrypted = await encryptGroupReactionPayload(
          groupId: groupId,
          membershipEpoch: state.epoch,
          author: _signer.selfId,
          seq: mySeq,
          createdAtMs: createdAt,
          clearText: clear,
          epochKey: key,
        );
        unsigned = GroupReaction(
          groupId: groupId,
          author: _signer.selfId,
          seq: mySeq,
          target: '',
          emoji: '',
          version: 2,
          membershipEpoch: state.epoch,
          encryptedPayload: encrypted,
          createdAtMs: createdAt,
          signature: Uint8List(0),
        );
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } else {
      unsigned = GroupReaction(
        groupId: groupId,
        author: _signer.selfId,
        seq: mySeq,
        target: msgRef,
        emoji: next,
        createdAtMs: createdAt,
        signature: Uint8List(0),
      );
    }
    final signed = _signer.signReaction(unsigned);
    await _save(b.copyWith(reactions: [...b.reactions, signed]));
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
    final materialized = <GroupReaction>[];
    for (final reaction in b.reactions) {
      if (!_validReactionFor(groupId, reaction) ||
          !state.isMember(reaction.author)) {
        continue;
      }
      final visible = await _materializeEncryptedReaction(b, reaction);
      if (visible != null) materialized.add(visible);
    }
    return foldGroupReactions(materialized, _signer.verifyReaction);
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
      devLog(() => 'xVeil[groups]: content request for unknown group — drop');
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
      devLog(
        () => 'xVeil[groups]: content request DENIED (${denial.name}) — drop',
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
      devLog(() => 'xVeil[groups]: stranger snapshot DENIED — drop');
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
    if (!_listEquals(_manifestHash(manifest), pending.manifestHash))
      return false;
    if (!await ingestSnapshot(bundleJson)) return false;
    if (!await adoptDeviceGroup(pending.groupId)) return false;
    await cancelPendingDeviceAdoption();
    return true;
  }

  /// Fetch [cid] of [groupId], preferring [holder] (normally the message
  /// author) but authorizing EVERY other current member as a candidate seeder.
  /// Thus a member that downloaded and verified the blob can keep serving it
  /// after the author goes offline. We intentionally do not publish persistent
  /// holder/read advertisements: one explicit user fetch sends the same signed
  /// membership request to all candidates, non-holders deny silently, and the
  /// content-addressed pull stops at the first verified source.
  Future<bool> fetchGroupContent(
    NodeId groupId,
    String cid,
    NodeId holder,
  ) async {
    final pullAny = startContentPullFromAny;
    final pullOne = startContentPull;
    if (pullAny == null && pullOne == null) return false;
    final state = await stateOf(groupId);
    if (state == null || !state.isMember(_signer.selfId)) return false;
    if (!(await referencedContentIds(groupId)).contains(cid)) return false;

    final members = [
      for (final member in state.members.values)
        if (member.nodeId != _signer.selfId) member.nodeId,
    ]..sort((a, b) => a.hex.compareTo(b.hex));
    if (members.isEmpty) return false;
    final candidates = <NodeId>[
      if (members.contains(holder)) holder,
      for (final member in members)
        if (member != holder) member,
    ];

    // Best-effort fanout: one temporarily unreachable member must not prevent
    // a reachable downloaded holder from receiving its authorization.
    final requestTargets = [
      for (final candidate in candidates.skip(1)) candidate,
      candidates.first,
    ];
    await Future.wait<bool>([
      // Launch fallback members before the preferred author: the pull still
      // prefers the author, but its dead route cannot queue every grant behind
      // it inside a serialized transport.
      for (final candidate in requestTargets)
        requestGroupContent(groupId, cid, candidate).catchError((Object e) {
          devLog(
            () =>
                'xVeil[groups]: content request to '
                '${candidate.short} failed locally: $e',
          );
          return false;
        }),
    ]).timeout(
      contentRequestFanoutTimeout,
      onTimeout: () {
        devLog(
          () =>
              'xVeil[groups]: content request fanout deadline reached; '
              'starting scoped pull',
        );
        return const <bool>[];
      },
    );
    // Durable requests need a wire round-trip before grants exist. Pull retries
    // preserve correctness; this delay avoids burning the first open on DENIED.
    if (contentGrantDelay > Duration.zero) {
      await Future<void>.delayed(contentGrantDelay);
    }
    if (pullAny != null) {
      await pullAny(candidates, cid);
    } else {
      await pullOne!(candidates.first, cid);
    }
    return true;
  }

  /// Ingest an externally-received control entry (from a peer-sync brick, or a
  /// hook). Appends if it isn't already present; the fold decides validity on
  /// read, so a bogus entry simply never applies.
  Future<void> ingestControl(NodeId groupId, ControlEntry e) =>
      _serialized(groupId, () => _ingestControl(groupId, e));

  Future<void> _ingestControl(NodeId groupId, ControlEntry e) async {
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
    await _save(b.copyWith(control: [...b.control, e]));
  }

  List<GroupEpochRecipientEnvelope> _epochEnvelopesFor(
    GroupBundle bundle,
    NodeId recipient, {
    Iterable<ControlEntry>? controls,
  }) {
    final descriptors =
        (controls ?? _acceptedControl(bundle.manifest, bundle.control))
            .map((entry) => entry.epochDescriptor)
            .whereType<GroupEpochDescriptor>()
            .toList();
    return [
      for (final envelope in bundle.epochEnvelopes)
        if (envelope.recipient == recipient &&
            descriptors.any(
              (descriptor) => verifyGroupEpochEnvelope(
                descriptor: descriptor,
                envelope: envelope,
              ),
            ))
          envelope,
    ];
  }

  bool _peerCanDecryptEpoch(GroupBundle bundle, NodeId peer, int epoch) {
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (state.epochDescriptor?.epoch == epoch && state.isMember(peer)) {
      return true;
    }
    return _epochEnvelopesFor(
      bundle,
      peer,
    ).any((envelope) => envelope.epoch == epoch);
  }

  /// Serialize a full snapshot tailored to one recipient. Epoch envelopes are
  /// never broadcast as a member list: the peer receives only its own sealed
  /// record and only ciphertext epochs it can open. [recipient] may be omitted
  /// by legacy unit/debug callers; such snapshots contain no epoch material.
  String snapshotJson(GroupBundle b, {NodeId? recipient}) {
    final encryptionEstablished = _encryptionEstablished(b.manifest, b.control);
    final epochEnvelopes = recipient == null
        ? const <GroupEpochRecipientEnvelope>[]
        : _epochEnvelopesFor(b, recipient);
    return jsonEncode({
      'm': b.manifest.toJson(),
      'c': b.control
          .where((e) => _validControlFor(b.manifest, e))
          .map((e) => e.toJson())
          .toList(),
      'g': b.messages
          .where(
            (message) =>
                _validMessageFor(b.manifest.groupId, message) &&
                (!encryptionEstablished
                    ? true
                    : message.isEncrypted &&
                          recipient != null &&
                          _peerCanDecryptEpoch(
                            b,
                            recipient,
                            message.membershipEpoch!,
                          )),
          )
          .map((message) => message.toJson())
          .toList(),
      'r': b.reactions
          .where(
            (reaction) =>
                _validReactionFor(b.manifest.groupId, reaction) &&
                (!encryptionEstablished
                    ? true
                    : reaction.isEncrypted &&
                          recipient != null &&
                          _peerCanDecryptEpoch(
                            b,
                            recipient,
                            reaction.membershipEpoch!,
                          )),
          )
          .map((r) => r.toJson())
          .toList(),
      if (epochEnvelopes.isNotEmpty)
        'ke': epochEnvelopes.map((entry) => entry.toJson()).toList(),
      if (b.sovereignBundle != null) 's': base64Encode(b.sovereignBundle!),
    });
  }

  /// Ingest a received snapshot: materialize the group if new (manifest +
  /// index), then merge control + message entries (dedup by author+seq).
  /// Idempotent — re-delivery of the same snapshot is a no-op.
  Future<bool> ingestSnapshot(String bundleJson) async {
    try {
      final value = jsonDecode(bundleJson);
      final manifest = value is Map ? value['m'] : null;
      final gid = manifest is Map ? manifest['gid'] : null;
      if (gid is! String) return false;
      return _serialized(
        NodeId.fromHex(gid),
        () => _ingestSnapshot(bundleJson),
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ingestSnapshot(String bundleJson) async {
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
    final inEpochEnvelopes = (d['ke'] as List? ?? const [])
        .map(GroupEpochRecipientEnvelope.fromJson)
        .whereType<GroupEpochRecipientEnvelope>()
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
    final material = await _mergeEpochMaterial(
      manifest: man,
      control: control,
      existingEnvelopes:
          existing?.epochEnvelopes ?? const <GroupEpochRecipientEnvelope>[],
      existingKeys: existing?.localEpochKeys ?? const <int, Uint8List>{},
      incomingEnvelopes: inEpochEnvelopes,
    );
    final encryptionEstablished = _encryptionEstablished(man, control);
    final fresh = <GroupMessage>[];
    for (final m in inMsgs) {
      if (!_validMessageFor(manifest.groupId, m)) {
        continue;
      }
      if (m.isEncrypted) {
        final epoch = m.membershipEpoch!;
        final key = material.keys[epoch];
        if (key == null ||
            !_validLocalEpochKey(man, control, epoch, key) ||
            !mergedState.isMember(m.author)) {
          continue;
        }
      } else if (encryptionEstablished || !mergedState.isMember(m.author)) {
        // Once a signed epoch descriptor exists, a clear v1 row is a
        // downgrade attempt. Historical local v1 rows remain readable but are
        // never newly imported into an encrypted group.
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
      if (!_validReactionFor(manifest.groupId, r)) {
        continue;
      }
      if (r.isEncrypted) {
        final epoch = r.membershipEpoch!;
        final key = material.keys[epoch];
        if (key == null ||
            !_validLocalEpochKey(man, control, epoch, key) ||
            !mergedState.isMember(r.author)) {
          continue;
        }
      } else if (encryptionEstablished || !mergedState.isMember(r.author)) {
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
    final saved = GroupBundle(
      manifest: man,
      control: control,
      messages: messages,
      reactions: reactions,
      epochEnvelopes: material.envelopes,
      localEpochKeys: material.keys,
      sovereignBundle: existing?.sovereignBundle ?? incomingSovereignBundle,
    );
    await _save(saved);
    if (existing == null) {
      final idx = await _index();
      if (!idx.contains(man.groupId.hex)) {
        idx.add(man.groupId.hex);
        await _setIndex(idx);
      }
    }
    if (man.name != kDeviceGroupName &&
        _epochService != null &&
        _encryptionEstablished(man, control) &&
        mergedState.epochDescriptor == null &&
        mergedState.memberOf(_signer.selfId)?.role == GroupRole.owner) {
      // A leave or a concurrent stale departure descriptor advances
      // membership without a usable key. Only the genesis owner repairs it,
      // avoiding an admin race; writes remain fail-closed until this succeeds.
      unawaited(addControlOp(man.groupId, ControlOp.rotateEpoch));
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
          final materialized = await _materializeEncryptedMessage(saved, m);
          if (materialized != null) _deviceIncomingCtl.add(materialized);
        }
      }
    } else {
      for (final m in fresh) {
        final materialized = await _materializeEncryptedMessage(saved, m);
        if (materialized != null) {
          _incomingCtl.add((groupId: man.groupId, message: materialized));
        }
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
    if (existing != null && !_listEquals(existing, certificate)) return null;
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
      _listEquals(manifest.genesisPubKey, sovereign.publicKey);

  bool _canUpgradeSovereign(
    GroupManifest manifest,
    SovereignGroupSigner sovereign,
  ) =>
      manifest.isSovereignDevice &&
      manifest.signatureAlgorithm == 'ed25519' &&
      sovereign.algorithm == 'ed25519+falcon512' &&
      sovereign.publicKey.length == 929 &&
      _listEquals(manifest.genesisPubKey, sovereign.publicKey.sublist(0, 32));

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
    await _save(bundle.copyWith(control: candidate));
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
    var n = 0;
    for (final m in state.members.values) {
      if (m.nodeId == _signer.selfId ||
          (b.manifest.isSovereignDevice && m.nodeId == b.manifest.owner)) {
        continue;
      }
      await send(m.nodeId, groupId, snapshotJson(b, recipient: m.nodeId));
      n++;
    }
    return n;
  }

  /// Fan a DELTA (only the just-added entries). Chat messages and reactions go
  /// to the [kGroupSyncNeighbors] XOR-closest members and are relayed across
  /// that sparse overlay. Control changes and device-group events still reach
  /// every member: roster/key changes carry per-recipient epoch material and
  /// cannot safely depend on a relay that does not own everybody's envelope.
  /// A new member still gets a full [broadcast] on join.
  Future<int> broadcastDelta(
    NodeId groupId, {
    List<ControlEntry> control = const [],
    List<GroupMessage> messages = const [],
    List<GroupReaction> reactions = const [],
    Set<NodeId> exclude = const {},
    String? overlayId,
  }) async {
    final send = _send;
    final b = await load(groupId);
    if (send == null || b == null) return 0;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final candidates = <NodeId>[
      for (final member in state.members.values)
        if (member.nodeId != _signer.selfId &&
            (!b.manifest.isSovereignDevice ||
                member.nodeId != b.manifest.owner))
          member.nodeId,
    ];
    final sparse = control.isEmpty && b.manifest.name != kDeviceGroupName;
    final neighborCount = sparse
        ? await groupSyncNeighborCount(groupId)
        : kGroupSyncNeighbors;
    final peers = sparse
        ? nearestGroupNodesByXor(_signer.selfId, candidates, k: neighborCount)
        : candidates;
    final deltaId = sparse
        ? (overlayId ?? _overlayDeltaId(groupId, messages, reactions))
        : null;
    if (deltaId != null) _rememberOverlayDelta(deltaId);
    var n = 0;
    for (final peer in peers) {
      if (exclude.contains(peer)) continue;
      final epochEnvelopes = _epochEnvelopesFor(b, peer, controls: control);
      final encryptionEstablished = _encryptionEstablished(
        b.manifest,
        b.control,
      );
      final peerMessages = [
        for (final message in messages)
          if (!encryptionEstablished ||
              (message.isEncrypted &&
                  _peerCanDecryptEpoch(b, peer, message.membershipEpoch!)))
            message,
      ];
      final peerReactions = [
        for (final reaction in reactions)
          if (!encryptionEstablished ||
              (reaction.isEncrypted &&
                  _peerCanDecryptEpoch(b, peer, reaction.membershipEpoch!)))
            reaction,
      ];
      await send(
        peer,
        groupId,
        jsonEncode({
          'm': b.manifest.toJson(),
          'c': control.map((entry) => entry.toJson()).toList(),
          'g': peerMessages.map((message) => message.toJson()).toList(),
          'r': peerReactions.map((reaction) => reaction.toJson()).toList(),
          if (epochEnvelopes.isNotEmpty)
            'ke': epochEnvelopes.map((entry) => entry.toJson()).toList(),
          if (deltaId != null) 'ov': deltaId,
        }),
      );
      n++;
    }
    return n;
  }

  String _overlayDeltaId(
    NodeId groupId,
    Iterable<GroupMessage> messages,
    Iterable<GroupReaction> reactions,
  ) {
    final identities = <String>[
      for (final message in messages) 'm:${message.author.hex}:${message.seq}',
      for (final reaction in reactions)
        'r:${reaction.author.hex}:${reaction.seq}',
    ]..sort();
    return crypto.sha256
        .convert(utf8.encode('${groupId.hex}|${identities.join('|')}'))
        .toString();
  }

  bool _rememberOverlayDelta(String id) {
    if (!_seenOverlayDeltas.add(id)) return false;
    if (_seenOverlayDeltas.length > _kSeenOverlayDeltaLimit) {
      _seenOverlayDeltas.remove(_seenOverlayDeltas.first);
    }
    return true;
  }

  /// Releases the pure-Dart event surfaces owned by this identity instance.
  /// Hosts must call this before replacing/closing the active identity so a
  /// stale group feed cannot survive an identity switch.
  Future<void> dispose() async {
    changes.dispose();
    await _groupCallIncomingCtl.close();
    await _deviceIncomingCtl.close();
    await _incomingCtl.close();
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
