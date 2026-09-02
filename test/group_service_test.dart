import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;
import 'package:xveil/core/ids.dart';
import 'package:xveil/crypto/blake3.dart';
import 'package:xveil/data/node/space_discovery_transport.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/bootstrap_invite.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/cloud.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/device_link.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_payload.dart';
import 'package:xveil/domain/group_policy.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/message_mention.dart';
import 'package:xveil/domain/space_abuse_report.dart';
import 'package:xveil/domain/space_channel.dart';
import 'package:xveil/domain/space_discovery.dart';
import 'package:xveil/domain/space_discovery_carrier.dart';
import 'package:xveil/domain/space_discovery_search.dart';
import 'package:xveil/domain/space_invite.dart';
import 'package:xveil/domain/space_lifecycle.dart';
import 'package:xveil/domain/space_join_request.dart';
import 'package:xveil/domain/space_membership.dart';
import 'package:xveil/domain/space_moderation.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/domain/space_policy_audit.dart';
import 'package:xveil/domain/space_public_discussion.dart';
import 'package:xveil/domain/space_public_feed.dart';
import 'package:xveil/domain/space_rules.dart';
import 'package:xveil/domain/space_recommendation.dart';
import 'package:xveil/domain/space_retention.dart';
import 'package:xveil/domain/inline_custom_emoji.dart';
import 'package:xveil/state/group_epoch_service.dart';
import 'package:xveil/state/group_service_providers.dart';
import 'package:xveil/state/space_observability.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

NodeId _ordinalId(int value) {
  final bytes = Uint8List(32);
  bytes[0] = (value >> 8) & 0xff;
  bytes[1] = value & 0xff;
  return NodeId(bytes);
}

/// A fake signer: a deterministic "public key" per author (its node id bytes),
/// signatures are a fixed marker, verification accepts anything well-formed.
class _FakeSigner implements GroupSigner {
  _FakeSigner(this._self);
  final NodeId _self;

  @override
  NodeId get selfId => _self;
  @override
  Uint8List get selfPubKey => _self.bytes;

  @override
  SpaceManifest signSpaceManifest(SpaceManifest value) => value.withSignature(
    _fakeSovereignSignature(selfPubKey, value.canonicalBytes()),
  );
  @override
  ControlEntry signControl(ControlEntry u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  GroupMessage signMessage(GroupMessage u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  GroupReaction signReaction(GroupReaction u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  SpacePost signPost(SpacePost u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  GroupContentRequest signContentRequest(GroupContentRequest u) =>
      u.withSignature(Uint8List(64), u.requester.bytes);
  @override
  GroupCallSignal signCallSignal(GroupCallSignal u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  SpaceModerationAppeal signModerationAppeal(SpaceModerationAppeal u) =>
      u.withSignature(Uint8List(64), u.appellant.bytes);
  @override
  SpaceModerationAppealDecision signModerationAppealDecision(
    SpaceModerationAppealDecision u,
  ) => u.withSignature(Uint8List(64), u.reviewer.bytes);
  @override
  bool verifyControl(ControlEntry e) =>
      e.signature.length == 64 && e.authorPubKey.length == 32;
  @override
  bool verifyContentRequest(GroupContentRequest r) =>
      r.signature.length == 64 && r.authorPubKey.length == 32;
  @override
  bool verifyCallSignal(GroupCallSignal s) =>
      s.signature.length == 64 && s.authorPubKey.length == 32;
  @override
  bool verifyModerationAppeal(SpaceModerationAppeal appeal) =>
      appeal.signature.length == 64 && appeal.authorPubKey.length == 32;
  @override
  bool verifyModerationAppealDecision(SpaceModerationAppealDecision decision) =>
      decision.signature.length == 64 && decision.authorPubKey.length == 32;
  @override
  bool verifyMessage(GroupMessage m) =>
      m.signature.length == 64 && m.authorPubKey.length == 32;
  @override
  bool verifyReaction(GroupReaction r) =>
      r.signature.length == 64 && r.authorPubKey.length == 32;
  @override
  bool verifyPost(SpacePost post) =>
      post.signature.length == 64 && post.authorPubKey.length == 32;
  @override
  bool verifySpaceManifest(SpaceManifest value) =>
      value.owner == NodeId(Uint8List.fromList(value.genesisPubKey)) &&
      _bytesEqual(
        _fakeSovereignSignature(value.genesisPubKey, value.canonicalBytes()),
        value.signature,
      );
  @override
  ({Uint8List signature, Uint8List publicKey}) signDetached(
    Uint8List message,
  ) => (
    signature: _fakeSovereignSignature(selfPubKey, message),
    publicKey: selfPubKey,
  );
  @override
  bool verifyDetached({
    required NodeId signer,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) =>
      signer == NodeId(Uint8List.fromList(publicKey)) &&
      _bytesEqual(_fakeSovereignSignature(publicKey, message), signature);
  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) =>
      algorithm == 'ed25519' &&
      nodeId == NodeId(Uint8List.fromList(publicKey)) &&
      _bytesEqual(_fakeSovereignSignature(publicKey, message), signature);
}

/// Keeps the control and detached fake signatures cryptographically
/// interchangeable, matching the production identity key used by public
/// authority links.
class _AuthorityFakeSigner extends _FakeSigner {
  _AuthorityFakeSigner(super._self);

  @override
  ControlEntry signControl(ControlEntry value) => value.withSignature(
    _fakeSovereignSignature(selfPubKey, value.canonicalBytes()),
    selfPubKey,
  );

  @override
  bool verifyControl(ControlEntry value) =>
      value.authorPubKey.length == 32 &&
      value.signature.length == 64 &&
      value.author == NodeId(Uint8List.fromList(value.authorPubKey)) &&
      _bytesEqual(
        _fakeSovereignSignature(value.authorPubKey, value.canonicalBytes()),
        value.signature,
      );
}

class _NativeSovereignVerifier extends _FakeSigner {
  _NativeSovereignVerifier(super._self);

  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => veil.verifySovereignSignature(
    algorithm: algorithm,
    nodeId: nodeId.bytes,
    publicKey: publicKey,
    message: message,
    signature: signature,
  );
}

class _DiscoveryFakeSigner extends _FakeSigner {
  _DiscoveryFakeSigner._(this._publicKey, NodeId self) : super(self);

  factory _DiscoveryFakeSigner(int seed) {
    final publicKey = Uint8List.fromList(
      List<int>.generate(32, (index) => seed + index),
    );
    return _DiscoveryFakeSigner._(publicKey, NodeId(blake3Hash(publicKey)));
  }

  final Uint8List _publicKey;

  @override
  Uint8List get selfPubKey => _publicKey;

  @override
  bool verifySpaceManifest(SpaceManifest value) =>
      value.owner == NodeId(blake3Hash(value.genesisPubKey)) &&
      _bytesEqual(
        _fakeSovereignSignature(value.genesisPubKey, value.canonicalBytes()),
        value.signature,
      );

  @override
  bool verifyDetached({
    required NodeId signer,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) =>
      signer == NodeId(blake3Hash(publicKey)) &&
      _bytesEqual(_fakeSovereignSignature(publicKey, message), signature);

  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) =>
      algorithm == 'ed25519' &&
      nodeId == NodeId(blake3Hash(publicKey)) &&
      _bytesEqual(_fakeSovereignSignature(publicKey, message), signature);
}

class _FakeSpaceDiscoveryTransport implements SpaceDiscoveryTransport {
  final List<Uint8List> records = <Uint8List>[];
  final List<SpaceDiscoveryCarrierRoute> resolvedRoutes =
      <SpaceDiscoveryCarrierRoute>[];
  bool returnUnrelatedRecords = true;

  @override
  Future<void> publish(Uint8List record) async {
    records.add(Uint8List.fromList(record));
  }

  @override
  Future<List<Uint8List>> resolve(
    SpaceDiscoveryCarrierRoute route, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    resolvedRoutes.add(
      SpaceDiscoveryCarrierRoute(route.kind, Uint8List.fromList(route.body)),
    );
    return [
      for (final record in records)
        if (returnUnrelatedRecords ||
            (SpaceDiscoveryCarrier.fromBytes(record)?.route.sameAs(route) ??
                false))
          Uint8List.fromList(record),
    ];
  }
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _fakeSovereignSignature(Uint8List publicKey, Uint8List message) {
  final digest = sha256.convert([...publicKey, ...message]).bytes;
  return Uint8List.fromList([...digest, ...digest]);
}

class _FakeSovereign implements SovereignGroupSigner {
  _FakeSovereign(this.nodeId);
  @override
  final NodeId nodeId;
  bool _closed = false;
  @override
  String get algorithm => 'ed25519';
  @override
  Uint8List get publicKey => Uint8List.fromList(nodeId.bytes);
  @override
  Uint8List sign(Uint8List message) {
    if (_closed) throw StateError('closed');
    return _fakeSovereignSignature(publicKey, message);
  }

  @override
  void close() => _closed = true;
}

/// Pauses the first epoch envelope for [heldRecipient]. This puts a membership
/// decision precisely inside the old check-to-commit window without sleeps.
class _GatedMailboxCrypto implements VeilMailboxCrypto {
  _GatedMailboxCrypto({
    required this.senderForOpen,
    required this.heldRecipient,
  }) : _delegate = LoopbackMailboxCrypto(senderForOpen: senderForOpen);

  final NodeId senderForOpen;
  final NodeId heldRecipient;
  final LoopbackMailboxCrypto _delegate;
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool _held = false;

  @override
  Future<Uint8List> seal({
    required NodeId recipient,
    required Uint8List appId,
    required int endpointId,
    required Uint8List data,
  }) async {
    if (!_held && recipient == heldRecipient) {
      _held = true;
      entered.complete();
      await release.future;
    }
    return _delegate.seal(
      recipient: recipient,
      appId: appId,
      endpointId: endpointId,
      data: data,
    );
  }

  @override
  Future<OpenedMailboxMessage> open({
    required Uint8List blob,
    required int ourCertVersion,
  }) => _delegate.open(blob: blob, ourCertVersion: ourCertVersion);
}

/// Pauses one group bundle write after it is durable but before the caller can
/// run its post-save relationship guard.
class _PostWriteGatedStorage extends HiddenVolumeStorage {
  _PostWriteGatedStorage()
    : super(
        ({required Uint8List password, required bool create}) =>
            FakeKvLogStore(),
      );

  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool gateNextGroupWrite = false;

  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) async {
    await super.storeFile(fileId, bytes, name: name);
    if (gateNextGroupWrite && fileId.startsWith('group:')) {
      gateNextGroupWrite = false;
      entered.complete();
      await release.future;
    }
  }
}

class _ControlledGroupWriteStorage extends HiddenVolumeStorage {
  _ControlledGroupWriteStorage()
    : super(
        ({required Uint8List password, required bool create}) =>
            FakeKvLogStore(),
      );

  int groupWriteAttempts = 0;
  bool failNextGroupWrite = false;

  void resetGroupWriteAttempts() {
    groupWriteAttempts = 0;
  }

  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) async {
    if (fileId.startsWith('group:')) {
      groupWriteAttempts++;
      if (failNextGroupWrite) {
        failNextGroupWrite = false;
        throw StateError('injected group bundle write failure');
      }
    }
    await super.storeFile(fileId, bytes, name: name);
  }
}

/// Models the store contract that made a read racing a save look like a
/// deleted group: `loadFile` answers null for a file that is "unknown OR
/// INCOMPLETE" (storage.dart), and `storeFile` is not atomic to readers.
/// While [gate] is armed, a group bundle write parks and reads of that same
/// key see the half-written state.
class _HalfWrittenBundleStorage extends HiddenVolumeStorage {
  _HalfWrittenBundleStorage()
    : super(
        ({required Uint8List password, required bool create}) =>
            FakeKvLogStore(),
      );

  final _incomplete = <String>{};
  Completer<void>? gate;

  /// Make the parked write fail when the gate opens — so the failure happens
  /// while a reader is already waiting on it.
  bool failOnRelease = false;

  /// Park ONLY the group index, letting bundle writes through — the shape a
  /// create has when the race is on the index rather than the bundle.
  bool gateIndexOnly = false;

  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) async {
    final held = gate;
    final gatable = gateIndexOnly
        ? fileId == 'groups.index'
        : fileId.startsWith('group:') || fileId == 'groups.index';
    if (held == null || !gatable) {
      return super.storeFile(fileId, bytes, name: name);
    }
    _incomplete.add(fileId);
    try {
      await held.future;
      if (failOnRelease) {
        failOnRelease = false;
        throw StateError('injected failure while a reader waits');
      }
      await super.storeFile(fileId, bytes, name: name);
    } finally {
      _incomplete.remove(fileId);
    }
  }

  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) async {
    if (_incomplete.contains(fileId)) return null;
    return super.loadFile(fileId, maxBytes: maxBytes);
  }
}

class _CountingGroupReadStorage extends HiddenVolumeStorage {
  _CountingGroupReadStorage()
    : super(
        ({required Uint8List password, required bool create}) =>
            FakeKvLogStore(),
      );

  int groupBundleReads = 0;

  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) async {
    if (fileId.startsWith('group:')) groupBundleReads++;
    return super.loadFile(fileId, maxBytes: maxBytes);
  }
}


/// The one chain in a sync vector whose scope starts with [prefix].
///
/// Looked up by prefix because a chain's scope now ends with the DEVICE that
/// wrote it — two devices of one identity each keep their own hash chain, which
/// is what stopped them reading each other as one author equivocating. The
/// tests care about the chain, not about the key's spelling.
Map<dynamic, dynamic> chainOf(Map<dynamic, dynamic> chains, String prefix) {
  final matches = chains.entries
      .where((entry) => '${entry.key}'.startsWith(prefix))
      .toList();
  expect(
    matches,
    hasLength(1),
    reason: 'expected exactly one chain under "$prefix", got ${chains.keys}',
  );
  return matches.single.value as Map<dynamic, dynamic>;
}

void main() {
  final hasVeilFfi = (Platform.environment['VEIL_FFI_DYLIB'] ?? '').isNotEmpty;
  final owner = _id(1);
  final bob = _id(3);
  final carol = _id(4);
  final stranger = _id(7);
  final sovereign = _FakeSovereign(_id(9));

  /// Fresh storage + an owner-perspective service; extra services over the SAME
  /// storage model other members on their own devices.
  Future<(GroupService, dynamic Function(NodeId))> setup() async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    GroupService member(NodeId self) =>
        GroupService(storage, _FakeSigner(self));
    return (member(owner), member);
  }

  test('create -> owner is sole member, group persists + lists', () async {
    final (svc, _) = await setup();
    final ticks = <int>[];
    void recordTick() => ticks.add(svc.changes.value);
    svc.changes.addListener(recordTick);
    addTearDown(() => svc.changes.removeListener(recordTick));
    final gid = await svc.createGroup('Family');
    final state = (await svc.stateOf(gid))!;
    final manifest = (await svc.load(gid))!.manifest;
    expect(state.roleOf(owner), GroupRole.owner);
    expect(state.members.length, 1);
    final groups = await svc.listGroups();
    expect(groups.single.name, 'Family');
    expect(groups.single.groupId, gid);
    expect(
      groups.single.lastTs,
      manifest.createdAtMs,
      reason:
          'an empty new group must sort by creation time instead of falling '
          'to the bottom of Chats with timestamp zero',
    );
    expect(ticks, [
      1,
    ], reason: 'a mounted Chats list must refresh after the durable create');
  });

  test('mounted group list provider emits a newly created group', () async {
    final (service, _) = await setup();
    final container = ProviderContainer(
      overrides: [groupServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    final values = <List<GroupListEntry>>[];
    final subscription = container.listen(
      groupListProvider,
      (_, next) => next.whenData(values.add),
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    expect(await container.read(groupListProvider.future), isEmpty);
    final groupId = await service.createGroup('Visible immediately');
    for (var attempt = 0; attempt < 20; attempt++) {
      if (values.any(
        (value) => value.any((entry) => entry.groupId == groupId),
      )) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(
      values.expand((value) => value).map((entry) => entry.groupId),
      contains(groupId),
      reason: 'Chats must update without restarting or another group mutation',
    );
  });

  /// The liveness probe must not land on the send path.
  ///
  /// `_reachableNow` crosses into the node and materialises the whole peer
  /// table — `peers()` was moved off the UI isolate for exactly that reason —
  /// and `broadcastDelta` runs on every group message. A probe whose cost
  /// lands on a hot path is a defect this project has already paid for once,
  /// so the lookup is cached for a few seconds and skipped outright when it
  /// cannot change the answer.
  test('the liveness probe is not paid on every send', () async {
    var probes = 0;
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    var wall = 1000;
    final service = GroupService(
      storage,
      _FakeSigner(owner),
      activePeers: () async {
        probes++;
        return {bob};
      },
      // Without a sender `broadcastDelta` returns before it ever selects, so
      // the probe would look free for the wrong reason.
      send: (peer, groupId, json) async {},
    )..debugWallClockMs = () => wall;
    addTearDown(service.dispose);

    final gid = await service.createGroup('Chatty');
    // MORE members than the overlay degree, or the selection takes them all
    // and the probe is skipped for a different reason than the cache.
    for (var i = 0; i < GroupService.kGroupSyncNeighbors + 2; i++) {
      await service.addControlOp(
        gid,
        ControlOp.addMember,
        target: NodeId.fromHex(
          i.toRadixString(16).padLeft(2, '0') * 32,
        ),
        role: GroupRole.member,
      );
    }
    probes = 0;

    for (var i = 0; i < 8; i++) {
      await service.postMessage(gid, 'burst $i');
    }

    expect(
      probes,
      lessThanOrEqualTo(1),
      reason:
          'a burst of sends inside the cache window must ask the node ONCE; '
          'asking per message puts a native round trip and a full peer-table '
          'copy on the send path (saw $probes)',
    );

    // And it does refresh once the window passes — a cache that never expires
    // would pin a peer table from boot.
    wall += 10000;
    await service.postMessage(gid, 'after the window');
    expect(
      probes,
      greaterThanOrEqualTo(2),
      reason: 'the view must refresh after its window, or it is frozen',
    );
  });

  /// How much of a chat's membership this device can actually see.
  ///
  /// The sparse overlay prefers members it believes are up and can only choose
  /// among the ones it can SEE — the node's live peer table. Whether a liveness
  /// hint on the wire would buy anything is therefore a RATIO, and it was
  /// measured for spaces only: the observability pass skipped every non-space
  /// outright. Measuring before building is how this project settled its
  /// idle-traffic work.
  test('a chat is counted for coverage, and its live share with it', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(
      storage,
      _FakeSigner(owner),
      activePeers: () async => {bob},
    );
    addTearDown(service.dispose);

    final gid = await service.createGroup('Family');
    for (final peer in [bob, carol]) {
      expect(
        await service.addControlOp(
          gid,
          ControlOp.addMember,
          target: peer,
          role: GroupRole.member,
        ),
        isTrue,
      );
    }

    final snapshot = await service.spaceObservabilitySnapshot();
    final r = snapshot.replication;
    expect(r.chatGroups, 1);
    expect(
      r.chatGroupMembers,
      2,
      reason: 'the owner is not a member it could sync WITH',
    );
    expect(
      r.chatGroupMembersActive,
      1,
      reason:
          'one of the two is in the live peer table, and that ratio is what '
          'decides whether a liveness hint on the wire buys anything',
    );

    // And it SURVIVES serialization, because the only reader is an HTTP
    // endpoint that serves `toJson()` — a number that exists on the object and
    // not in the payload is a measurement nobody can take. (The API test for
    // that route fakes this map wholesale, so it could never catch this.)
    final wire = snapshot.toJson()['replication'] as Map<String, Object?>;
    expect(wire['chatGroups'], 1);
    expect(wire['chatGroupMembers'], 2);
    expect(wire['chatGroupMembersActive'], 1);
    // Counts only: a coverage metric must not become a membership listing.
    expect(
      RegExp(r'[0-9a-f]{64}').hasMatch(jsonEncode(wire)),
      isFalse,
      reason: 'the replication payload must carry no node ids',
    );
  });

  test('an unreadable peer table is not the same as nobody being up', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _FakeSigner(owner));
    addTearDown(service.dispose);

    final gid = await service.createGroup('Family');
    await service.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );

    final snapshot = await service.spaceObservabilitySnapshot();
    final r = snapshot.replication;
    expect(r.chatGroupMembers, 1);
    expect(
      (snapshot.toJson()['replication'] as Map)['chatGroupMembersActive'],
      -1,
      reason:
          'the map is Object-valued, so "unknown" crosses as -1 — a reader '
          'deserves to tell it from "none of them are up"',
    );
    expect(
      r.chatGroupMembersActive,
      isNull,
      reason:
          'with no reader wired the answer is unknown, and reporting 0 would '
          'read as a total outage',
    );
  });

  test('a chat with nobody else in it is not counted', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(
      storage,
      _FakeSigner(owner),
      activePeers: () async => const <NodeId>{},
    );
    addTearDown(service.dispose);
    await service.createGroup('Just me');

    final r = (await service.spaceObservabilitySnapshot()).replication;
    expect(
      r.chatGroups,
      0,
      reason: 'a group with no other member says nothing about coverage',
    );
  });

  test(
    'group chats and Spaces have disjoint creation and list semantics',
    () async {
      final (service, _) = await setup();
      final before = service.changes.value;
      final groupId = await service.createGroup('Family chat');
      final spaceId = await service.createSpace('Builders');

      final group = (await service.load(groupId))!;
      final space = (await service.load(spaceId))!;
      expect(group.manifest.isSpace, isFalse);
      expect(await service.channelsOf(groupId), isEmpty);
      expect(space.manifest.isSpace, isTrue);
      expect(await service.channelsOf(spaceId), hasLength(1));

      expect((await service.listGroups()).single.groupId, groupId);
      expect((await service.listSpaces()).single.groupId, spaceId);
      expect(
        service.changes.value,
        before + 2,
        reason: 'Group and Space creation each invalidate their own list',
      );
    },
  );

  test(
    'Space service emits bounded privacy-safe lifecycle and content metrics',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      var now = 1700000000000;
      final service = GroupService(
        storage,
        _FakeSigner(owner),
        send: (_, _, _) async {},
        activePeers: () async => {bob},
        observability: SpaceObservability(nowMs: () => now++),
      );
      addTearDown(service.dispose);

      final spaceId = await service.createSpace(
        'Private telemetry must not retain this name',
        visibility: SpaceVisibility.public,
      );
      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final post = await service.publishSpacePost(
        spaceId,
        body: 'secret publication body',
        broadcast: false,
      );
      expect(post, isNotNull);
      expect(await service.spaceFeed(), hasLength(1));
      expect(await service.archiveSpace(spaceId), isTrue);
      expect(await service.restoreSpace(spaceId), isTrue);

      final snapshot = await service.spaceObservabilitySnapshot();
      expect(snapshot.counters['spaceCreated.succeeded'], 1);
      expect(snapshot.counters['postPublished.succeeded'], 1);
      expect(snapshot.counters['feedRead.succeeded'], 1);
      expect(snapshot.counters['spaceArchived.succeeded'], 1);
      expect(snapshot.counters['spaceRestored.succeeded'], 1);
      expect(snapshot.amounts['postPublished'], 1);
      expect(snapshot.amounts['feedRead'], 1);
      expect(snapshot.durationsMs['p2pSnapshotDelivery']?['samples'], 1);
      expect(snapshot.replication.liveSourceAvailable, isTrue);
      expect(snapshot.replication.spaces, 1);
      expect(snapshot.replication.eligibleRemoteSpreaders, 1);
      expect(snapshot.replication.availableRemoteSpreaders, 1);
      expect(snapshot.replication.targetReplicationFactorTotal, 2);
      expect(snapshot.replication.estimatedLiveReplicationFactorTotal, 2);
      expect(snapshot.replication.estimatedLiveReplicationFactorMin, 2);
      expect(snapshot.replication.estimatedLiveReplicationFactorMax, 2);
      expect(snapshot.replication.estimatedUnderReplicatedSpaces, 0);
      expect(snapshot.replication.confirmedRemoteHolderSlots, 0);
      expect(snapshot.replication.availableConfirmedRemoteHolderSlots, 0);
      expect(snapshot.replication.confirmedReplicationFactorTotal, 1);
      expect(snapshot.replication.confirmedReplicationFactorMin, 1);
      expect(snapshot.replication.confirmedReplicationFactorMax, 1);
      expect(snapshot.replication.confirmedUnderReplicatedSpaces, 1);
      final encoded = jsonEncode(snapshot.toJson());
      expect(encoded, isNot(contains(spaceId.hex)));
      expect(encoded, isNot(contains(bob.hex)));
      expect(encoded, isNot(contains('Private telemetry')));
      expect(encoded, isNot(contains('secret publication body')));
    },
  );

  test(
    'index repair drops only entries nothing backs, and only on apply',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      addTearDown(service.dispose);
      final live = await service.createGroup('Real group');
      const ghost =
          '9e6f04b1884f5311805a8b15ade5670237c6886ccf1e86a9088f656a666bd10a';
      // Put a ghost in the index the way the race did: a list that names an id
      // nothing backs.
      await storage.storeFile(
        'groups.index',
        Uint8List.fromList(utf8.encode(jsonEncode([live.hex, ghost]))),
        name: 'groups-index',
      );

      final dry = await service.repairIndexGhosts();
      expect(dry, [ghost]);
      expect(
        (await service.indexedGroups()).map((row) => row.hex),
        containsAll([live.hex, ghost]),
        reason: 'a dry run must change nothing',
      );

      final applied = await service.repairIndexGhosts(apply: true);
      expect(applied, [ghost]);
      final after = (await service.indexedGroups()).map((row) => row.hex);
      expect(after, contains(live.hex), reason: 'the real group must survive');
      expect(after, isNot(contains(ghost)));
    },
  );

  test(
    'a read racing an index write does not fall back to the legacy copy',
    () async {
      // The legacy settings copy is only inert while the file read cannot miss.
      // It can: a read landing inside the write sees "incomplete" as "absent",
      // falls back to the stale list, and the next write persists it — which is
      // how an id of a purged group comes back and, having no bundle and no
      // tombstone, silently disables shared-content GC.
      final storage = _HalfWrittenBundleStorage();
      await storage.open(password: 'pw', createIfMissing: true);
      const ghost =
          '9e6f04b1884f5311805a8b15ade5670237c6886ccf1e86a9088f656a666bd10a';
      final service = GroupService(storage, _FakeSigner(owner));
      addTearDown(service.dispose);
      // The index FILE must already exist: falling back on a store that never
      // had one is the legitimate migration path, not this race.
      await service.createGroup('First');
      // A legacy value that outlived its clear — the code calls it inert.
      await storage.putSetting('groups.index', '["$ghost"]');

      storage.gate = Completer<void>();
      storage.gateIndexOnly = true;
      final creating = service.createGroup('Racing the index');
      await Future<void>.delayed(Duration.zero);
      final reading = service.indexedGroups();
      await Future<void>.delayed(Duration.zero);
      storage.gate!.complete();
      storage.gate = null;
      await creating;

      final rows = await reading;
      expect(
        rows.map((row) => row.hex),
        isNot(contains(ghost)),
        reason: 'the stale legacy list must never answer for the live index',
      );
    },
  );

  test('a read that races a bundle save does not see a missing group', () async {
    // The store cannot tell a half-written blob from an absent one, and every
    // caller reads a failed load as "no such group". Downstream that made
    // deviceSyncRecords answer "no records" and cloud reconcile apply nothing.
    final storage = _HalfWrittenBundleStorage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _FakeSigner(owner));
    addTearDown(service.dispose);
    final gid = await service.createGroup('Racing bundle');

    storage.gate = Completer<void>();
    final saving = service.postMessage(
      gid,
      'while the blob is replaced',
      broadcast: false,
    );
    // Let the save reach the parked write before reading.
    await Future<void>.delayed(Duration.zero);
    final loading = service.load(gid);
    await Future<void>.delayed(Duration.zero);
    storage.gate!.complete();
    storage.gate = null;

    expect(await saving, isTrue);
    final bundle = await loading;
    expect(
      bundle,
      isNotNull,
      reason: 'a group being written is still a group that exists',
    );
    expect(
      bundle!.messages.map((message) => message.body),
      contains('while the blob is replaced'),
      reason: 'and the read must land after the write, not before it',
    );
  });

  test('a failed bundle write does not make concurrent reads throw', () async {
    // The reader waits for the writer; it must not inherit the writer's
    // failure. load() answers null for "cannot read it", never by throwing.
    final storage = _HalfWrittenBundleStorage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _FakeSigner(owner));
    addTearDown(service.dispose);
    final gid = await service.createGroup('Failing write');

    storage.gate = Completer<void>();
    storage.failOnRelease = true;
    final saving = service.postMessage(gid, 'doomed', broadcast: false);
    await Future<void>.delayed(Duration.zero);
    final loading = service.load(gid);
    await Future<void>.delayed(Duration.zero);
    storage.gate!.complete();
    storage.gate = null;
    await saving.then<void>((_) {}, onError: (_) {});

    final bundle = await loading;
    expect(
      bundle,
      isNotNull,
      reason: 'the write failed, so the previous bundle is still there',
    );
  });

  test(
    'waiting out a bundle write is bounded, not indefinite',
    () async {
      // A read must never hang behind a slow write: on timeout it reads anyway
      // and lands back on the old answer for that one call.
      final storage = _HalfWrittenBundleStorage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner))
        ..bundleWriteWait = const Duration(milliseconds: 30);
      addTearDown(service.dispose);
      final gid = await service.createGroup('Slow write');

      storage.gate = Completer<void>();
      final saving = service.postMessage(gid, 'slow', broadcast: false);
      await Future<void>.delayed(Duration.zero);
      // The write never finishes within the bound; the read must still return.
      await expectLater(service.load(gid), completes);
      storage.gate!.complete();
      storage.gate = null;
      await saving;
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test(
    'Space replication snapshot reads each durable bundle once per call',
    () async {
      final storage = _CountingGroupReadStorage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(
        storage,
        _FakeSigner(owner),
        activePeers: () async => const <NodeId>{},
      );
      addTearDown(service.dispose);

      await service.createSpace(
        'Single coherent observability read',
        visibility: SpaceVisibility.public,
      );
      // A CHAT too. The pass folds a control log for these as well now, to
      // count how much of each chat this device can see, and the cost of a
      // diagnostic is exactly the kind of thing this project has been bitten
      // by before — a probe that rescanned the journal on every call. It must
      // still be one read per group, not one per group per question asked.
      final chatId = await service.createGroup('Coherent chat read');
      await service.addControlOp(
        chatId,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      storage.groupBundleReads = 0;

      final firstPass = await service.spaceObservabilitySnapshot();
      expect(firstPass.replication.spaces, 1);
      expect(
        firstPass.replication.chatGroups,
        1,
        reason: 'the chat must be in this pass, or the read count below is '
            'about a pass that skipped it',
      );
      expect(
        storage.groupBundleReads,
        3,
        reason:
            'frontier and message materialization must reuse the validated '
            'bundle loaded by the snapshot — ONE read per durable group, and '
            'there are three: the space, the chat, and the device group that '
            'admitting a member brings into the index. The chat-coverage fold '
            'must reuse the bundle the pass already loaded rather than '
            'fetching its own; measured with the fold bypassed, the count is '
            'the same 3',
      );

      storage.groupBundleReads = 0;
      final secondPass = await service.spaceObservabilitySnapshot();
      expect(secondPass.replication.spaces, 1);
      expect(
        storage.groupBundleReads,
        secondPass.replication.spaces + secondPass.replication.chatGroups,
        reason:
            'a later snapshot must still read every group it reports on, '
            'freshly — stated against what the pass counted rather than a '
            'fixed number, because the device group materialises once and is '
            'not fetched again',
      );
    },
  );

  test(
    'Space receipts are source-bound, loop-free and confirm only a caught-up '
    'authorized sync frontier',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final ownerOutbound = <(NodeId, String)>[];
      final bobOutbound = <(NodeId, String)>[];
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (peer, _, json) async => ownerOutbound.add((peer, json)),
        activePeers: () async => {bob, carol},
      );
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        send: (peer, _, json) async => bobOutbound.add((peer, json)),
      );
      addTearDown(ownerSvc.dispose);
      addTearDown(bobSvc.dispose);

      final spaceId = await ownerSvc.createSpace(
        'Receipt scope',
        visibility: SpaceVisibility.public,
      );
      for (final peer in [bob, carol]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: peer,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );

      ownerOutbound.clear();
      expect(await ownerSvc.broadcast(spaceId), 2);
      final bobWire = ownerOutbound.singleWhere((entry) => entry.$1 == bob).$2;
      final receipt = (jsonDecode(bobWire) as Map)['rcpt'] as String;
      expect(receipt, hasLength(64));
      final currentVector = (await bobSvc.buildGroupSyncRequest(spaceId))!;
      final sendsBeforeForgeries = ownerOutbound.length;

      final unknown = Map<String, dynamic>.of(currentVector)
        ..['rack'] = List.filled(64, '0').join();
      expect(await ownerSvc.handleGroupSyncRequest(bob, unknown), isFalse);
      final wrongSource = Map<String, dynamic>.of(currentVector)
        ..['rack'] = receipt;
      expect(
        await ownerSvc.handleGroupSyncRequest(carol, wrongSource),
        isFalse,
      );
      expect(
        ownerOutbound,
        hasLength(sendsBeforeForgeries),
        reason: 'a caught-up sync vector and rejected receipt emit no reply',
      );
      var replication =
          (await ownerSvc.spaceObservabilitySnapshot()).replication;
      expect(replication.confirmedRemoteHolderSlots, 0);

      bobOutbound.clear();
      expect(await bobSvc.ingestGroupEntry(owner, bobWire), isTrue);
      final acknowledgement = bobOutbound.singleWhere((entry) {
        final wire = jsonDecode(entry.$2);
        return entry.$1 == owner &&
            wire is Map &&
            wire['sreq'] == 1 &&
            wire['rack'] == receipt;
      }).$2;
      final ownerSendsBeforeAck = ownerOutbound.length;
      expect(await ownerSvc.ingestGroupEntry(bob, acknowledgement), isFalse);
      expect(
        ownerOutbound,
        hasLength(ownerSendsBeforeAck),
        reason: 'a caught-up receipt request is terminal, not ACKed again',
      );

      replication = (await ownerSvc.spaceObservabilitySnapshot()).replication;
      expect(replication.confirmedRemoteHolderSlots, 1);
      expect(replication.availableConfirmedRemoteHolderSlots, 1);
      expect(replication.confirmedReplicationFactorTotal, 2);
      expect(replication.confirmedUnderReplicatedSpaces, 1);

      expect(
        await ownerSvc.ingestGroupEntry(bob, acknowledgement),
        isFalse,
        reason: 'a receipt is single-use even when replayed by its source',
      );
      expect(
        await ownerSvc.publishSpacePost(
          spaceId,
          body: 'temporarily missing',
          broadcast: false,
        ),
        isNotNull,
      );
      replication = (await ownerSvc.spaceObservabilitySnapshot()).replication;
      expect(
        replication.confirmedRemoteHolderSlots,
        0,
        reason: 'any local frontier change invalidates the previous proof',
      );

      ownerOutbound.clear();
      bobOutbound.clear();
      final behindVector = (await bobSvc.buildGroupSyncRequest(spaceId))!;
      expect(await ownerSvc.handleGroupSyncRequest(bob, behindVector), isTrue);
      final repair = ownerOutbound.singleWhere((entry) => entry.$1 == bob).$2;
      final repairWire = jsonDecode(repair) as Map;
      final missingObjects = ['c', 'g', 'r', 'p', 'ke', 'cke'].fold<int>(
        0,
        (count, key) =>
            count +
            (repairWire[key] is List ? (repairWire[key] as List).length : 0),
      );
      expect(missingObjects, greaterThan(0));
      expect(repairWire['rcpt'], isA<String>());

      final repairReceipt = repairWire['rcpt'];
      final noProgressAck = Map<String, dynamic>.of(behindVector)
        ..['rack'] = repairReceipt;
      final beforeNoProgressAck = ownerOutbound.length;
      expect(
        await ownerSvc.handleGroupSyncRequest(bob, noProgressAck),
        isFalse,
        reason:
            'ACKing a repair without advancing the frontier must stop the loop',
      );
      expect(
        ownerOutbound,
        hasLength(beforeNoProgressAck),
        reason: 'the identical missing-object set must not be sent again',
      );
      expect(
        await ownerSvc.handleGroupSyncRequest(bob, noProgressAck),
        isFalse,
        reason: 'a replayed durable ACK must not restart the repair loop',
      );
      expect(ownerOutbound, hasLength(beforeNoProgressAck));

      expect(
        await ownerSvc.handleGroupSyncRequest(bob, behindVector),
        isTrue,
        reason: 'a fresh independent sync nudge may retry after a stalled ACK',
      );
      final retryRepair = ownerOutbound.last.$2;
      final retryWire = jsonDecode(retryRepair) as Map;
      expect(retryWire['rcpt'], isA<String>());
      expect(retryWire['rcpt'], isNot(repairReceipt));

      expect(await bobSvc.ingestGroupEntry(owner, retryRepair), isTrue);
      final retryReceipt = retryWire['rcpt'];
      final repairAck = bobOutbound.singleWhere((entry) {
        final wire = jsonDecode(entry.$2);
        return entry.$1 == owner && wire is Map && wire['rack'] == retryReceipt;
      }).$2;
      final backfillSends = ownerOutbound.length;
      expect(await ownerSvc.ingestGroupEntry(bob, repairAck), isFalse);
      expect(
        ownerOutbound,
        hasLength(backfillSends),
        reason: 'the caught-up repair receipt also terminates the exchange',
      );

      final observations = await ownerSvc.spaceObservabilitySnapshot();
      expect(
        observations.amounts['p2pMissingObjects'],
        missingObjects * 4,
        reason: 'all four behind vectors report the same missing-object set',
      );
      expect(observations.counters['p2pMissingObjects.succeeded'], 4);
      expect(observations.counters['p2pReceipt.succeeded'], 3);
      expect(observations.counters['p2pReceipt.rejected'], 3);
      expect(observations.durationsMs['p2pReceipt']?['samples'], 3);
      expect(observations.replication.confirmedRemoteHolderSlots, 1);
      expect(
        jsonEncode(observations.toJson()),
        isNot(contains(receipt)),
        reason: 'receipt challenges never enter the exported diagnostics',
      );
    },
  );

  test('content receipts are source-bound, replay-safe and expose distinct '
      'per-blob deficits without ids', () async {
    final ownerStorage = FakeHvContainer().storage();
    final bobStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'pw', createIfMissing: true);
    await bobStorage.open(password: 'pw', createIfMissing: true);
    late GroupService ownerSvc;
    final receiptWires = <(NodeId, String)>[];
    final bobSvc = GroupService(
      bobStorage,
      _FakeSigner(bob),
      sendContentRequest: (holder, requestJson) async {
        expect(holder, owner);
        expect(await ownerSvc.handleContentRequest(requestJson), isTrue);
      },
      sendContentReceipt: (holder, receiptJson) async {
        receiptWires.add((holder, receiptJson));
      },
      activePeers: () async => {owner},
    );
    ownerSvc = GroupService(
      ownerStorage,
      _FakeSigner(owner),
      grantContentServe: (_, _) {},
      activePeers: () async => {bob},
    );
    addTearDown(ownerSvc.dispose);
    addTearDown(bobSvc.dispose);

    final spaceId = await ownerSvc.createSpace(
      'Blob receipt scope must stay private',
      visibility: SpaceVisibility.public,
    );
    expect(
      await ownerSvc.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      ),
      isTrue,
    );
    final cids = [
      sha256.convert(const [1]).toString(),
      sha256.convert(const [2]).toString(),
    ];
    for (var i = 0; i < cids.length; i++) {
      expect(
        await ownerSvc.publishSpacePost(
          spaceId,
          body: 'blob ${i + 1}',
          media: [MediaObject(contentId: cids[i], kind: 'image', size: 1)],
          broadcast: false,
        ),
        isNotNull,
      );
      await ownerStorage.storeFile(
        cids[i],
        Uint8List.fromList([i + 1]),
        name: 'owner-$i',
      );
    }
    expect(
      await bobSvc.ingestSnapshot(
        ownerSvc.snapshotJson((await ownerSvc.load(spaceId))!, recipient: bob),
      ),
      isTrue,
    );

    var replication = (await ownerSvc.spaceObservabilitySnapshot()).replication;
    expect(replication.referencedContentBlobs, 2);
    expect(replication.locallyHeldContentBlobs, 2);
    expect(replication.targetContentHolderSlots, 4);
    expect(replication.confirmedRemoteContentHolderSlots, 0);
    expect(replication.confirmedContentHolderSlots, 2);
    expect(replication.confirmedContentDeficitSlots, 2);
    expect(replication.confirmedUnderReplicatedContentBlobs, 2);

    Future<String> completeFromOwner(String cid, int byte) async {
      expect(await bobSvc.requestGroupContent(spaceId, cid, owner), isTrue);
      if (!await bobStorage.hasFile(cid)) {
        await bobStorage.storeFile(
          cid,
          Uint8List.fromList([byte]),
          name: 'bob',
        );
      }
      final before = receiptWires.length;
      await bobSvc.handleVerifiedContentSources(cid, {owner});
      for (var i = 0; i < 20 && receiptWires.length == before; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(receiptWires, hasLength(before + 1));
      expect(receiptWires.last.$1, owner);
      return receiptWires.last.$2;
    }

    final firstWire = await completeFromOwner(cids.first, 1);
    final firstJson = jsonDecode(firstWire) as Map<String, dynamic>;
    expect(
      await ownerSvc.handleContentReceipt(stranger, firstWire),
      isFalse,
      reason: 'authenticated transport source must equal requester',
    );
    final forgedNonce = Map<String, dynamic>.of(firstJson)..['n'] = 'f' * 24;
    expect(
      await ownerSvc.handleContentReceipt(bob, jsonEncode(forgedNonce)),
      isFalse,
    );
    expect(await ownerSvc.handleContentReceipt(bob, firstWire), isTrue);
    expect(
      await ownerSvc.handleContentReceipt(bob, firstWire),
      isFalse,
      reason: 'the matching request challenge is single-use',
    );

    replication = (await ownerSvc.spaceObservabilitySnapshot()).replication;
    expect(replication.confirmedRemoteContentHolderSlots, 1);
    expect(replication.confirmedContentHolderSlots, 3);
    expect(replication.confirmedContentDeficitSlots, 1);
    expect(replication.confirmedUnderReplicatedContentBlobs, 1);

    final secondWire = await completeFromOwner(cids.last, 2);
    expect(await ownerSvc.handleContentReceipt(bob, secondWire), isTrue);
    final completedObservations = await ownerSvc.spaceObservabilitySnapshot();
    replication = completedObservations.replication;
    expect(replication.confirmedRemoteContentHolderSlots, 2);
    expect(replication.availableConfirmedRemoteContentHolderSlots, 2);
    expect(replication.confirmedContentHolderSlots, 4);
    expect(replication.confirmedContentDeficitSlots, 0);
    expect(replication.confirmedUnderReplicatedContentBlobs, 0);
    expect(completedObservations.counters['p2pContentReceipt.succeeded'], 2);
    expect(completedObservations.counters['p2pContentReceipt.rejected'], 3);
    final encoded = jsonEncode(completedObservations.toJson());
    expect(encoded, isNot(contains(spaceId.hex)));
    expect(encoded, isNot(contains(owner.hex)));
    expect(encoded, isNot(contains(bob.hex)));
    for (final cid in cids) {
      expect(encoded, isNot(contains(cid)));
    }
    expect(encoded, isNot(contains('Blob receipt scope')));
    expect(encoded, isNot(contains('blob 1')));

    final revokedWire = await completeFromOwner(cids.first, 1);
    expect(
      await ownerSvc.addControlOp(spaceId, ControlOp.removeMember, target: bob),
      isTrue,
    );
    expect(
      await ownerSvc.handleContentReceipt(bob, revokedWire),
      isFalse,
      reason:
          'a request accepted before removal cannot confirm a holder after '
          'the current ACL changes',
    );
    final revokedObservations = await ownerSvc.spaceObservabilitySnapshot();
    expect(revokedObservations.counters['p2pContentReceipt.rejected'], 4);
    expect(
      revokedObservations.replication.confirmedRemoteContentHolderSlots,
      0,
      reason: 'ineligible peers are excluded before proof TTL expiry',
    );
  });

  test(
    'Space rules are signed, versioned and require explicit re-acceptance',
    () async {
      final (service, member) = await setup();
      final groupId = await service.createGroup('Family chat');
      final spaceId = await service.createSpace('Builders');

      expect(
        await service.publishSpaceRules(
          groupId,
          fullText: 'Rules must never attach to a group chat.',
          summary: 'Wrong entity',
        ),
        isFalse,
      );
      expect(
        await service.publishSpaceRules(
          spaceId,
          fullText: 'Be kind. Verify information before redistributing it.',
          summary: 'Be kind and verify.',
        ),
        isTrue,
      );
      var state = (await service.stateOf(spaceId))!;
      expect(state.currentRules?.version, 1);
      expect(state.rulesHistory, hasLength(1));
      expect(state.requiresRulesAcceptance(owner), isTrue);
      expect(await service.acceptSpaceRules(spaceId), isTrue);
      state = (await service.stateOf(spaceId))!;
      expect(state.requiresRulesAcceptance(owner), isFalse);
      expect(state.rulesAcceptanceOf(owner)?.rulesVersion, 1);

      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.admin,
        ),
        isTrue,
      );
      expect(
        await member(bob).publishSpaceRules(
          spaceId,
          fullText: 'An admin must not replace owner-approved rules.',
          summary: 'Forged',
        ),
        isFalse,
      );

      expect(
        await service.publishSpaceRules(
          spaceId,
          fullText: 'Be kind. Verify sources. Do not expose private data.',
          summary: 'Privacy requirement added.',
        ),
        isTrue,
      );
      state = (await service.stateOf(spaceId))!;
      expect(state.currentRules?.version, 2);
      expect(state.currentRules?.previousVersion, 1);
      expect(state.rulesHistory, hasLength(2));
      expect(state.requiresRulesAcceptance(owner), isTrue);
      expect(state.requiresRulesAcceptance(bob), isTrue);
      expect(
        SpaceRulesVersion.fromJson(state.currentRules!.toJson())?.fullText,
        state.currentRules!.fullText,
      );
    },
  );

  test(
    'an own-device seed keeps rows sealed under a rotated-away epoch',
    () async {
      // Measured on the stand: a linked device received 8 of 9 rows, the
      // missing one exactly the pre-revocation head of the history. The
      // seed's filter asked the envelope question — right for a NEW MEMBER
      // (forward secrecy), wrong for my own device, which reads with the
      // keys the very same snapshot hands over ('kk').
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      addTearDown(ownerSvc.dispose);
      final gid = await ownerSvc.createGroup('Rotated away');
      expect(
        await ownerSvc.postMessage(gid, 'pre-rotation', broadcast: false),
        isTrue,
      );
      // The rotation: membership change bumps the epoch past the row's.
      expect(
        await ownerSvc.addControlOp(
          gid,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final b = (await ownerSvc.load(gid))!;
      final row = b.messages.single;
      expect(row.isEncrypted, isTrue);
      final oldEpoch = row.membershipEpoch!;
      expect(oldEpoch, lessThan((await ownerSvc.stateOf(gid))!.epoch));
      expect(b.localEpochKeys.containsKey(oldEpoch), isTrue);
      // Forward secrecy at its endpoint: no envelope of the old epoch
      // survives, only the local key does.
      final rotated = b.copyWith(
        epochEnvelopes: [
          for (final e in b.epochEnvelopes)
            if (e.epoch != oldEpoch) e,
        ],
      );
      final seeded =
          jsonDecode(
                ownerSvc.snapshotJson(
                  rotated,
                  recipient: carol,
                  ownDevice: true,
                ),
              )
              as Map;
      expect(
        seeded['g'] as List,
        hasLength(1),
        reason: 'my own device reads with the keys this snapshot hands over',
      );
      final stranger =
          jsonDecode(ownerSvc.snapshotJson(rotated, recipient: bob)) as Map;
      expect(
        (stranger['g'] as List?) ?? const [],
        isEmpty,
        reason: 'forward secrecy for a NEW MEMBER stands untouched',
      );
    },
  );

  test(
    'epoch E2EE persists and wires only ciphertext for messages + reactions',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final gid = await ownerSvc.createGroup('Encrypted');
      expect((await ownerSvc.stateOf(gid))!.epoch, 1);
      expect(
        await ownerSvc.addControlOp(
          gid,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final afterJoin = (await ownerSvc.stateOf(gid))!;
      expect(afterJoin.epoch, 2);
      expect(afterJoin.epochDescriptor?.recipientCount, 2);

      const attachment = GroupAttachment(
        kind: 'image',
        dataB64: 'c2VjcmV0LWltYWdl',
        w: 32,
        h: 24,
        cid: 'private-content-id',
      );
      const customEmoji = InlineCustomEmoji(offset: 6, dataB64: 'AQID');
      expect(
        await ownerSvc.postMessage(
          gid,
          'owner ☺ secret',
          attachment: attachment,
          customEmoji: const [customEmoji],
          broadcast: false,
        ),
        isTrue,
      );
      final ownerBundle = (await ownerSvc.load(gid))!;
      expect(ownerBundle.messages.single.isEncrypted, isTrue);
      expect(ownerBundle.messages.single.body, isEmpty);
      final bobWire = ownerSvc.snapshotJson(ownerBundle, recipient: bob);
      expect(bobWire, isNot(contains('owner ☺ secret')));
      expect(bobWire, isNot(contains('AQID')));
      expect(bobWire, isNot(contains('private-content-id')));
      expect((jsonDecode(bobWire) as Map)['kk'], isNull);
      expect(((jsonDecode(bobWire) as Map)['ke'] as List).length, 1);

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      expect(await bobSvc.ingestSnapshot(bobWire), isTrue);
      final bobMessages = await bobSvc.messagesOf(gid);
      expect(bobMessages.single.body, 'owner ☺ secret');
      expect(bobMessages.single.customEmoji.single.offset, 6);
      expect(bobMessages.single.customEmoji.single.dataB64, 'AQID');
      expect(bobMessages.single.attachment?.cid, 'private-content-id');
      final persisted = utf8.decode(
        (await bobStorage.loadFile('group:${gid.hex}'))!,
      );
      expect(persisted, isNot(contains('owner ☺ secret')));
      expect(persisted, isNot(contains('AQID')));
      expect(persisted, isNot(contains('private-content-id')));

      expect(
        await bobSvc.postMessage(gid, 'bob secret', broadcast: false),
        isTrue,
      );
      expect(
        await bobSvc.react(gid, bobMessages.single.ref, '🔥', broadcast: false),
        isTrue,
      );
      final bobBundle = (await bobSvc.load(gid))!;
      expect(bobBundle.messages.last.isEncrypted, isTrue);
      expect(bobBundle.reactions.single.isEncrypted, isTrue);
      final ownerWire = bobSvc.snapshotJson(bobBundle, recipient: owner);
      expect(ownerWire, isNot(contains('bob secret')));
      expect(ownerWire, isNot(contains('🔥')));
      final concurrentLocal = ownerSvc.postMessage(
        gid,
        'concurrent owner secret',
        broadcast: false,
      );
      final concurrentIngest = ownerSvc.ingestSnapshot(ownerWire);
      expect(await concurrentLocal, isTrue);
      expect(await concurrentIngest, isTrue);
      expect(
        (await ownerSvc.messagesOf(gid)).map((message) => message.body),
        containsAll([
          'owner ☺ secret',
          'bob secret',
          'concurrent owner secret',
        ]),
      );
      expect((await ownerSvc.reactionsOf(gid))[bobMessages.single.ref]?['🔥'], [
        bob,
      ]);
    },
  );

  test(
    'new members get only the post-join epoch and removed members get no new key',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final gid = await ownerSvc.createGroup('Forward secure');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await ownerSvc.postMessage(gid, 'before carol', broadcast: false);
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: carol,
        role: GroupRole.member,
      );
      await ownerSvc.postMessage(gid, 'after carol', broadcast: false);
      final bundle = (await ownerSvc.load(gid))!;
      expect((await ownerSvc.stateOf(gid))!.epoch, 3);
      expect(
        bundle.messages.last.prevHash,
        isEmpty,
        reason: 'a membership epoch is a new visibility/chain scope',
      );
      final carolWire = ownerSvc.snapshotJson(bundle, recipient: carol);
      expect(carolWire, isNot(contains('before carol')));

      final carolStorage = FakeHvContainer().storage();
      await carolStorage.open(password: 'pw', createIfMissing: true);
      final carolSvc = GroupService(
        carolStorage,
        _FakeSigner(carol),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      expect(await carolSvc.ingestSnapshot(carolWire), isTrue);
      expect((await carolSvc.messagesOf(gid)).map((message) => message.body), [
        'after carol',
      ]);

      expect(
        await ownerSvc.addControlOp(gid, ControlOp.removeMember, target: bob),
        isTrue,
      );
      expect((await ownerSvc.stateOf(gid))!.epoch, 4);
      await ownerSvc.postMessage(gid, 'after bob removal', broadcast: false);
      final removedWire = ownerSvc.snapshotJson(
        (await ownerSvc.load(gid))!,
        recipient: bob,
      );
      final removedJson = jsonDecode(removedWire) as Map;
      final bobEpochs = (removedJson['ke'] as List? ?? const [])
          .map((entry) => (entry as Map)['epoch'])
          .toList();
      expect(bobEpochs, isNot(contains(4)));
      expect(removedWire, isNot(contains('after bob removal')));
    },
  );

  test(
    'missing/wrong epoch envelope fails closed and clear v1 downgrade drops',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final gid = await ownerSvc.createGroup('No downgrade');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await ownerSvc.postMessage(gid, 'cipher only', broadcast: false);
      final validWire =
          jsonDecode(
                ownerSvc.snapshotJson(
                  (await ownerSvc.load(gid))!,
                  recipient: bob,
                ),
              )
              as Map<String, dynamic>;

      Future<GroupService> receiver(NodeId reportedIssuer) async {
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'pw', createIfMissing: true);
        return GroupService(
          storage,
          _FakeSigner(bob),
          epochService: GroupEpochService(
            LoopbackMailboxCrypto(senderForOpen: reportedIssuer),
          ),
        );
      }

      final withoutEnvelope = Map<String, dynamic>.from(validWire)
        ..remove('ke');
      final missing = await receiver(owner);
      expect(await missing.ingestSnapshot(jsonEncode(withoutEnvelope)), isTrue);
      expect(await missing.messagesOf(gid), isEmpty);
      expect(await missing.postMessage(gid, 'must not fall back'), isFalse);

      final wrongIssuer = await receiver(stranger);
      expect(await wrongIssuer.ingestSnapshot(jsonEncode(validWire)), isTrue);
      expect(await wrongIssuer.messagesOf(gid), isEmpty);
      expect(await wrongIssuer.postMessage(gid, 'must stay closed'), isFalse);

      final downgrade = _FakeSigner(bob).signMessage(
        GroupMessage(
          groupId: gid,
          author: bob,
          seq: 0,
          prevHash: '',
          body: 'clear downgrade',
          policyVersion: 0,
          createdAtMs: 9000,
          signature: Uint8List(0),
        ),
      );
      final injected = Map<String, dynamic>.from(validWire)
        ..['g'] = [downgrade.toJson()];
      final before = (await ownerSvc.load(gid))!.messages.length;
      expect(await ownerSvc.ingestSnapshot(jsonEncode(injected)), isTrue);
      expect((await ownerSvc.load(gid))!.messages.length, before);
    },
  );

  test(
    'owner boot migration upgrades a legacy group without re-sending clear history',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final legacy = GroupService(storage, _FakeSigner(owner));
      final gid = await legacy.createGroup('Legacy');
      await legacy.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await legacy.postMessage(gid, 'legacy local history', broadcast: false);
      expect((await legacy.stateOf(gid))!.epochDescriptor, isNull);

      final upgraded = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      await upgraded.nudgeGroupSyncAll();
      final state = (await upgraded.stateOf(gid))!;
      expect(state.epochDescriptor, isNotNull);
      expect(state.epoch, 1);
      await upgraded.postMessage(gid, 'encrypted future', broadcast: false);
      final bundle = (await upgraded.load(gid))!;
      expect(bundle.messages.first.isEncrypted, isFalse);
      expect(bundle.messages.last.isEncrypted, isTrue);
      final bobWire = upgraded.snapshotJson(bundle, recipient: bob);
      expect(bobWire, isNot(contains('legacy local history')));
      expect(bobWire, isNot(contains('encrypted future')));
      expect((jsonDecode(bobWire) as Map)['ke'], isNotNull);
    },
  );

  test(
    'member leave clears the key and owner automatically establishes a fresh epoch',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final gid = await ownerSvc.createGroup('Leave rekey');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      String? leaveDelta;
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        send: (peer, group, json) async {
          if (peer == owner && group == gid) leaveDelta = json;
        },
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson((await ownerSvc.load(gid))!, recipient: bob),
        ),
        isTrue,
      );
      expect(await bobSvc.leaveGroup(gid), isTrue);
      expect(leaveDelta, isNotNull);
      expect(await ownerSvc.ingestSnapshot(leaveDelta!), isTrue);
      GroupState? state;
      for (var attempt = 0; attempt < 20; attempt++) {
        state = await ownerSvc.stateOf(gid);
        if (state?.epochDescriptor != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(state?.isMember(bob), isFalse);
      expect(state?.epoch, 4);
      expect(state?.epochDescriptor?.recipientCount, 1);
      expect(
        await ownerSvc.postMessage(gid, 'after leave', broadcast: false),
        isTrue,
      );
      expect((await ownerSvc.load(gid))!.messages.single.isEncrypted, isTrue);
    },
  );

  test('owner adds a member; a plain member cannot add', () async {
    final (svc, member) = await setup();
    final gid = await svc.createGroup('G');
    expect(
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      ),
      isTrue,
    );
    expect((await svc.stateOf(gid))!.isMember(bob), isTrue);

    expect(
      await member(bob).addControlOp(
        gid,
        ControlOp.addMember,
        target: carol,
        role: GroupRole.member,
      ),
      isFalse,
    );
    expect((await svc.stateOf(gid))!.isMember(carol), isFalse);
  });

  test('post + read: a member posts, a stranger cannot', () async {
    final (svc, member) = await setup();
    final gid = await svc.createGroup('G');
    await svc.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );

    expect(await svc.postMessage(gid, 'hi from owner'), isTrue);
    expect(await member(bob).postMessage(gid, 'hi from bob'), isTrue);
    expect(await member(stranger).postMessage(gid, 'spam'), isFalse);

    final msgs = await svc.messagesOf(gid);
    expect(
      msgs.map((m) => m.body),
      containsAll(['hi from owner', 'hi from bob']),
    );
    expect(msgs.length, 2, reason: 'stranger message was never stored');
  });

  test('a muted member cannot post; unmute restores', () async {
    final (svc, member) = await setup();
    final gid = await svc.createGroup('G');
    await svc.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );
    await svc.addControlOp(gid, ControlOp.mute, target: bob);

    expect(await member(bob).postMessage(gid, 'muted'), isFalse);
    await svc.addControlOp(gid, ControlOp.unmute, target: bob);
    expect(await member(bob).postMessage(gid, 'back'), isTrue);
    expect((await svc.messagesOf(gid)).single.body, 'back');
  });

  test('snapshot -> ingest materializes the group on a fresh device', () async {
    // Owner's device.
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    final owned = GroupService(s1, _FakeSigner(owner));
    final gid = await owned.createGroup('Shared');
    await owned.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );
    await owned.postMessage(gid, 'welcome');
    final snap = owned.snapshotJson((await owned.load(gid))!);

    // Bob's fresh device: never saw the group before.
    final s2 = FakeHvContainer().storage();
    await s2.open(password: 'pw', createIfMissing: true);
    final bobDev = GroupService(s2, _FakeSigner(bob));
    expect(await bobDev.stateOf(gid), isNull);
    expect(await bobDev.ingestSnapshot(snap), isTrue);

    final st = (await bobDev.stateOf(gid))!;
    expect(st.roleOf(owner), GroupRole.owner);
    expect(st.isMember(bob), isTrue);
    expect((await bobDev.listGroups()).single.name, 'Shared');
    expect((await bobDev.messagesOf(gid)).single.body, 'welcome');
    // Re-ingest is idempotent (no dupes).
    await bobDev.ingestSnapshot(snap);
    final b = await bobDev.load(gid);
    expect(
      b!.control.where((entry) => entry.op == ControlOp.addMember).length,
      1,
    );
    expect(b.messages.length, 1);
  });

  test('new control entries are group-bound while legacy canonical bytes stay '
      'compatible', () {
    ControlEntry entry({NodeId? gid}) => ControlEntry(
      groupId: gid,
      author: owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 1,
      signature: Uint8List(0),
    );

    final legacy = String.fromCharCodes(entry().canonicalBytes());
    final bound = String.fromCharCodes(entry(gid: _id(8)).canonicalBytes());
    expect(legacy.contains('"gid"'), isFalse);
    expect(bound.contains('"gid":"${_id(8).hex}"'), isTrue);
    expect(ControlEntry.fromJson(entry(gid: _id(8)).toJson())!.groupId, _id(8));
  });

  test(
    'ingest rejects cross-group replay and invalid-signature seq poisoning',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(storage, _FakeSigner(owner));
      final groupA = await svc.createGroup('A');
      final groupB = await svc.createGroup('B');
      await svc.addControlOp(
        groupA,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      final aBundle = (await svc.load(groupA))!;
      final bBundle = (await svc.load(groupB))!;

      final replay = jsonEncode({
        'm': bBundle.manifest.toJson(),
        'c': [
          aBundle.control
              .singleWhere((entry) => entry.op == ControlOp.addMember)
              .toJson(),
        ],
        'g': const [],
        'r': const [],
      });
      expect(await svc.ingestSnapshot(replay), isTrue);
      expect((await svc.stateOf(groupB))!.isMember(bob), isFalse);
      expect(
        (await svc.load(
          groupB,
        ))!.control.where((entry) => entry.op == ControlOp.addMember),
        isEmpty,
      );

      GroupMessage message(Uint8List signature, String body) => GroupMessage(
        groupId: groupB,
        author: owner,
        seq: 0,
        prevHash: '',
        body: body,
        policyVersion: 0,
        createdAtMs: 2,
        signature: signature,
        authorPubKey: owner.bytes,
      );
      String snap(GroupMessage m) => jsonEncode({
        'm': bBundle.manifest.toJson(),
        'c': const [],
        'g': [m.toJson()],
        'r': const [],
      });

      await svc.ingestSnapshot(snap(message(Uint8List(0), 'poison')));
      expect((await svc.load(groupB))!.messages, isEmpty);
      await svc.ingestSnapshot(snap(message(Uint8List(64), 'valid')));
      expect((await svc.messagesOf(groupB)).single.body, 'valid');
    },
  );

  test(
    'cross-group messages/reactions and non-member reactions are ignored',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(storage, _FakeSigner(owner));
      final gid = await svc.createGroup('target');
      final other = _id(9);
      final bundle = (await svc.load(gid))!;
      final wrongMessage = GroupMessage(
        groupId: other,
        author: owner,
        seq: 0,
        prevHash: '',
        body: 'wrong-group',
        policyVersion: 0,
        createdAtMs: 1,
        signature: Uint8List(64),
        authorPubKey: owner.bytes,
      );
      GroupReaction reaction(NodeId group, NodeId author, int seq) =>
          GroupReaction(
            groupId: group,
            author: author,
            seq: seq,
            target: '${owner.hex}:0',
            emoji: '🔥',
            createdAtMs: 2,
            signature: Uint8List(64),
            authorPubKey: author.bytes,
          );
      final payload = jsonEncode({
        'm': bundle.manifest.toJson(),
        'c': const [],
        'g': [wrongMessage.toJson()],
        'r': [
          reaction(other, owner, 0).toJson(),
          reaction(gid, stranger, 0).toJson(),
        ],
      });
      expect(await svc.ingestSnapshot(payload), isTrue);
      final stored = (await svc.load(gid))!;
      expect(stored.messages, isEmpty);
      expect(stored.reactions, isEmpty);
      expect(await svc.reactionsOf(gid), isEmpty);
    },
  );

  test('a full-history push is a NEW transfer every time, so a peer that lost '
      'its store can be re-seeded from an unchanged bundle', () async {
    // The durable frame id of a snapshot derives from the snapshot's own
    // bytes. For a re-drive that is right. For re-seeding a device that was
    // wiped it is fatal: the bundle has not changed, so the frames carry
    // exactly the ids that device acknowledged in its previous life, the
    // delivery layer treats them as settled, and the snapshot never lands.
    // Measured live: 204 chunks arrived, reassembly never completed, and
    // appending one row to the source bundle fixed it on the first attempt.
    final sent = <String>[];
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(
      storage,
      _FakeSigner(owner),
      send: (peer, gid, json) async => sent.add(json),
    );
    final gid = await svc.createGroup('G');
    await svc.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );

    // addControlOp fans a delta out unawaited; let it land before measuring.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    sent.clear();
    await svc.broadcast(gid, reseed: true);
    await svc.broadcast(gid, reseed: true);

    expect(sent, hasLength(2));
    expect(
      sent[0],
      isNot(sent[1]),
      reason: 'identical bytes would reuse a settled durable frame id',
    );

    // And the ordinary push stays content-keyed. Minting a fresh identity on
    // EVERY broadcast had two live devices shipping the whole bundle to each
    // other without pause: each push arrived as new and provoked the next.
    sent.clear();
    await svc.broadcast(gid);
    await svc.broadcast(gid);
    expect(sent, hasLength(2));
    expect(
      sent[0],
      sent[1],
      reason: 'an unchanged bundle must collapse into no delivery at all',
    );
    // A delta must NOT pay this: re-driving the same delta is exactly the case
    // content keying exists to collapse.
    final bundle = (await svc.load(gid))!;
    expect(svc.snapshotJson(bundle), svc.snapshotJson(bundle));
  });

  test(
    'a member outside a restricted channel cannot enter its voice room',
    () async {
      // Found by break-checking: making canEnterVoiceChannel always true failed
      // nothing. Admission to a restricted channel's room is the same question
      // as reading it — the recipients of its current epoch, no one else — and
      // belonging to the Space is not that question.
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      addTearDown(svc.dispose);

      final spaceId = await svc.createSpace('Voice');
      for (final member in [bob, carol]) {
        expect(
          await svc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: member,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      final channelId = await svc.createChannel(
        spaceId,
        name: 'Leads only',
        kind: SpaceChannelKind.voice,
        access: SpaceChannelAccess.restricted,
        members: [bob],
      );
      expect(channelId, isNotNull);

      expect(
        await svc.canEnterVoiceChannel(spaceId, channelId, bob),
        isTrue,
        reason: 'a recipient of the current epoch belongs in the room',
      );
      expect(
        await svc.canEnterVoiceChannel(spaceId, channelId, carol),
        isFalse,
        reason: 'a Space member who is not in the channel is not in its room',
      );
    },
  );

  test('an ORDINARY group cannot be adopted as the device group, however '
      'legitimately you belong to it', () async {
    // Found by breaking the guard: dropping the isSovereignDevice check let
    // any group become the device group and NOTHING in the suite noticed.
    // Adoption is not cosmetic — it binds devices.gid, installs the sovereign
    // credential, and replays the group's messages as DEVICE-SYNC events, so
    // an ordinary chat's traffic would be read as settings, contacts and the
    // cloud index. Membership is not enough; the group has to BE one.
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner));
    addTearDown(svc.dispose);

    final ordinary = await svc.createGroup('Just a chat');
    expect(
      await svc.addControlOp(
        ordinary,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      ),
      isTrue,
    );
    expect(
      (await svc.load(ordinary))!.manifest.isSovereignDevice,
      isFalse,
      reason: 'the fixture must really be an ordinary group',
    );

    expect(await svc.adoptDeviceGroup(ordinary), isFalse);
    expect(
      await svc.deviceGroupIdHex(),
      isNull,
      reason: 'a refused adoption must not leave the pointer behind',
    );
  });

  test('a message signed for ANOTHER group is refused when spliced into this '
      'one — the row names its own group and that name is checked', () async {
    // Found by breaking the guard: removing `m.groupId == groupId` from
    // _validMessageFor was noticed by NOTHING in the suite. A signed row
    // carries the group it was written for, and without that check a member of
    // two groups could move another member's message from one into the other —
    // it stays validly signed, so nothing downstream would question it.
    //
    // WHAT THIS DOES AND DOES NOT CATCH: removing that clause fails this test.
    // Making the whole function return true does NOT — some other layer also
    // refuses the row then, and I did not identify which. So this pins the
    // clause, not the whole guard, and says so rather than implying more.
    //
    // The sibling clauses on reactions and posts (r.groupId / post.spaceId)
    // are ALSO unnoticed when removed, but they cannot be exercised the same
    // way: a reaction names its target inside the encrypted payload, and that
    // target is a message — which THIS guard already keeps out of the wrong
    // group. They are defended in depth rather than untested, and a test
    // spliced the obvious way passes with them removed, proving nothing. One
    // was written that way and deleted rather than left looking like cover.
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final ownerSvc = GroupService(storage, _FakeSigner(owner));
    addTearDown(ownerSvc.dispose);
    final bobStorage = FakeHvContainer().storage();
    await bobStorage.open(password: 'pw', createIfMissing: true);
    final bobSvc = GroupService(bobStorage, _FakeSigner(bob));
    addTearDown(bobSvc.dispose);

    final secret = await ownerSvc.createGroup('Secret');
    final ordinary = await ownerSvc.createGroup('Ordinary');
    for (final gid in [secret, ordinary]) {
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
    }
    expect(
      await ownerSvc.postMessage(secret, 'not for the other group'),
      isTrue,
    );
    // A legitimate row in the SAME doctored snapshot. Without it the test
    // would pass whenever nothing landed at all — and "nothing landed" has
    // many causes besides the guard under test. Verified by breaking it.
    expect(await ownerSvc.postMessage(ordinary, 'belongs here'), isTrue);

    final secretWire =
        jsonDecode(ownerSvc.snapshotJson((await ownerSvc.load(secret))!))
            as Map<String, dynamic>;
    final ordinaryWire =
        jsonDecode(ownerSvc.snapshotJson((await ownerSvc.load(ordinary))!))
            as Map<String, dynamic>;
    // The manifest stays Ordinary's; only the message rows are foreign.
    ordinaryWire['g'] = [
      ...(ordinaryWire['g'] as List),
      ...(secretWire['g'] as List),
    ];
    expect(
      (secretWire['g'] as List),
      isNotEmpty,
      reason: 'the fixture must actually carry a message to smuggle',
    );

    await bobSvc.ingestSnapshot(jsonEncode(ordinaryWire));

    // Observed on what was STORED, not on what is displayed: a display filter
    // would make this pass while the foreign row sat in the bundle.
    final stored = (await bobSvc.load(ordinary))!.messages;
    final landed = stored.map((m) => m.body);
    expect(
      stored.every((m) => m.groupId == ordinary),
      isTrue,
      reason: 'no stored row may name a group other than the one holding it',
    );
    expect(
      landed,
      contains('belongs here'),
      reason:
          'the snapshot itself was accepted — this is not a blanket refusal',
    );
    expect(
      landed,
      isNot(contains('not for the other group')),
      reason: 'a row that names another group must not fold into this one',
    );
  });

  test('broadcast ships the snapshot to every other member', () async {
    final sent = <(NodeId, NodeId)>[];
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(
      storage,
      _FakeSigner(owner),
      send: (peer, gid, json) async => sent.add((peer, gid)),
    );
    final gid = await svc.createGroup('G');
    await svc.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );
    await svc.addControlOp(
      gid,
      ControlOp.addMember,
      target: carol,
      role: GroupRole.member,
    );
    final n = await svc.broadcast(gid);
    expect(n, 2, reason: 'both members, not self');
    expect(sent.map((e) => e.$1).toSet(), {bob, carol});
    expect(sent.every((e) => e.$2 == gid), isTrue);
  });

  test('XOR neighbour selection is deterministic, unique, and capped at k', () {
    final self = _id(1);
    final peers = [_id(7), _id(2), _id(5), _id(3), _id(0), _id(3)];

    expect(
      nearestGroupNodesByXor(self, peers, k: 3),
      [_id(0), _id(3), _id(2)],
      reason: 'distance is numeric XOR, not membership/insertion order',
    );
    expect(nearestGroupNodesByXor(self, peers.reversed, k: 3), [
      _id(0),
      _id(3),
      _id(2),
    ]);
    expect(nearestGroupNodesByXor(self, peers, k: 0), isEmpty);
  });

  test('a candidate that IS the sort origin is kept, not filtered', () {
    // The origin is the IDENTITY, and the master device's transport id IS the
    // identity. The picker used to drop any candidate equal to the origin as
    // "self" — which on a sibling device silently removed the MASTER from
    // every sparse delta: the post fanned out only to a deleted third device,
    // the master received nothing, and the sender logged success. Candidate
    // lists are built self-free at the call sites, which are the layer that
    // can tell "me the identity" from "me the device"; the picker must not
    // answer that question again.
    final identity = _id(1);
    final master = identity; // same 32 bytes — that is the whole point
    final dead = _id(9);
    expect(
      nearestGroupNodesByXor(identity, [dead, master], k: 5),
      containsAll(<NodeId>[master, dead]),
      reason: 'the master device vanished from the sibling\'s fanout',
    );
  });

  test(
    'chat deltas use five XOR neighbours and relay once transitively',
    () async {
      final sent = <(NodeId, String)>[];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        send: (peer, gid, json) async => sent.add((peer, json)),
      );
      final gid = await svc.createGroup('overlay');
      final members = [_id(0), _id(2), _id(3), _id(4), _id(5), _id(7)];
      for (final member in members) {
        await svc.addControlOp(
          gid,
          ControlOp.addMember,
          target: member,
          role: GroupRole.member,
        );
      }
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      sent.clear();

      await svc.postMessage(gid, 'sparse');
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(sent.map((entry) => entry.$1).toSet(), {
        _id(0),
        _id(3),
        _id(2),
        _id(5),
        _id(4),
      });
      expect(sent, hasLength(GroupService.kGroupSyncNeighbors));
      final delta = sent.first.$2;
      final wire = jsonDecode(delta) as Map;
      expect(
        wire['ov'],
        isA<String>(),
        reason: 'the stable overlay id breaks relay cycles',
      );

      final relayStorage = FakeHvContainer().storage();
      await relayStorage.open(password: 'pw', createIfMissing: true);
      final relayed = <NodeId>[];
      final relay = GroupService(
        relayStorage,
        _FakeSigner(_id(3)),
        send: (peer, gid, json) async => relayed.add(peer),
      );
      final ownerBundle = (await svc.load(gid))!;
      // Materialize membership without the new message, then deliver its delta
      // through real ingress so the sparse overlay forwards it.
      final beforeMessage = ownerBundle.copyWith(messages: const []);
      expect(
        await relay.ingestSnapshot(
          svc.snapshotJson(beforeMessage, recipient: _id(3)),
        ),
        isTrue,
      );
      expect(await relay.ingestGroupEntry(owner, delta), isTrue);
      expect(relayed, isNotEmpty);
      final once = relayed.length;
      expect(await relay.ingestGroupEntry(owner, delta), isTrue);
      expect(relayed, hasLength(once), reason: 'a duplicate is not relayed');
    },
  );

  test('one row repeated is one delta, not one delta per copy', () async {
    // Audit XV-11. The overlay id was built from `(type, author, seq)` per
    // row, in a LIST — so repeating one valid row N times produced N different
    // ids, the relay dedup saw a brand new delta every time, and an accepted
    // contact could pump the same signed row through the overlay for as long
    // as it liked. The id is now a hash of the row CONTENT over a SET, so how
    // many copies a delta carries is not part of what the delta IS.
    //
    // It stays ephemeral: RAM only, never signed, never persisted.
    final sent = <(NodeId, String)>[];
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(
      storage,
      _FakeSigner(owner),
      send: (peer, gid, json) async => sent.add((peer, json)),
    );
    final gid = await svc.createGroup('multiplicity');
    for (final member in [_id(0), _id(2), _id(3), _id(4), _id(5), _id(7)]) {
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: member,
        role: GroupRole.member,
      );
    }
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    sent.clear();
    await svc.postMessage(gid, 'once');
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final delta = sent.first.$2;
    final wire = jsonDecode(delta) as Map;

    // What an accepted contact sends: the same signed row, repeated, with the
    // overlay id left exactly as it was. Nothing here is forged — every copy
    // is the sender's own valid row.
    final repeated = Map<String, dynamic>.from(wire);
    final row = (wire['g'] as List).single;
    repeated['g'] = [row, row, row, row, row];

    final relayStorage = FakeHvContainer().storage();
    await relayStorage.open(password: 'pw', createIfMissing: true);
    final relayed = <(NodeId, String)>[];
    final relay = GroupService(
      relayStorage,
      _FakeSigner(_id(3)),
      send: (peer, gid, json) async => relayed.add((peer, json)),
    );
    final ownerBundle = (await svc.load(gid))!;
    expect(
      await relay.ingestSnapshot(
        svc.snapshotJson(
          ownerBundle.copyWith(messages: const []),
          recipient: _id(3),
        ),
      ),
      isTrue,
    );

    expect(await relay.ingestGroupEntry(owner, jsonEncode(repeated)), isTrue);
    expect(
      relayed,
      isNotEmpty,
      reason:
          'a delta that repeats a row is still the delta it is — the id used '
          'to change with the copy count, so this one was not recognised',
    );
    final forwarded = jsonDecode(relayed.first.$2) as Map;
    expect(
      (forwarded['g'] as List),
      hasLength(1),
      reason: 'five copies in, five copies out to every neighbour',
    );

    // …and the plain delta afterwards is the SAME delta, so it is not relayed
    // a second time. That is the property the count used to destroy.
    final before = relayed.length;
    expect(await relay.ingestGroupEntry(owner, delta), isTrue);
    expect(
      relayed,
      hasLength(before),
      reason: 'one row, however many copies, is one identity',
    );
  });

  test(
    'boot gap-fill contacts the same deterministic XOR neighbours',
    () async {
      final sent = <(NodeId, String)>[];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        send: (peer, gid, json) async => sent.add((peer, json)),
      );
      final gid = await svc.createGroup('boot-overlay');
      for (final member in [_id(0), _id(2), _id(3), _id(4), _id(5), _id(7)]) {
        await svc.addControlOp(
          gid,
          ControlOp.addMember,
          target: member,
          role: GroupRole.member,
        );
      }
      await svc.setGroupSyncNeighborCount(gid, 2);
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      sent.clear();

      await svc.nudgeGroupSyncAll();

      expect(sent.map((entry) => entry.$1).toSet(), {_id(0), _id(3)});
      expect(sent, hasLength(2));
      expect(
        sent.every((entry) => (jsonDecode(entry.$2) as Map)['sreq'] == 1),
        isTrue,
      );
    },
  );

  test('per-chat XOR neighbour count persists and defaults to five', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner));
    final gid = await svc.createGroup('configurable-overlay');

    expect(await svc.groupSyncNeighborCount(gid), 5);
    await svc.setGroupSyncNeighborCount(gid, 8);
    expect(await svc.groupSyncNeighborCount(gid), 8);
    expect(
      await GroupService(
        storage,
        _FakeSigner(owner),
      ).groupSyncNeighborCount(gid),
      8,
    );
    expect(svc.setGroupSyncNeighborCount(gid, 0), throwsA(isA<RangeError>()));
    expect(svc.setGroupSyncNeighborCount(gid, 21), throwsA(isA<RangeError>()));
  });

  test(
    'inline image attachment persists + survives snapshot round-trip',
    () async {
      // A realistic-size payload (~40 KB) so the bundle overflows the single
      // ~4 KB setting cap and is chunked across the file-store — the exact case
      // that threw PayloadTooLarge when the bundle lived in one setting.
      final big = 'Q' * 40000;
      final att = GroupAttachment(kind: 'image', dataB64: big, w: 40, h: 30);
      final s1 = FakeHvContainer().storage();
      await s1.open(password: 'pw', createIfMissing: true);
      final owned = GroupService(s1, _FakeSigner(owner));
      final gid = await owned.createGroup('Pics');
      await owned.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      expect(await owned.postMessage(gid, 'look', attachment: att), isTrue);

      final mine = (await owned.messagesOf(gid)).single;
      expect(mine.body, 'look');
      expect(mine.attachment, isNotNull);
      expect(mine.attachment!.w, 40);
      expect(mine.attachment!.h, 30);
      expect(mine.attachment!.dataB64, big);

      // Fresh member device materializes the group AND the image via snapshot.
      final snap = owned.snapshotJson((await owned.load(gid))!);
      final s2 = FakeHvContainer().storage();
      await s2.open(password: 'pw', createIfMissing: true);
      final bobDev = GroupService(s2, _FakeSigner(bob));
      expect(await bobDev.ingestSnapshot(snap), isTrue);
      final got = (await bobDev.messagesOf(gid)).single;
      expect(got.attachment?.dataB64, big);
      expect(got.attachment?.w, 40);
    },
  );

  test('attachment is signed: canonicalBytes differ, text-only unchanged', () {
    GroupMessage base({GroupAttachment? att}) => GroupMessage(
      groupId: _id(2),
      author: owner,
      seq: 0,
      prevHash: '',
      body: 'hi',
      policyVersion: 0,
      createdAtMs: 5,
      signature: Uint8List(0),
      attachment: att,
    );
    final textOnly = base().canonicalBytes();
    final withImg = base(
      att: const GroupAttachment(kind: 'image', dataB64: 'QQ', w: 1, h: 1),
    ).canonicalBytes();
    // The attachment is inside the signed bytes (tamper-evident)...
    expect(withImg, isNot(equals(textOnly)));
    // ...and a text-only message signs byte-identically to before the field
    // existed (the 'att' key is omitted, not null).
    expect(String.fromCharCodes(textOnly).contains('att'), isFalse);
    // JSON round-trip preserves the attachment.
    final rt = GroupMessage.fromJson(
      base(
        att: const GroupAttachment(
          kind: 'image',
          dataB64: 'QQ',
          w: 2,
          h: 3,
          name: 'photo.png',
        ),
      ).toJson(),
    )!;
    expect(rt.attachment?.w, 2);
    expect(rt.attachment?.h, 3);
    expect(rt.attachment?.dataB64, 'QQ');
    expect(rt.attachment?.name, 'photo.png');
  });

  test(
    'voice attachment: durationMs rides in w, round-trips, signs stably',
    () {
      GroupMessage voiceMsg() => GroupMessage(
        groupId: _id(2),
        author: owner,
        seq: 0,
        prevHash: '',
        body: '',
        policyVersion: 0,
        createdAtMs: 5,
        signature: Uint8List(0),
        attachment: const GroupAttachment(
          kind: 'voice',
          dataB64: 'Vk9QMQ',
          w: 4200,
          h: 1,
        ),
      );
      final rt = GroupMessage.fromJson(voiceMsg().toJson())!;
      expect(rt.attachment?.kind, 'voice');
      expect(rt.attachment?.w, 4200, reason: 'durationMs travels in w');
      expect(rt.attachment?.h, 1);
      // The parsed message re-canonicalizes byte-identically — a signature a
      // voice-aware build minted verifies on any build (zero schema change).
      expect(rt.canonicalBytes(), voiceMsg().canonicalBytes());
    },
  );

  test(
    'content path: member request → grant; stranger/replay/unknown → drop',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final grants = <(NodeId, String)>[];
      final sentReq = <String>[];
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        grantContentServe: (peer, cid) => grants.add((peer, cid)),
      );
      final gid = await svc.createGroup('G');
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await svc.postMessage(
        gid,
        '',
        attachment: const GroupAttachment(
          kind: 'image',
          dataB64: 'QQ',
          w: 1,
          h: 1,
          cid: 'c0ffee',
        ),
      );
      expect(await svc.referencedContentIds(gid), {'c0ffee'});

      // Bob (member, own service+store) mints a signed request…
      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        sendContentRequest: (holder, json) async => sentReq.add(json),
      );
      expect(await bobSvc.requestGroupContent(gid, 'c0ffee', owner), isTrue);
      // …and the holder authorizes: a grant for exactly (bob, cid).
      expect(await svc.handleContentRequest(sentReq.last), isTrue);
      expect(grants.single.$1, bob);
      expect(grants.single.$2, 'c0ffee');

      // A replay of the same request is refused (nonce cache).
      expect(await svc.handleContentRequest(sentReq.last), isFalse);

      // A stranger's request never grants.
      final evieSvc = GroupService(
        bobStorage,
        _FakeSigner(_id(7)),
        sendContentRequest: (holder, json) async => sentReq.add(json),
      );
      expect(await evieSvc.requestGroupContent(gid, 'c0ffee', owner), isTrue);
      expect(await svc.handleContentRequest(sentReq.last), isFalse);

      // A cid the group never referenced never grants either.
      expect(await bobSvc.requestGroupContent(gid, 'beef', owner), isTrue);
      expect(await svc.handleContentRequest(sentReq.last), isFalse);
      expect(grants, hasLength(1));
    },
  );

  test(
    'fetchGroupContent authorizes every current member and pulls from any',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final sentTo = <NodeId>[];
      final pulls = <(List<NodeId>, String)>[];
      final svc = GroupService(
        storage,
        _FakeSigner(bob),
        sendContentRequest: (holder, json) async {
          sentTo.add(holder);
          if (holder == carol) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        },
        startContentPullFromAny: (holders, cid) async =>
            pulls.add((holders, cid)),
        contentRequestFanoutTimeout: const Duration(milliseconds: 5),
        contentGrantDelay: Duration.zero,
      );
      final gid = await svc.createGroup('G');
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: owner,
        role: GroupRole.member,
      );
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: carol,
        role: GroupRole.member,
      );
      await svc.postMessage(
        gid,
        '',
        attachment: const GroupAttachment(
          kind: 'file',
          dataB64: 'QQ==',
          w: 10,
          h: 1,
          cid: 'c0ffee',
        ),
      );

      expect(await svc.fetchGroupContent(gid, 'c0ffee', owner), isTrue);
      expect(sentTo.toSet(), {owner, carol});
      expect(pulls.single.$1, [owner, carol], reason: 'author stays preferred');
      expect(pulls.single.$2, 'c0ffee');
      expect(
        await svc.fetchGroupContent(gid, 'not-referenced', owner),
        isFalse,
        reason: 'membership must not become an arbitrary cid probe',
      );
      expect(sentTo, hasLength(2));

      // Without a pull sink the flow reports not-started (nothing to drive).
      final noPull = GroupService(
        storage,
        _FakeSigner(bob),
        sendContentRequest: (holder, json) async => sentTo.add(holder),
        contentGrantDelay: Duration.zero,
      );
      expect(await noPull.fetchGroupContent(gid, 'c0ffee', owner), isFalse);
    },
  );

  test(
    'a member holder serves with the owner offline and current ACL cuts stale '
    'requesters and denied holders off',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      final carolStorage = FakeHvContainer().storage();
      for (final storage in [ownerStorage, bobStorage, carolStorage]) {
        await storage.open(password: 'pw', createIfMissing: true);
      }

      late GroupService ownerSvc;
      late GroupService bobSvc;
      var ownerOnline = true;
      final ownerGrants = <(NodeId, String)>[];
      final bobGrants = <(NodeId, String)>[];
      final carolRequestTargets = <NodeId>[];
      final ownerRequestTargets = <NodeId>[];
      bool? ownerToBobDecision;
      final cid = sha256.convert(const [7, 8, 9]).toString();
      final bytes = Uint8List.fromList(const [7, 8, 9]);

      ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        grantContentServe: (peer, contentId) =>
            ownerGrants.add((peer, contentId)),
        sendContentRequest: (holder, requestJson) async {
          ownerRequestTargets.add(holder);
          if (holder == bob) {
            ownerToBobDecision = await bobSvc.handleContentRequest(requestJson);
          }
        },
        startContentPullFromAny: (_, _) async {},
        contentGrantDelay: Duration.zero,
      );
      bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        grantContentServe: (peer, contentId) =>
            bobGrants.add((peer, contentId)),
        sendContentRequest: (holder, requestJson) async {
          if (holder != owner || !ownerOnline) {
            throw StateError('owner is offline');
          }
          await ownerSvc.handleContentRequest(requestJson);
        },
      );
      final carolSvc = GroupService(
        carolStorage,
        _FakeSigner(carol),
        sendContentRequest: (holder, requestJson) async {
          carolRequestTargets.add(holder);
          if (holder == owner) {
            if (!ownerOnline) throw StateError('owner is offline');
            await ownerSvc.handleContentRequest(requestJson);
          } else if (holder == bob) {
            await bobSvc.handleContentRequest(requestJson);
          }
        },
        startContentPullFromAny: (holders, contentId) async {
          expect(holders, [owner, bob], reason: 'author remains preferred');
          expect(contentId, cid);
          final source = await bobStorage.loadFile(contentId);
          expect(source, bytes, reason: 'the non-owner holder has exact bytes');
          await carolStorage.storeFile(contentId, source!, name: 'from-bob');
        },
        contentGrantDelay: Duration.zero,
      );
      addTearDown(ownerSvc.dispose);
      addTearDown(bobSvc.dispose);
      addTearDown(carolSvc.dispose);

      final spaceId = await ownerSvc.createSpace(
        'Owner-offline holder cut-off',
        visibility: SpaceVisibility.public,
      );
      for (final member in [bob, carol]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: member,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      expect(
        await ownerSvc.publishSpacePost(
          spaceId,
          body: 'replicated media',
          media: [
            MediaObject(contentId: cid, kind: 'file', size: bytes.length),
          ],
          broadcast: false,
        ),
        isNotNull,
      );
      await ownerStorage.storeFile(cid, bytes, name: 'owner');
      final initial = (await ownerSvc.load(spaceId))!;
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(initial, recipient: bob),
        ),
        isTrue,
      );
      expect(
        await carolSvc.ingestSnapshot(
          ownerSvc.snapshotJson(initial, recipient: carol),
        ),
        isTrue,
      );

      expect(await bobSvc.requestGroupContent(spaceId, cid, owner), isTrue);
      expect(ownerGrants, [(bob, cid)]);
      await bobStorage.storeFile(
        cid,
        (await ownerStorage.loadFile(cid))!,
        name: 'replica',
      );

      ownerOnline = false;
      expect(
        await carolSvc.fetchGroupContent(spaceId, cid, owner),
        isTrue,
        reason: 'the preferred author being offline must not block a holder',
      );
      expect(carolRequestTargets.toSet(), {owner, bob});
      expect(bobGrants, [(carol, cid)]);
      expect(await carolStorage.loadFile(cid), bytes);

      ownerOnline = true;
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.removeMember,
          target: carol,
        ),
        isTrue,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      ownerOnline = false;
      final staleCarolRequest = _FakeSigner(carol).signContentRequest(
        GroupContentRequest(
          groupId: spaceId,
          contentId: cid,
          requester: carol,
          nonce: 'stale-carol-after-removal',
          tsMs: DateTime.now().millisecondsSinceEpoch,
          signature: Uint8List(0),
        ),
      );
      final grantsBeforeRevokedRequest = bobGrants.length;
      expect(
        await bobSvc.handleContentRequest(
          jsonEncode(staleCarolRequest.toJson()),
        ),
        isFalse,
        reason:
            'an owner-offline holder must use its current fold, not the '
            'requester stale membership view',
      );
      expect(bobGrants, hasLength(grantsBeforeRevokedRequest));
      final revokedObservations = await bobSvc.spaceObservabilitySnapshot();
      expect(
        revokedObservations
            .counters['revokedDeliveryPrevented.reason.notMember'],
        1,
      );

      ownerOnline = true;
      final denyRoleId = sha256
          .convert(utf8.encode('deny-holder-distribution'))
          .toString();
      expect(
        await ownerSvc.replaceSpaceAccessPolicy(
          spaceId,
          expectedRevision: 0,
          roles: [
            SpaceRoleDefinition(
              roleId: denyRoleId,
              name: 'No redistribution',
              grants: const <SpacePermissionGrant>[],
              denials: const [
                SpacePermissionDenial(
                  permission: SpacePermission.distributeContent,
                  scope: SpacePermissionScope.space(),
                ),
              ],
            ),
          ],
          groups: const <SpaceMemberGroup>[],
          directAssignments: [
            SpaceMemberRoleAssignment(member: bob, roleIds: [denyRoleId]),
          ],
        ),
        isNotNull,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );

      final directOwnerRequest = _FakeSigner(owner).signContentRequest(
        GroupContentRequest(
          groupId: spaceId,
          contentId: cid,
          requester: owner,
          nonce: 'owner-to-denied-holder',
          tsMs: DateTime.now().millisecondsSinceEpoch,
          signature: Uint8List(0),
        ),
      );
      final grantsBeforeDeniedHolder = bobGrants.length;
      expect(
        await bobSvc.handleContentRequest(
          jsonEncode(directOwnerRequest.toJson()),
        ),
        isFalse,
        reason: 'serve authority belongs to the holder current scoped ACL too',
      );
      expect(bobGrants, hasLength(grantsBeforeDeniedHolder));

      ownerRequestTargets.clear();
      ownerToBobDecision = null;
      expect(
        await ownerSvc.fetchGroupContent(spaceId, cid, bob),
        isFalse,
        reason: 'known ineligible holders are omitted before request fanout',
      );
      expect(ownerRequestTargets, isEmpty);
      expect(ownerToBobDecision, isNull);
    },
  );

  test(
    'an owner-offline protected holder enforces current channel epoch and its '
    'own scoped distribution permission',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      final carolStorage = FakeHvContainer().storage();
      for (final storage in [ownerStorage, bobStorage, carolStorage]) {
        await storage.open(password: 'pw', createIfMissing: true);
      }
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final bobGrants = <(NodeId, String)>[];
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        grantContentServe: (peer, contentId) =>
            bobGrants.add((peer, contentId)),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final carolSvc = GroupService(
        carolStorage,
        _FakeSigner(carol),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      addTearDown(ownerSvc.dispose);
      addTearDown(bobSvc.dispose);
      addTearDown(carolSvc.dispose);

      final spaceId = await ownerSvc.createSpace('Protected holder cut-off');
      for (final member in [bob, carol]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: member,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      final channelId = await ownerSvc.createChannel(
        spaceId,
        name: 'Protected',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
        members: [bob, carol],
      );
      expect(channelId, isNotNull);
      final cid = sha256.convert(const [10, 11, 12]).toString();
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'protected media',
          channelId: channelId,
          attachment: MediaObject(
            kind: 'file',
            contentId: cid,
            name: 'protected.bin',
            size: 3,
          ),
          broadcast: false,
        ),
        isTrue,
      );
      await bobStorage.storeFile(
        cid,
        Uint8List.fromList(const [10, 11, 12]),
        name: 'replica',
      );
      final initial = (await ownerSvc.load(spaceId))!;
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(initial, recipient: bob),
        ),
        isTrue,
      );
      expect(
        await carolSvc.ingestSnapshot(
          ownerSvc.snapshotJson(initial, recipient: carol),
        ),
        isTrue,
      );

      GroupContentRequest request(
        NodeId requester, {
        required String nonce,
        required int channelEpoch,
      }) => _FakeSigner(requester).signContentRequest(
        GroupContentRequest(
          groupId: spaceId,
          contentId: cid,
          requester: requester,
          nonce: nonce,
          tsMs: DateTime.now().millisecondsSinceEpoch,
          channelId: channelId,
          channelEpoch: channelEpoch,
          signature: Uint8List(0),
        ),
      );

      expect(
        await bobSvc.handleContentRequest(
          jsonEncode(
            request(
              carol,
              nonce: 'carol-before-channel-revoke',
              channelEpoch: 1,
            ).toJson(),
          ),
        ),
        isTrue,
      );
      expect(bobGrants, [(carol, cid)]);

      expect(
        await ownerSvc.setChannelMembers(spaceId, channelId!, [bob]),
        isTrue,
      );
      expect(
        (await ownerSvc.stateOf(
          spaceId,
        ))!.protectedChannels[channelId.hex]!.channelEpoch,
        2,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final grantsBeforeEpochCutOff = bobGrants.length;
      expect(
        await bobSvc.handleContentRequest(
          jsonEncode(
            request(
              carol,
              nonce: 'carol-stale-channel-epoch',
              channelEpoch: 1,
            ).toJson(),
          ),
        ),
        isFalse,
        reason:
            'the non-owner holder enforces the rotated epoch without asking '
            'the owner',
      );
      expect(bobGrants, hasLength(grantsBeforeEpochCutOff));

      final denyRoleId = sha256
          .convert(utf8.encode('deny-protected-holder-distribution'))
          .toString();
      expect(
        await ownerSvc.replaceSpaceAccessPolicy(
          spaceId,
          expectedRevision: 0,
          roles: [
            SpaceRoleDefinition(
              roleId: denyRoleId,
              name: 'No protected redistribution',
              grants: const <SpacePermissionGrant>[],
              denials: [
                SpacePermissionDenial(
                  permission: SpacePermission.distributeContent,
                  scope: SpacePermissionScope(
                    kind: SpacePermissionScopeKind.channel,
                    targetId: channelId,
                  ),
                ),
              ],
            ),
          ],
          groups: const <SpaceMemberGroup>[],
          directAssignments: [
            SpaceMemberRoleAssignment(member: bob, roleIds: [denyRoleId]),
          ],
        ),
        isNotNull,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final grantsBeforeHolderDenial = bobGrants.length;
      expect(
        await bobSvc.handleContentRequest(
          jsonEncode(
            request(
              owner,
              nonce: 'owner-to-scoped-denied-holder',
              channelEpoch: 2,
            ).toJson(),
          ),
        ),
        isFalse,
        reason:
            'a channel-scoped denial on the holder blocks serving retained '
            'bytes too',
      );
      expect(bobGrants, hasLength(grantsBeforeHolderDenial));
    },
  );

  test(
    'snapshot content is gated even for an internal non-member caller',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(storage, _FakeSigner(owner));
      addTearDown(svc.dispose);
      final spaceId = await svc.createSpace(
        'Public but membership-scoped wire',
        visibility: SpaceVisibility.public,
      );
      expect(
        await svc.publishSpacePost(
          spaceId,
          body: 'must not ride an unauthorized member snapshot',
          broadcast: false,
        ),
        isNotNull,
      );

      final wire =
          jsonDecode(
                svc.snapshotJson((await svc.load(spaceId))!, recipient: _id(7)),
              )
              as Map<String, dynamic>;
      expect(wire['p'], isEmpty);
      expect(wire['g'], isEmpty);
      expect(wire['r'], isEmpty);
      expect(wire, isNot(contains('ke')));
    },
  );

  test(
    'stranger sync: member delta merges into a held group; others drop',
    () async {
      Future<void> drain() async {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      final sent = <String>[];
      final s1 = FakeHvContainer().storage();
      await s1.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        s1,
        _FakeSigner(owner),
        send: (p, g, j) async => sent.add(j),
      );
      final gid = await ownerSvc.createGroup('G');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await drain();
      final full =
          sent.last; // the join snapshot bob's device materializes from

      final s2 = FakeHvContainer().storage();
      await s2.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(
        s2,
        _FakeSigner(bob),
        send: (p, g, j) async => sent.add(j),
      );
      expect(await bobSvc.ingestSnapshot(full), isTrue);
      sent.clear();
      await bobSvc.postMessage(gid, 'from-bob');
      await drain();
      final delta = sent.last;

      // Bob needs NO contact relationship: he is a member per the owner's fold.
      expect(await ownerSvc.allowStrangerGroupSync(bob, gid.hex), isTrue);
      expect(await ownerSvc.ingestSnapshotFromStranger(bob, delta), isTrue);
      expect(
        (await ownerSvc.messagesOf(gid)).map((m) => m.body),
        contains('from-bob'),
      );

      // A non-member stranger is refused even with a well-formed bundle…
      expect(await ownerSvc.ingestSnapshotFromStranger(_id(7), delta), isFalse);
      // …and a group we don't hold NEVER materializes from a stranger.
      expect(await ownerSvc.allowStrangerGroupSync(bob, 'ff' * 32), isFalse);
      expect(
        await ownerSvc.ingestSnapshotFromStranger(
          bob,
          '{"m":{"gid":"${'ff' * 32}"}}',
        ),
        isFalse,
      );
    },
  );

  // ── A stranger's SYNC REQUEST passes the same door as its bundle ──────────
  //
  // A Space id is its group id, which is published on purpose, so "knows the
  // id" is not a credential. The request branch used to reach the handler
  // straight from the wire and have its entitlement settled deep inside, after
  // the whole group had been loaded, folded, retention-materialized and
  // fork-scanned (audit report6 XV-09). Both halves matter and are pinned
  // below: an outsider gets nothing AND does not get us to do the work, while
  // a member who is not a contact — the case the stranger door exists for —
  // still gets its answer.
  test('stranger sync REQUEST: a non-member is turned away at the door, a '
      'member without any contact relationship is still answered', () async {
    Future<void> drain() async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    final owner = _id(1);
    final bob = _id(2);
    final outsider = _id(9);

    final toWire = <String>[];
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    final ownerSvc = GroupService(
      s1,
      _FakeSigner(owner),
      send: (p, g, j) async => toWire.add(j),
    );
    final spaceId = await ownerSvc.createSpace(
      'Open house',
      visibility: SpaceVisibility.public,
    );
    await ownerSvc.addControlOp(
      spaceId,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );
    await drain();
    final joinSnapshot = toWire.last;

    final s2 = FakeHvContainer().storage();
    await s2.open(password: 'pw', createIfMissing: true);
    final bobSvc = GroupService(s2, _FakeSigner(bob), send: (p, g, j) async {});
    expect(await bobSvc.ingestSnapshot(joinSnapshot), isTrue);
    expect(
      await ownerSvc.publishSpacePost(spaceId, body: 'members only'),
      isNotNull,
    );
    await drain();

    final request = (await bobSvc.buildGroupSyncRequest(spaceId))!;
    final requestJson = jsonEncode(request);

    // The outsider replays the very same well-formed request, which needs
    // nothing but the public Space id and a transport session.
    toWire.clear();
    expect(
      await ownerSvc.ingestGroupEntryFromStranger(outsider, requestJson),
      isFalse,
    );
    expect(toWire, isEmpty, reason: 'nothing goes back to a non-member');
    final afterOutsider = await ownerSvc.spaceObservabilitySnapshot();
    expect(
      afterOutsider.counters['aclDenied.reason.notMember'],
      isNull,
      reason:
          'the request was refused at the stranger door — the handler '
          'that records this was never entered at all',
    );
    expect(afterOutsider.counters['p2pBackfill.reason.notMember'], isNull);

    // …and the door is not simply shut for everyone: Bob is a member per our
    // own fold and holds no contact relationship with us, which is exactly
    // the exchange the stranger path exists to carry.
    expect(await ownerSvc.allowStrangerGroupSync(bob, spaceId.hex), isTrue);
    expect(
      await ownerSvc.ingestGroupEntryFromStranger(bob, requestJson),
      isTrue,
    );
    expect(
      toWire,
      isNotEmpty,
      reason: 'the legitimate member-to-member sync still gets its delta',
    );
    expect(await bobSvc.ingestSnapshot(toWire.last), isTrue);
    expect(
      (await bobSvc.postsOf(spaceId)).map((post) => post.body),
      contains('members only'),
    );
  });

  test(
    'a sync request is refused before the group is materialized, not after',
    () async {
      Future<void> drain() async {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      final owner = _id(1);
      final bob = _id(2);
      final outsider = _id(9);

      final toWire = <String>[];
      final s1 = FakeHvContainer().storage();
      await s1.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        s1,
        _FakeSigner(owner),
        send: (p, g, j) async => toWire.add(j),
      );
      final spaceId = await ownerSvc.createSpace(
        'Retention house',
        visibility: SpaceVisibility.public,
      );
      await ownerSvc.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      for (var i = 0; i < 5; i++) {
        expect(
          await ownerSvc.publishSpacePost(spaceId, body: 'post $i'),
          isNotNull,
        );
      }
      await drain();
      final request = (await ownerSvc.buildGroupSyncRequest(spaceId))!;

      // Materializing the retention history is the first of the per-group
      // passes the reply is built from, and it is the one that reads the wall
      // clock. A refusal that happens first therefore never reads it — this is
      // the observable edge between "decide, then work" and "work, then
      // decide". A member's request does the work and does read it.
      var wallClockReads = 0;
      ownerSvc.debugWallClockMs = () {
        wallClockReads++;
        return DateTime.now().millisecondsSinceEpoch;
      };

      toWire.clear();
      expect(await ownerSvc.handleGroupSyncRequest(outsider, request), isFalse);
      expect(
        wallClockReads,
        0,
        reason: 'the outsider was refused before a single pass over the group',
      );
      expect(toWire, isEmpty);
      expect(
        (await ownerSvc.spaceObservabilitySnapshot())
            .counters['aclDenied.reason.notMember'],
        1,
        reason:
            'reached through the handler directly, the refusal is still '
            'recorded — it just costs nothing now',
      );

      // Control: an entitled member still gets the full treatment, so the
      // refusal above is an admission decision and not a dead code path.
      final bobRequest = Map<String, dynamic>.from(request)
        ..['p'] = <String, Object>{}
        ..['pg'] = <String, Object>{}
        ..['c'] = <String, Object>{};
      expect(await ownerSvc.handleGroupSyncRequest(bob, bobRequest), isTrue);
      expect(
        wallClockReads,
        greaterThan(0),
        reason:
            'the member DOES pay for the passes the outsider skipped — '
            'the counter is measuring real work, not nothing at all',
      );
      expect(toWire, isNotEmpty);
    },
  );

  test(
    'unread + incoming: ingest feeds the stream, watermark clears the count',
    () async {
      Future<void> drain() async {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      final sent = <String>[];
      final s1 = FakeHvContainer().storage();
      await s1.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        s1,
        _FakeSigner(owner),
        send: (p, g, j) async => sent.add(j),
      );
      final gid = await ownerSvc.createGroup('G');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await drain();
      final s2 = FakeHvContainer().storage();
      await s2.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(
        s2,
        _FakeSigner(bob),
        send: (p, g, j) async => sent.add(j),
      );
      await bobSvc.ingestSnapshot(sent.last);
      sent.clear();
      await bobSvc.postMessage(gid, 'ping-1');
      await bobSvc.postMessage(gid, 'ping-2');
      await drain();

      // Owner ingests bob's deltas: the incoming stream fires per NEW message…
      final got = <String>[];
      final sub = ownerSvc.incoming.listen((n) => got.add(n.message.body));
      for (final delta in sent) {
        await ownerSvc.ingestSnapshot(delta);
      }
      await drain();
      expect(got, ['ping-1', 'ping-2']);
      // …a re-ingest is silent (dedup)…
      await ownerSvc.ingestSnapshot(sent.last);
      await drain();
      expect(got, hasLength(2));
      // …and our OWN messages never feed the stream.
      await ownerSvc.postMessage(gid, 'mine');
      await drain();
      expect(got, hasLength(2));
      await sub.cancel();

      // Unread counts bob's two messages, ignores ours, and clears on seen.
      expect(await ownerSvc.unreadOf(gid), 2);
      final listed = await ownerSvc.listGroups();
      expect(listed.single.unread, 2);
      // The list carries the last-message preview + its timestamp too.
      expect(listed.single.preview, 'mine');
      expect(listed.single.lastTs, greaterThan(0));
      await ownerSvc.markGroupSeen(gid);
      expect(await ownerSvc.unreadOf(gid), 0);

      // The local notification mute persists and rides the list record.
      expect(listed.single.muted, isFalse);
      await ownerSvc.setGroupMuted(gid, true);
      expect(await ownerSvc.isGroupMuted(gid), isTrue);
      expect((await ownerSvc.listGroups()).single.muted, isTrue);
      final mentionUntil = DateTime.now().add(const Duration(hours: 8));
      await ownerSvc.setGroupNotificationPolicy(
        gid,
        NotificationMuteMode.mentionsOnly,
        mentionUntil,
      );
      final mentionPolicy = await ownerSvc.groupNotificationPolicy(gid);
      expect(
        mentionPolicy.effectiveAt(DateTime.now()),
        NotificationMuteMode.mentionsOnly,
      );
      final mentionListed = (await ownerSvc.listGroups()).single;
      expect(mentionListed.muted, isTrue);
      expect(mentionListed.notificationMode, NotificationMuteMode.mentionsOnly);
      expect(
        mentionListed.notificationUntil?.millisecondsSinceEpoch,
        mentionUntil.millisecondsSinceEpoch,
      );
      await ownerSvc.setGroupNotificationPolicy(
        gid,
        NotificationMuteMode.mentionsOnly,
        DateTime.now().subtract(const Duration(minutes: 1)),
      );
      final expiredListed = (await ownerSvc.listGroups()).single;
      expect(expiredListed.muted, isFalse);
      expect(expiredListed.notificationMode, NotificationMuteMode.all);
      expect(expiredListed.notificationUntil, isNull);
      await ownerSvc.setGroupMuted(gid, false);
      expect(await ownerSvc.isGroupMuted(gid), isFalse);
    },
  );

  test('the local order bound on a group stamp is ONE-SIDED and tolerates '
      'honest drift', () {
    const now = 1700000000000;

    // The past is never touched: a stamp behind the receiver's clock cannot
    // float above anything, and a device back from a nap must keep its own
    // send time.
    expect(groupMessageOrderAt(now - 60000, now), now - 60000);
    expect(groupMessageOrderAt(0, now), 0);
    expect(groupMessageOrderAt(now, now), now);

    // Honest drift is believed to the millisecond, all the way to the bound.
    // This is why it is a TOLERANCE and not "anything ahead of my clock":
    // ordinary traffic keeps the author's own send order on every device.
    expect(
      groupMessageOrderAt(now + kMessageClockSkew.inMilliseconds, now),
      now + kMessageClockSkew.inMilliseconds,
      reason: 'an author exactly at the tolerated skew is still believed',
    );

    // One millisecond past it is not a clock reading any more, and the only
    // time the receiver actually knows is when the row arrived.
    expect(
      groupMessageOrderAt(now + kMessageClockSkew.inMilliseconds + 1, now),
      now,
    );
    expect(
      groupMessageOrderAt(now + const Duration(days: 365).inMilliseconds, now),
      now,
    );
  });

  test('the display-order projection is invisible to everything the author '
      'signed', () {
    final message = GroupMessage(
      groupId: _id(9),
      author: bob,
      seq: 3,
      prevHash: '',
      body: 'from the future',
      policyVersion: 0,
      createdAtMs: 4102444800000, // 2100-01-01
      signature: Uint8List(64),
      authorPubKey: bob.bytes,
    );
    // Pinned literally: `ts` is INSIDE these bytes, which is the whole reason
    // this surface gets a derived order instead of the 1:1 receipt clamp. If a
    // later change ever moves the stored stamp, this is what fails.
    expect(
      utf8.decode(message.canonicalBytes()),
      '{"gid":"${_id(9).hex}","author":"${bob.hex}","seq":3,"prev":"",'
      '"body":"from the future","pv":0,"ts":4102444800000}',
    );

    final projected = message.withOrderedAt(1700000000000);
    expect(projected.orderedAtMs, 1700000000000);
    expect(
      message.orderedAtMs,
      message.createdAtMs,
      reason: 'a row with no receipt is ordered by its own claim',
    );
    expect(
      projected.createdAtMs,
      message.createdAtMs,
      reason: "the author's signed word is left exactly as written",
    );
    expect(
      projected.canonicalBytes(),
      message.canonicalBytes(),
      reason: 'byte-identical: a signature made before this still verifies',
    );
    expect(
      jsonEncode(projected.toJson()),
      jsonEncode(message.toJson()),
      reason: 'nothing new reaches disk or the wire',
    );
    expect(
      groupMessageHash(projected),
      groupMessageHash(message),
      reason: 'dedup, chain prev-hash and fork evidence are untouched',
    );
    // The projection survives the copies the read path makes on the way out.
    expect(projected.withMediaHiddenByRetention().orderedAtMs, 1700000000000);
    expect(
      projected
          .withSignature(Uint8List(64), bob.bytes)
          .withDecryptedContent(const GroupMessageCleartext(body: 'decrypted'))
          .orderedAtMs,
      1700000000000,
    );
  });

  test('a group member stamping itself into the future owns the bottom of the '
      'log, the chat-list row and the unread badge until that future arrives — '
      'and the fix must not touch one signed byte', () async {
    Future<void> drain() async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    final sent = <String>[];
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    // Held clocks on both sides: this asserts an ORDER and an arrival
    // moment, so it must not race DateTime.now. `_now()` is monotonic per
    // service instance, so each side's stamps only ever move forward here.
    final t0 = DateTime.utc(2026, 8, 3, 12).millisecondsSinceEpoch;
    var wall = t0;
    final ownerSvc = GroupService(
      s1,
      _FakeSigner(owner),
      send: (p, g, j) async => sent.add(j),
    )..debugWallClockMs = () => wall;
    addTearDown(ownerSvc.dispose);
    final gid = await ownerSvc.createGroup('G');
    await ownerSvc.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );
    await drain();
    final s2 = FakeHvContainer().storage();
    await s2.open(password: 'pw', createIfMissing: true);
    // Bob back from a nap, a minute BEHIND the receiver.
    var bobWall = t0 - 60000;
    final bobSvc = GroupService(
      s2,
      _FakeSigner(bob),
      send: (p, g, j) async => sent.add(j),
    )..debugWallClockMs = () => bobWall;
    addTearDown(bobSvc.dispose);
    await bobSvc.ingestSnapshot(sent.last);
    sent.clear();

    await ownerSvc.postMessage(gid, 'mine');
    // A stamp in the PAST is never touched: it cannot float above anything,
    // and a device coming back must keep its own send time.
    await bobSvc.postMessage(gid, 'a minute ago');
    // Bob honestly a few minutes fast — exactly at the tolerated bound.
    bobWall = t0 + kMessageClockSkew.inMilliseconds;
    await bobSvc.postMessage(gid, 'nearly now');
    // Bob claims to live in 2027. Nothing in the group can contradict a
    // clock, and the signature over `ts` proves only who said it.
    final hostileTs = t0 + const Duration(days: 365).inMilliseconds;
    bobWall = hostileTs;
    await bobSvc.postMessage(gid, 'from the future');
    await drain();

    wall = t0 + 1000;
    for (final delta in sent) {
      await ownerSvc.ingestSnapshot(delta);
    }
    await drain();

    Future<List<String>> bodies() async =>
        (await ownerSvc.messagesOf(gid)).map((m) => m.body).toList();
    Future<GroupMessage> hostileRow() async => (await ownerSvc.messagesOf(
      gid,
    )).firstWhere((m) => m.body == 'from the future');

    expect(
      await bodies(),
      ['a minute ago', 'mine', 'from the future', 'nearly now'],
      reason:
          'the 2027 row is ranked where it ARRIVED, and the honest rows '
          'on both sides of the receiver clock keep their own send time',
    );

    // The stamp itself is untouched, and so is every byte the author signed:
    // rewriting it (the 1:1 answer) would invalidate the signature over
    // `canonicalBytes`, which includes `ts`, and take group admission with it.
    final hostile = await hostileRow();
    final landedAt = hostile.orderedAtMs;
    expect(hostile.createdAtMs, hostileTs);
    expect(
      landedAt,
      inInclusiveRange(wall, wall + 1000),
      reason: 'ordered by the one time the receiver actually knows',
    );
    final storedRow = (await ownerSvc.load(
      gid,
    ))!.messages.firstWhere((m) => m.body == 'from the future');
    expect(
      storedRow.createdAtMs,
      hostileTs,
      reason: 'what is on disk is what bob signed',
    );
    expect(hostile.canonicalBytes(), storedRow.canonicalBytes());
    expect(groupMessageHash(hostile), groupMessageHash(storedRow));
    // Nothing local rides out on the wire either. The arrival moment is a
    // number this receiver chose; shipping it would just be the same
    // unauthenticated stamp under a second name.
    final served =
        jsonDecode(ownerSvc.snapshotJson((await ownerSvc.load(gid))!)) as Map;
    expect(served.containsKey('mrx'), isFalse);
    expect(
      (served['g'] as List).firstWhere(
        (row) => (row as Map)['body'] == 'from the future',
      ),
      storedRow.toJson(),
      reason: 'served exactly as bob signed it, extra keys and all: none',
    );

    // The chat-list row: preview and recency both come off the last message,
    // so before this the group sat at the top of Chats showing 'from the
    // future' until 2027.
    final listed = (await ownerSvc.listGroups()).single;
    expect(listed.preview, 'nearly now');
    expect(listed.lastTs, t0 + kMessageClockSkew.inMilliseconds);
    expect(listed.lastTs, lessThan(hostileTs));

    // The badge. `group.seen` is a LOCAL clock reading, so a row stamped
    // into the future is newer than every watermark this device will ever
    // write and the badge could not be cleared again — the mirror image of
    // what the same stamp did to the 1:1 badge, which went permanently
    // silent instead.
    expect(await ownerSvc.unreadOf(gid), 3);
    wall = t0 + const Duration(minutes: 10).inMilliseconds;
    await ownerSvc.markGroupSeen(gid);
    expect(
      await ownerSvc.unreadOf(gid),
      0,
      reason: 'a member cannot pin the badge on by claiming to be in 2027',
    );
    expect((await ownerSvc.listGroups()).single.unread, 0);

    // ONCE, on arrival. Peers re-ship whole snapshots on every reconnect, so
    // this exact row comes back against a clock that has moved on; if the
    // bound were re-derived then, the row would walk down the log on every
    // sync instead of staying where it landed.
    wall = t0 + const Duration(hours: 5).inMilliseconds;
    for (final delta in sent) {
      await ownerSvc.ingestSnapshot(delta);
    }
    await drain();
    expect(
      (await hostileRow()).orderedAtMs,
      landedAt,
      reason: 'stamped once on arrival; a re-ship must not restamp it',
    );
    expect(await bodies(), [
      'a minute ago',
      'mine',
      'from the future',
      'nearly now',
    ]);
    // ...and re-reading is a pure re-fold, never a re-stamp: the clock has
    // moved another five hours between these two reads.
    wall = t0 + const Duration(hours: 10).inMilliseconds;
    expect((await hostileRow()).orderedAtMs, landedAt);
    expect(await ownerSvc.unreadOf(gid), 0);

    // It survives a reload from disk, so the arrival moment is persisted and
    // not re-invented per process.
    final reopened = GroupService(s1, _FakeSigner(owner))
      ..debugWallClockMs = () => wall;
    addTearDown(reopened.dispose);
    expect(
      (await reopened.messagesOf(
        gid,
      )).firstWhere((m) => m.body == 'from the future').orderedAtMs,
      landedAt,
    );
    expect(await reopened.unreadOf(gid), 0);

    // A row already on disk from before this rule existed is bounded the
    // next time a peer offers it, not left with its 2027 forever — which is
    // why the arrival moment is recorded OUTSIDE the dedup below it. Stand
    // in for that log by receiving everything on a device whose own clock
    // already reads 2027, so nothing is recorded, then restarting it sane.
    final wire = ownerSvc.snapshotJson((await ownerSvc.load(gid))!);
    final s3 = FakeHvContainer().storage();
    await s3.open(password: 'pw', createIfMissing: true);
    final believed = GroupService(s3, _FakeSigner(owner))
      ..debugWallClockMs = () => hostileTs;
    addTearDown(believed.dispose);
    expect(await believed.ingestSnapshot(wire), isTrue);
    expect(
      (await believed.messagesOf(
        gid,
      )).firstWhere((m) => m.body == 'from the future').orderedAtMs,
      hostileTs,
      reason: 'a device whose own clock says 2027 has no reason to doubt it',
    );
    var restartedWall = t0;
    final restarted = GroupService(s3, _FakeSigner(owner))
      ..debugWallClockMs = () => restartedWall;
    addTearDown(restarted.dispose);
    await restarted.ingestSnapshot(wire);
    final rescued = (await restarted.messagesOf(
      gid,
    )).firstWhere((m) => m.body == 'from the future');
    expect(rescued.createdAtMs, hostileTs);
    expect(
      rescued.orderedAtMs,
      inInclusiveRange(t0, t0 + 1000),
      reason: 'a duplicate the log already held is still bounded',
    );
    restartedWall = t0 + const Duration(hours: 5).inMilliseconds;
    await restarted.ingestSnapshot(wire);
    expect(
      (await restarted.messagesOf(
        gid,
      )).firstWhere((m) => m.body == 'from the future').orderedAtMs,
      rescued.orderedAtMs,
      reason: 'the first observation is the only one that may set it',
    );

    // The bound at the exact millisecond, against a receiver whose arrival
    // moment is pinned: a FRESH service instance (so its monotonic `_now`
    // starts from the held wall clock) taking ONE snapshot. Everything above
    // sits comfortably inside or outside the tolerance; this is the pair
    // that straddles it, one millisecond apart.
    final bobAgain = GroupService(s2, _FakeSigner(bob));
    addTearDown(bobAgain.dispose);
    final tB = t0 + const Duration(days: 2).inMilliseconds;
    var bobAgainWall = tB + kMessageClockSkew.inMilliseconds;
    bobAgain.debugWallClockMs = () => bobAgainWall;
    await bobAgain.postMessage(gid, 'at the bound', broadcast: false);
    bobAgainWall += 1;
    await bobAgain.postMessage(gid, 'one past it', broadcast: false);
    final straddling = bobAgain.snapshotJson((await bobAgain.load(gid))!);

    final s4 = FakeHvContainer().storage();
    await s4.open(password: 'pw', createIfMissing: true);
    final receiver = GroupService(s4, _FakeSigner(owner))
      ..debugWallClockMs = () => tB;
    addTearDown(receiver.dispose);
    expect(await receiver.ingestSnapshot(straddling), isTrue);
    final landed = {for (final m in await receiver.messagesOf(gid)) m.body: m};
    expect(
      landed['from the future']!.orderedAtMs,
      tB,
      reason: 'the arrival moment of this ingest is exactly tB',
    );
    expect(
      landed['at the bound']!.orderedAtMs,
      tB + kMessageClockSkew.inMilliseconds,
      reason: 'an author exactly at the tolerated skew is still believed',
    );
    expect(
      landed['one past it']!.orderedAtMs,
      tB,
      reason: 'one millisecond further is not a clock reading any more',
    );
    expect(
      (await receiver.messagesOf(gid)).map((m) => m.body).toList().sublist(2),
      ['from the future', 'one past it', 'at the bound'],
      reason: 'both bounded rows land at tB, below the believed one',
    );
  });

  test(
    'mirror loop: msgMirror events fold + apply, deduped, deniability-safe',
    () async {
      // Pure fold/codec check of the mirror event vocabulary against the store's
      // dedup contract — the wiring (onMessageStored → postDeviceEvent →
      // deviceIncoming → applyMirroredMessage) is exercised on-device; here we
      // pin the fold that carries it.
      final a = DeviceSyncEvent(
        kind: DeviceSyncKind.msgMirror,
        key: 'm1',
        tsMs: 10,
        payload: const {'peer': 'aa', 'dir': 'incoming', 'body': 'hi'},
      );
      final dup = DeviceSyncEvent(
        kind: DeviceSyncKind.msgMirror,
        key: 'm1',
        tsMs: 10,
        payload: const {'peer': 'aa', 'dir': 'incoming', 'body': 'hi'},
      );
      final b = DeviceSyncEvent(
        kind: DeviceSyncKind.msgMirror,
        key: 'm2',
        tsMs: 20,
        payload: const {'peer': 'aa', 'dir': 'outgoing', 'body': 'yo'},
      );
      final folded = foldDeviceSync([a, dup, b]);
      // One entry per msgId (the mirror key IS the message id → idempotent apply).
      expect(folded.length, 2);
      expect(folded[(DeviceSyncKind.msgMirror, 'm1')]!.payload['body'], 'hi');
      expect(
        folded[(DeviceSyncKind.msgMirror, 'm2')]!.payload['dir'],
        'outgoing',
      );
      // Body codec preserves the mirror payload across the wire.
      expect(DeviceSyncEvent.fromBody(a.toBody())!.payload, a.payload);
    },
  );

  test('device group: link/adopt/revoke lifecycle, hidden + silent', () async {
    Future<void> drain() async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    final sent = <String>[];
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    final primary = GroupService(
      s1,
      _FakeSigner(owner),
      send: (p, g, j) async => sent.add(j),
    );

    // First link creates the device group; the second reuses it (a different
    // device — bob is _id(3), so link _id(4) as the second phone).
    expect(await primary.deviceGroupIdHex(), isNull);
    expect(await primary.linkDevice(bob, sovereign: sovereign), isTrue);
    final gidHex = (await primary.deviceGroupIdHex())!;
    expect(await primary.linkDevice(_id(4), sovereign: sovereign), isTrue);
    expect(await primary.deviceGroupIdHex(), gidHex);
    await drain();

    // Hidden from the user-facing group list despite being a real group…
    expect(
      (await primary.listGroups()).where((g) => g.groupId.hex == gidHex),
      isEmpty,
    );
    // …and linked devices are members; only the sovereign is owner.
    final st = (await primary.stateOf(NodeId.fromHex(gidHex)))!;
    expect(st.roleOf(bob), GroupRole.member);
    expect(st.roleOf(sovereign.nodeId), GroupRole.owner);

    // The NEW device adopts via the handshake id, then sees the same group.
    final s2 = FakeHvContainer().storage();
    await s2.open(password: 'pw', createIfMissing: true);
    final secondary = GroupService(s2, _FakeSigner(bob));
    expect(await secondary.ingestSnapshot(sent.first), isTrue);
    expect(await secondary.adoptDeviceGroup(NodeId.fromHex(gidHex)), isTrue);
    expect(await secondary.deviceGroupIdHex(), gidHex);

    // Sync events round-trip through the device log and fold newest-wins…
    final chat = <String>[];
    final sub = primary.incoming.listen((n) => chat.add(n.message.body));
    expect(
      await secondary.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.settingSet,
          key: 'theme',
          tsMs: 111,
          payload: const {'v': 'dark'},
        ),
      ),
      isTrue,
    );
    final deltas = <String>[];
    final secondary2 = GroupService(
      s2,
      _FakeSigner(bob),
      send: (p, g, j) async => deltas.add(j),
    );
    await secondary2.postDeviceEvent(
      DeviceSyncEvent(
        kind: DeviceSyncKind.settingSet,
        key: 'theme',
        tsMs: 222,
        payload: const {'v': 'light'},
      ),
    );
    await drain();
    for (final d in deltas) {
      await primary.ingestSnapshot(d);
    }
    await drain();
    final folded = await primary.deviceSyncState();
    expect(folded[(DeviceSyncKind.settingSet, 'theme')]!.payload['v'], 'light');
    // …and device-group traffic NEVER feeds the chat notification stream.
    expect(chat, isEmpty);
    await sub.cancel();

    // Revoke removes the device and rotates the epoch.
    final epochBefore = (await primary.stateOf(NodeId.fromHex(gidHex)))!.epoch;
    expect(await primary.revokeDevice(bob, sovereign: sovereign), isTrue);
    final after = (await primary.stateOf(NodeId.fromHex(gidHex)))!;
    expect(after.isMember(bob), isFalse);
    expect(after.epoch, greaterThan(epochBefore));
  });

  test(
    'sovereign genesis tampering is rejected before materialization',
    () async {
      final sent = <String>[];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final primary = GroupService(
        storage,
        _FakeSigner(owner),
        send: (p, g, j) async => sent.add(j),
      );
      expect(await primary.linkDevice(bob, sovereign: sovereign), isTrue);

      final wire = jsonDecode(sent.first) as Map<String, dynamic>;
      final manifest = wire['m'] as Map<String, dynamic>;
      expect(manifest['v'], SpaceManifest.sovereignDeviceVersion);
      expect(manifest['kind'], SpaceManifest.sovereignDeviceKind);
      expect(manifest['alg'], 'ed25519');
      expect(manifest['msig'], isNotEmpty);
      manifest['name'] = ' xveil.devices.tampered';

      final freshStorage = FakeHvContainer().storage();
      await freshStorage.open(password: 'pw', createIfMissing: true);
      final fresh = GroupService(freshStorage, _FakeSigner(bob));
      expect(await fresh.ingestSnapshot(jsonEncode(wire)), isFalse);
      expect(await fresh.listGroups(), isEmpty);
    },
  );

  test(
    'hybrid bundle hash gates snapshot and adopt persists encrypted copy',
    () async {
      final phrase = veil.generateMasterPhrase();
      final encrypted = veil.createHybrid512SovereignBundle(phrase);
      final sourceStorage = FakeHvContainer().storage();
      await sourceStorage.open(password: 'pw', createIfMissing: true);
      await sourceStorage.putSetting(
        GroupService.kSovereignBundleSetting,
        base64Encode(encrypted),
      );
      final source = GroupService(
        sourceStorage,
        _NativeSovereignVerifier(owner),
      );
      final signer = NativeSovereignGroupSigner.openBundle(encrypted, phrase);
      expect(await source.linkDevice(bob, sovereign: signer), isTrue);
      signer.close();

      final gid = NodeId.fromHex((await source.deviceGroupIdHex())!);
      final local = (await source.load(gid))!;
      expect(local.manifest.signatureAlgorithm, 'ed25519+falcon512');
      expect(local.manifest.sovereignBundleHash, hasLength(32));
      expect(local.sovereignBundle, encrypted);
      final snapshot = source.snapshotJson(local);

      final tampered = jsonDecode(snapshot) as Map<String, dynamic>;
      final wireBundle = base64Decode(tampered['s'] as String)..last ^= 1;
      tampered['s'] = base64Encode(wireBundle);
      final targetStorage = FakeHvContainer().storage();
      await targetStorage.open(password: 'pw', createIfMissing: true);
      final target = GroupService(targetStorage, _NativeSovereignVerifier(bob));
      expect(await target.ingestSnapshot(jsonEncode(tampered)), isFalse);
      expect(await target.ingestSnapshot(snapshot), isTrue);
      expect(
        await target.localSovereignBundle(),
        isNull,
        reason: 'a planted snapshot stays inert before explicit adopt',
      );
      expect(await target.adoptDeviceGroup(gid), isTrue);
      expect(await target.localSovereignBundle(), encrypted);

      await expectLater(
        target.openLocalSovereign(veil.generateMasterPhrase()),
        throwsA(anything),
      );
      final reopened = await target.openLocalSovereign(phrase);
      expect(reopened.algorithm, 'ed25519+falcon512');
      expect(reopened.nodeId, local.manifest.owner);
      reopened.close();

      final corruptStorage = FakeHvContainer().storage();
      await corruptStorage.open(password: 'pw', createIfMissing: true);
      await corruptStorage.putSetting(
        GroupService.kSovereignBundleSetting,
        'not-base64%%%',
      );
      final corrupt = GroupService(
        corruptStorage,
        _NativeSovereignVerifier(owner),
      );
      await expectLater(corrupt.openLocalSovereign(phrase), throwsStateError);
      expect(
        await corruptStorage.getSetting(GroupService.kSovereignBundleSetting),
        'not-base64%%%',
        reason: 'corruption must fail closed, never rotate sovereign identity',
      );
    },
    skip: hasVeilFfi ? false : 'set VEIL_FFI_DYLIB to test hybrid XVSB',
  );

  test(
    'sovereign credential lives in the chunked file store, not a setting',
    () async {
      // The hybrid XVSB blob (~3.1 KiB base64) exceeds a single hidden-volume
      // settings record: the settings path threw PayloadTooLarge on EVERY
      // real store (found live 2026-07-25 on the first link ceremony).
      final phrase = veil.generateMasterPhrase();
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _NativeSovereignVerifier(owner));
      final created = await service.openLocalSovereign(phrase);
      created.close();
      expect(
        await storage.loadFile(GroupService.kSovereignBundleSetting),
        isNotNull,
        reason: 'credential must be written to the chunked file store',
      );
      final settingRaw = await storage.getSetting(
        GroupService.kSovereignBundleSetting,
      );
      expect(
        settingRaw == null || settingRaw.isEmpty,
        isTrue,
        reason: 'no oversized settings record may be written',
      );

      // The same phrase reopens the same owner from the file store, and the
      // real link ceremony mints from it.
      final signer = await service.openLocalSovereign(phrase);
      expect(signer.algorithm, 'ed25519+falcon512');
      expect(await service.linkDevice(bob, sovereign: signer), isTrue);
      signer.close();
      expect(await service.deviceGroupIdHex(), isNotNull);

      // A pre-fix store that persisted a small credential in the legacy
      // settings key keeps opening it (read fallback).
      final legacyStorage = FakeHvContainer().storage();
      await legacyStorage.open(password: 'pw', createIfMissing: true);
      final legacyPhrase = veil.generateMasterPhrase();
      final legacyBundle = veil.createHybrid512SovereignBundle(legacyPhrase);
      await legacyStorage.putSetting(
        GroupService.kSovereignBundleSetting,
        base64Encode(legacyBundle),
      );
      final legacy = GroupService(
        legacyStorage,
        _NativeSovereignVerifier(owner),
      );
      expect(await legacy.localSovereignBundle(), legacyBundle);
      final reopened = await legacy.openLocalSovereign(legacyPhrase);
      expect(reopened.algorithm, 'ed25519+falcon512');
      reopened.close();
      await storage.close();
      await legacyStorage.close();
    },
    skip: hasVeilFfi ? false : 'set VEIL_FFI_DYLIB to test hybrid XVSB',
  );

  test(
    'XVRC disaster recovery preserves sovereign node id and mints fresh gid',
    () async {
      final phrase = veil.generateMasterPhrase();
      final sourceStorage = FakeHvContainer().storage();
      await sourceStorage.open(password: 'pw', createIfMissing: true);
      final source = GroupService(
        sourceStorage,
        _NativeSovereignVerifier(owner),
      );

      final exported = await source.exportRecoveryCertificate(phrase);
      expect(
        exported,
        isNotNull,
        reason: 'pre-issuing a certificate provisions XVSB before first link',
      );
      expect(await source.sovereignCredentialKind(), 'phrase');
      expect(
        await source.deviceGroupIdHex(),
        isNull,
        reason: 'pre-issuing a certificate does not create device membership',
      );
      expect(ascii.decode(exported!.certificate.sublist(0, 4)), 'XVRC');

      final recoveredStorage = FakeHvContainer().storage();
      await recoveredStorage.open(password: 'pw', createIfMissing: true);
      final recovered = GroupService(
        recoveredStorage,
        _NativeSovereignVerifier(bob),
      );
      final gid = await recovered.recoverDeviceGroupFromCertificate(
        exported.certificate,
        exported.code,
      );
      expect(gid, isNotNull);
      final bundle = (await recovered.load(gid!))!;
      expect(bundle.manifest.owner, exported.nodeId);
      expect(bundle.manifest.sovereignBundleHash, hasLength(32));
      expect(bundle.sovereignBundle, exported.certificate);
      expect((await recovered.stateOf(gid))!.isMember(bob), isTrue);
      expect(await recovered.sovereignCredentialKind(), 'certificate');

      final reopened = await recovered.openLocalSovereign(exported.code);
      expect(reopened.nodeId, exported.nodeId);
      reopened.close();
      await expectLater(
        recovered.openLocalSovereign(veil.generateSovereignRecoveryCode()),
        throwsA(anything),
      );

      final rotated = await recovered.exportRecoveryCertificate(exported.code);
      expect(rotated, isNotNull);
      expect(rotated!.nodeId, exported.nodeId);
      final rotatedSigner = NativeSovereignGroupSigner.openRecoveryCertificate(
        rotated.certificate,
        rotated.code,
      );
      expect(rotatedSigner.nodeId, exported.nodeId);
      rotatedSigner.close();

      final wrongStorage = FakeHvContainer().storage();
      await wrongStorage.open(password: 'pw', createIfMissing: true);
      final wrong = GroupService(wrongStorage, _NativeSovereignVerifier(bob));
      await expectLater(
        wrong.recoverDeviceGroupFromCertificate(
          exported.certificate,
          veil.generateSovereignRecoveryCode(),
        ),
        throwsA(anything),
      );
      expect(
        await wrong.localSovereignBundle(),
        isNull,
        reason: 'wrong code must fail before persisting any credential',
      );
      expect(await wrong.deviceGroupIdHex(), isNull);

      final rejectedStorage = FakeHvContainer().storage();
      await rejectedStorage.open(password: 'pw', createIfMissing: true);
      final rejected = GroupService(rejectedStorage, _FakeSigner(bob));
      expect(
        await rejected.recoverDeviceGroupFromCertificate(
          exported.certificate,
          exported.code,
        ),
        isNull,
      );
      expect(
        await rejected.localSovereignBundle(),
        isNull,
        reason: 'failed manifest verification rolls back the staged XVRC',
      );
    },
    skip: hasVeilFfi ? false : 'set VEIL_FFI_DYLIB to test XVRC recovery',
  );

  test(
    'guided adoption admits one pinned stranger snapshot then auto-adopts',
    () async {
      final sourceInvite = BootstrapInvite(
        publicKey: Uint8List.fromList(List.filled(32, 21)),
        nonce: Uint8List.fromList([1, 2, 3, 4]),
      );
      final targetInvite = BootstrapInvite(
        publicKey: Uint8List.fromList(List.filled(32, 22)),
        nonce: Uint8List.fromList([4, 3, 2, 1]),
      );
      final sent = <({NodeId peer, String json})>[];
      final sourceStorage = FakeHvContainer().storage();
      await sourceStorage.open(password: 'pw', createIfMissing: true);
      final source = GroupService(
        sourceStorage,
        _FakeSigner(sourceInvite.nodeId),
        send: (peer, _, json) async => sent.add((peer: peer, json: json)),
      );
      final sourceSovereign = _FakeSovereign(_id(9));
      expect(
        await source.linkDevice(
          targetInvite.nodeId,
          sovereign: sourceSovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      expect(
        sent,
        isEmpty,
        reason: 'target has not explicitly admitted it yet',
      );
      final token = await source.createDeviceLinkToken(sourceInvite);
      expect(token, isNotNull);
      final gid = token!.groupId;
      final bundle = (await source.load(gid))!;
      final snapshot = source.snapshotJson(bundle);

      final targetStorage = FakeHvContainer().storage();
      await targetStorage.open(password: 'pw', createIfMissing: true);
      final target = GroupService(
        targetStorage,
        _FakeSigner(targetInvite.nodeId),
      );
      expect(
        await target.ingestSnapshotFromStranger(sourceInvite.nodeId, snapshot),
        isFalse,
        reason: 'a new marker group is inert without scanned consent',
      );
      expect(
        await target.prepareDeviceAdoption(
          DeviceLinkToken(
            groupId: token.groupId,
            source: token.source,
            manifestHash: Uint8List(32),
            sourceInvite: token.sourceInvite,
            expiresAtMs: token.expiresAtMs,
          ),
        ),
        isTrue,
      );
      expect(
        await target.ingestGroupEntry(sourceInvite.nodeId, snapshot),
        isFalse,
        reason: 'the QR pins the exact sovereign-signed manifest',
      );
      expect(await target.prepareDeviceAdoption(token), isTrue);
      expect(
        await target.ingestSnapshotFromStranger(_id(77), snapshot),
        isFalse,
        reason: 'the token pins the source device',
      );

      expect(await source.broadcastDeviceGroup(), 1);
      expect(sent.single.peer, targetInvite.nodeId);
      expect(
        await target.ingestGroupEntry(sourceInvite.nodeId, sent.single.json),
        isTrue,
      );
      expect(await target.deviceGroupIdHex(), gid.hex);
      expect(await target.pendingDeviceAdoption(), isNull);
      expect(
        (await target.stateOf(gid))!.isMember(targetInvite.nodeId),
        isTrue,
      );
    },
  );

  test(
    'device keys and a wrong sovereign cannot mutate the registry',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final primary = GroupService(storage, _FakeSigner(owner));
      expect(await primary.linkDevice(bob, sovereign: sovereign), isTrue);
      final gid = NodeId.fromHex((await primary.deviceGroupIdHex())!);
      final wrong = _FakeSovereign(_id(8));

      expect(await primary.linkDevice(carol, sovereign: wrong), isFalse);
      expect(await primary.revokeDevice(bob, sovereign: wrong), isFalse);
      expect(
        await primary.addControlOp(
          gid,
          ControlOp.addMember,
          target: carol,
          role: GroupRole.member,
        ),
        isFalse,
      );
      final beforeRows = (await primary.load(gid))!.control.length;
      final forged = ControlEntry(
        groupId: gid,
        author: owner,
        seq: 99,
        prevHash: '',
        op: ControlOp.addMember,
        target: carol,
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: 9999,
        signature: Uint8List(0),
      );
      await primary.ingestControl(gid, _FakeSigner(owner).signControl(forged));
      expect((await primary.load(gid))!.control, hasLength(beforeRows));
      final state = (await primary.stateOf(gid))!;
      expect(state.isMember(bob), isTrue);
      expect(state.isMember(carol), isFalse);
    },
  );

  test(
    'legacy device group remints gid and carries compact sync state',
    () async {
      final sent = <String>[];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final legacyGid = _id(43);
      final legacyManifest = SpaceManifest(
        groupId: legacyGid,
        owner: owner,
        genesisPubKey: owner.bytes,
        name: 'Legacy devices',
        createdAtMs: 1000,
      );
      await storage.storeFile(
        'group:${legacyGid.hex}',
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'm': legacyManifest.toJson(),
              'c': const <Object>[],
              'g': const <Object>[],
              'r': const <Object>[],
            }),
          ),
        ),
        name: 'group',
      );
      await storage.putSetting(
        'groups.index',
        jsonEncode(<String>[legacyGid.hex]),
      );
      final builder = GroupService(storage, _FakeSigner(owner));
      expect(
        await builder.addControlOp(
          legacyGid,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      final raw = await storage.loadFile('group:${legacyGid.hex}');
      final legacyJson = jsonDecode(utf8.decode(raw!)) as Map<String, dynamic>;
      (legacyJson['m'] as Map<String, dynamic>)['name'] =
          GroupService.kDeviceGroupName;
      await storage.storeFile(
        'group:${legacyGid.hex}',
        Uint8List.fromList(utf8.encode(jsonEncode(legacyJson))),
        name: 'group',
      );
      await storage.putSetting('devices.gid', legacyGid.hex);
      final legacy = GroupService(storage, _FakeSigner(owner));
      expect(
        await legacy.postDeviceEvent(
          DeviceSyncEvent(
            kind: DeviceSyncKind.settingSet,
            key: 'locale',
            tsMs: 4242,
            payload: const {'v': 'ru'},
          ),
        ),
        isTrue,
      );

      final migrating = GroupService(
        storage,
        _FakeSigner(owner),
        send: (p, g, j) async => sent.add(j),
      );
      expect(
        await migrating.addControlOp(
          legacyGid,
          ControlOp.addMember,
          target: carol,
          role: GroupRole.member,
        ),
        isFalse,
        reason: 'legacy registry is read-only',
      );
      expect(await migrating.linkDevice(carol, sovereign: sovereign), isTrue);
      final newGid = NodeId.fromHex((await migrating.deviceGroupIdHex())!);
      expect(newGid, isNot(legacyGid));

      final oldBundle = (await migrating.load(legacyGid))!;
      final newBundle = (await migrating.load(newGid))!;
      expect(oldBundle.manifest.version, 1);
      expect(oldBundle.control, hasLength(1));
      expect(newBundle.manifest.isSovereignDevice, isTrue);
      expect(newBundle.manifest.owner, sovereign.nodeId);
      expect(
        (await migrating.deviceSyncState())[(
              DeviceSyncKind.settingSet,
              'locale',
            )]!
            .payload['v'],
        'ru',
      );
      final state = (await migrating.stateOf(newGid))!;
      expect(state.isMember(owner), isTrue);
      expect(state.isMember(bob), isTrue);
      expect(state.isMember(carol), isTrue);
      expect(state.roleOf(bob), GroupRole.member);
      expect(sent, isNotEmpty);

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobDevice = GroupService(bobStorage, _FakeSigner(bob));
      final applied = <String>[];
      final sub = bobDevice.deviceIncoming.listen((m) => applied.add(m.body));
      expect(await bobDevice.ingestSnapshot(sent.first), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(
        applied,
        isEmpty,
        reason: 'snapshot is inert before explicit local adoption',
      );
      expect(await bobDevice.adoptDeviceGroup(newGid), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(
        applied
            .map(DeviceSyncEvent.fromBody)
            .whereType<DeviceSyncEvent>()
            .any((e) => e.key == 'locale'),
        isTrue,
      );
      await sub.cancel();
    },
  );

  test('a disposed service posts nothing to the identity it belonged to',
      () async {
    // report21 X21-H2. `dispose()` states its own purpose — "hosts must call
    // this before replacing/closing the active identity so a stale group feed
    // cannot survive an identity switch" — and the writes never consulted it.
    // A sheet or a picker captured before the switch went on posting to the
    // device group of the identity the user had already left, and minting its
    // recovery credential.
    final s = FakeHvContainer().storage();
    await s.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(s, _FakeSigner(owner));
    await svc.linkDevice(bob, sovereign: sovereign);

    // Vacuity: while active the post lands, or the assertions below pass on a
    // service that refuses everything.
    expect(
      await svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.contactUp,
          key: 'while-active',
          tsMs: 1000,
          payload: const {'pin': true},
        ),
      ),
      isTrue,
    );
    final before = await svc.deviceSyncState();

    await svc.dispose();
    expect(svc.isDisposed, isTrue);

    expect(
      await svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.contactUp,
          key: 'after-the-switch',
          tsMs: 2000,
          payload: const {'pin': true},
        ),
      ),
      isFalse,
      reason: 'an event reached the device group of an identity the user had '
          'already left',
    );
    final after = await svc.deviceSyncState();
    expect(
      after.length,
      before.length,
      reason: 'the refusal still appended to the log',
    );

    // And the recovery path, which installs a signer rather than a row.
    expect(
      await svc.recoverDeviceGroupFromCertificate(
        Uint8List.fromList(List<int>.filled(64, 7)),
        'code',
      ),
      isNull,
      reason: 'a recovery sheet completed after the switch installed the old '
          'identity own signer',
    );
  });

  test('postDeviceEvent: concurrent fire-and-forget emits ALL land '
      '(regression: two unawaited posts raced the group log read-modify-write '
      'and the later save dropped the earlier append — caught in the brick-4 '
      'device verify)', () async {
    final s = FakeHvContainer().storage();
    await s.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(s, _FakeSigner(owner));
    await svc.linkDevice(bob, sovereign: sovereign);

    // Fire a burst WITHOUT awaiting each — exactly what the sync taps do.
    final posts = [
      for (var i = 0; i < 5; i++)
        svc.postDeviceEvent(
          DeviceSyncEvent(
            kind: DeviceSyncKind.contactUp,
            key: 'peer$i',
            tsMs: 1000 + i,
            payload: {'pin': i.isEven},
          ),
        ),
    ];
    expect(await Future.wait(posts), everyElement(isTrue));
    final folded = await svc.deviceSyncState();
    for (var i = 0; i < 5; i++) {
      expect(
        folded[(DeviceSyncKind.contactUp, 'peer$i')],
        isNotNull,
        reason: 'emit $i must survive the concurrent burst',
      );
    }
  });

  test('gap-fill (brick G1): a member behind by one LOST delta converges from '
      'the sync-vector exchange; the reply carries ONLY the missing entry and '
      'a non-member vector is dropped silently', () async {
    // Owner + member over separate stores, cross-wired sends.
    final sOwner = FakeHvContainer().storage();
    await sOwner.open(password: 'pw', createIfMissing: true);
    final sBob = FakeHvContainer().storage();
    await sBob.open(password: 'pw', createIfMissing: true);
    final toBob = <String>[], toOwner = <String>[];
    final ownerSvc = GroupService(
      sOwner,
      _FakeSigner(owner),
      send: (p, g, j) async => (p == bob ? toBob : toOwner).add(j),
    );
    final bobSvc = GroupService(
      sBob,
      _FakeSigner(bob),
      send: (p, g, j) async => toOwner.add(j),
    );

    final gid = await ownerSvc.createGroup('g1');
    await ownerSvc.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // Bob joins from the full snapshot.
    for (final j in toBob) {
      await bobSvc.ingestSnapshot(j);
    }
    expect((await bobSvc.messagesOf(gid)).length, 0);

    // A visible post AND a silently-lost one (the outage-class delta).
    await ownerSvc.postMessage(gid, 'delivered');
    await ownerSvc.postMessage(gid, 'lost-in-outage', broadcast: false);
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    toBob.removeRange(0, toBob.length - 1); // keep only the delivered delta
    for (final j in toBob) {
      await bobSvc.ingestSnapshot(j);
    }
    expect(
      (await bobSvc.messagesOf(gid)).length,
      1,
      reason: 'precondition: bob is missing the lost delta',
    );

    // Bob's boot vector reaches the owner → reply carries ONLY the gap.
    toBob.clear();
    final req = (await bobSvc.buildGroupSyncRequest(gid))!;
    expect(await ownerSvc.ingestGroupEntry(bob, jsonEncode(req)), isTrue);
    expect(toBob, hasLength(1), reason: 'one targeted reply');
    final reply = jsonDecode(toBob.single) as Map;
    expect(
      (reply['g'] as List).length,
      1,
      reason: 'only the missing message ships, not the whole log',
    );
    expect(
      reply['ov'],
      isA<String>(),
      reason: 'a repaired content gap continues through the XOR overlay',
    );
    await bobSvc.ingestSnapshot(toBob.single);
    final bodies = (await bobSvc.messagesOf(gid)).map((m) => m.body).toList();
    expect(bodies, containsAll(['delivered', 'lost-in-outage']));

    // In-sync vector → nothing to send. Non-member vector → silent drop.
    toBob.clear();
    final req2 = (await bobSvc.buildGroupSyncRequest(gid))!;
    expect(await ownerSvc.ingestGroupEntry(bob, jsonEncode(req2)), isFalse);
    expect(toBob, isEmpty);
    expect(
      await ownerSvc.ingestGroupEntry(_id(9), jsonEncode(req2)),
      isFalse,
      reason: 'no membership oracle — a stranger gets nothing',
    );
  });

  test(
    'new message rows chain to the exact predecessor inside each visible scope',
    () async {
      final (service, _) = await setup();
      final groupId = await service.createGroup('chained chat');
      expect(await service.postMessage(groupId, 'one'), isTrue);
      expect(await service.postMessage(groupId, 'two'), isTrue);
      final chatRows = (await service.load(groupId))!.messages;
      expect(chatRows, hasLength(2));
      expect(chatRows.first.prevHash, isEmpty);
      expect(chatRows.last.prevHash, groupMessageHash(chatRows.first));

      final spaceId = await service.createSpace('scoped chains');
      final defaultChannel = (await service.channelsOf(
        spaceId,
      )).single.channelId;
      final secondChannel = await service.createChannel(
        spaceId,
        name: 'second',
        kind: SpaceChannelKind.text,
      );
      expect(secondChannel, isNotNull);
      expect(
        await service.postMessage(
          spaceId,
          'default-0',
          channelId: defaultChannel,
        ),
        isTrue,
      );
      expect(
        await service.postMessage(
          spaceId,
          'second-0',
          channelId: secondChannel,
        ),
        isTrue,
      );
      expect(
        await service.postMessage(
          spaceId,
          'default-1',
          channelId: defaultChannel,
        ),
        isTrue,
      );
      final spaceRows = (await service.load(spaceId))!.messages;
      expect(spaceRows.map((message) => message.seq), [0, 1, 2]);
      expect(spaceRows[0].prevHash, isEmpty);
      expect(
        spaceRows[1].prevHash,
        isEmpty,
        reason: 'another channel is an independent visibility scope',
      );
      expect(spaceRows[2].prevHash, groupMessageHash(spaceRows[0]));

      final vector = (await service.buildGroupSyncRequest(spaceId))!;
      // By prefix: the scope now names the device that wrote the chain, and
      // what this asserts is that each channel keeps its OWN chain.
      chainOf(vector['mg'] as Map, '${defaultChannel.hex}|clear');
      chainOf(vector['mg'] as Map, '${secondChannel!.hex}|clear');
    },
  );

  test(
    'out-of-order chained suffix stays hidden until gap-fill supplies predecessor',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(ownerStorage, _FakeSigner(owner));
      final groupId = await ownerService.createGroup('ordered chain');
      expect(
        await ownerService.addControlOp(
          groupId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final base = (await ownerService.load(groupId))!;
      expect(
        await ownerService.postMessage(groupId, 'zero', broadcast: false),
        isTrue,
      );
      expect(
        await ownerService.postMessage(groupId, 'one', broadcast: false),
        isTrue,
      );
      final rows = (await ownerService.load(groupId))!.messages;
      expect(rows[1].prevHash, groupMessageHash(rows[0]));

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobService = GroupService(bobStorage, _FakeSigner(bob));
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(base, recipient: bob),
        ),
        isTrue,
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            base.copyWith(messages: [rows[1]]),
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(await bobService.messagesOf(groupId), isEmpty);
      expect((await bobService.load(groupId))!.messages, hasLength(1));

      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            base.copyWith(messages: [rows[0]]),
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        (await bobService.messagesOf(groupId)).map((message) => message.body),
        ['zero', 'one'],
      );
    },
  );

  test(
    'same-seq message fork quarantines the scoped suffix and converges by sync',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(ownerStorage, _FakeSigner(owner));
      final groupId = await ownerService.createGroup('fork evidence');
      expect(
        await ownerService.addControlOp(
          groupId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      for (final body in ['zero', 'one', 'two']) {
        expect(
          await ownerService.postMessage(groupId, body, broadcast: false),
          isTrue,
        );
      }
      final cleanBundle = (await ownerService.load(groupId))!;
      final original = cleanBundle.messages[1];
      final alternate = _FakeSigner(owner).signMessage(
        GroupMessage(
          groupId: groupId,
          author: owner,
          seq: original.seq,
          prevHash: original.prevHash,
          body: 'fork',
          policyVersion: original.policyVersion,
          createdAtMs: original.createdAtMs + 1,
          signature: Uint8List(0),
        ),
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobService = GroupService(bobStorage, _FakeSigner(bob));
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(cleanBundle, recipient: bob),
        ),
        isTrue,
      );
      expect((await bobService.messagesOf(groupId)), hasLength(3));

      expect(
        await ownerService.ingestSnapshot(
          ownerService.snapshotJson(
            cleanBundle.copyWith(
              messages: [...cleanBundle.messages, alternate],
            ),
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        (await ownerService.messagesOf(groupId)).map((message) => message.body),
        ['zero'],
      );
      expect(
        await ownerService.postMessage(groupId, 'must not extend the fork'),
        isFalse,
      );

      final replies = <String>[];
      final responder = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (peer, gid, wire) async => replies.add(wire),
      );
      final cleanRequest = (await bobService.buildGroupSyncRequest(groupId))!;
      expect(
        await responder.ingestGroupEntry(bob, jsonEncode(cleanRequest)),
        isTrue,
      );
      final evidence = jsonDecode(replies.single) as Map;
      expect(evidence['g'] as List, hasLength(2));
      await bobService.ingestSnapshot(replies.single);
      expect(
        (await bobService.messagesOf(groupId)).map((message) => message.body),
        ['zero'],
      );

      final forkedRequest = (await bobService.buildGroupSyncRequest(groupId))!;
      final fork =
          ((chainOf(forkedRequest['ms'] as Map, 'group|clear')[owner.hex]
                  as Map)['f'])
              as Map;
      expect(fork['s'], 1);
      expect((fork['h'] as List).toSet(), {
        groupMessageHash(original),
        groupMessageHash(alternate),
      });
      replies.clear();
      expect(
        await responder.ingestGroupEntry(bob, jsonEncode(forkedRequest)),
        isFalse,
        reason: 'known fork evidence must not be re-sent forever',
      );
      expect(replies, isEmpty);
    },
  );

  test(
    'gap-fill G1 remainder: a LOST reaction converges from the sync-vector '
    'exchange; a legacy vector without the r-key over-ships but dedups',
    () async {
      final sOwner = FakeHvContainer().storage();
      await sOwner.open(password: 'pw', createIfMissing: true);
      final sBob = FakeHvContainer().storage();
      await sBob.open(password: 'pw', createIfMissing: true);
      final toBob = <String>[], toOwner = <String>[];
      final ownerSvc = GroupService(
        sOwner,
        _FakeSigner(owner),
        send: (p, g, j) async => (p == bob ? toBob : toOwner).add(j),
      );
      final bobSvc = GroupService(
        sBob,
        _FakeSigner(bob),
        send: (p, g, j) async => toOwner.add(j),
      );

      final gid = await ownerSvc.createGroup('g1rx');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await ownerSvc.postMessage(gid, 'react-target');
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      for (final j in toBob) {
        await bobSvc.ingestSnapshot(j);
      }
      expect((await bobSvc.messagesOf(gid)).length, 1);

      // The owner's reaction is stored but its delta is LOST (broadcast off).
      final ref = (await ownerSvc.messagesOf(gid)).last.ref;
      expect(await ownerSvc.react(gid, ref, '🔥', broadcast: false), isTrue);
      expect(
        await bobSvc.reactionsOf(gid),
        isEmpty,
        reason: 'precondition: bob never saw the reaction delta',
      );

      // Bob's boot vector → the reply carries ONLY the missing reaction.
      toBob.clear();
      final req = (await bobSvc.buildGroupSyncRequest(gid))!;
      expect(await ownerSvc.ingestGroupEntry(bob, jsonEncode(req)), isTrue);
      expect(toBob, hasLength(1));
      final reply = jsonDecode(toBob.single) as Map;
      expect(reply['g'] as List, isEmpty, reason: 'messages are in sync');
      expect(reply['c'] as List, isEmpty, reason: 'control is in sync');
      expect(reply['r'] as List, hasLength(1));
      await bobSvc.ingestSnapshot(toBob.single);
      final agg = await bobSvc.reactionsOf(gid);
      expect(agg[ref]?['🔥']?.map((n) => n.hex), contains(owner.hex));

      // Converged → the same exchange now stays silent.
      toBob.clear();
      final req2 = (await bobSvc.buildGroupSyncRequest(gid))!;
      expect(await ownerSvc.ingestGroupEntry(bob, jsonEncode(req2)), isFalse);
      expect(toBob, isEmpty);

      // A LEGACY requester (no 'r' key) gets every reaction re-shipped; the
      // (author, seq) ingest dedup keeps the fold at exactly one reactor.
      final legacy = Map<String, dynamic>.of(req2)..remove('r');
      expect(await ownerSvc.ingestGroupEntry(bob, jsonEncode(legacy)), isTrue);
      expect(toBob, hasLength(1));
      await bobSvc.ingestSnapshot(toBob.single);
      expect(
        (await bobSvc.reactionsOf(gid))[ref]?['🔥']?.length,
        1,
        reason: 'over-shipped reaction dedups by (author, seq)',
      );
    },
  );

  test(
    'gap-fill heals a lost FIRST entry (seq 0) of an author — with the old '
    '0-floor vector semantics it was unrecoverable (latent G1 bug)',
    () async {
      final sOwner = FakeHvContainer().storage();
      await sOwner.open(password: 'pw', createIfMissing: true);
      final sBob = FakeHvContainer().storage();
      await sBob.open(password: 'pw', createIfMissing: true);
      final toBob = <String>[], toOwner = <String>[];
      final ownerSvc = GroupService(
        sOwner,
        _FakeSigner(owner),
        send: (p, g, j) async => (p == bob ? toBob : toOwner).add(j),
      );
      final bobSvc = GroupService(
        sBob,
        _FakeSigner(bob),
        send: (p, g, j) async => toOwner.add(j),
      );

      final gid = await ownerSvc.createGroup('g1seq0');
      await ownerSvc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      for (final j in toBob) {
        await bobSvc.ingestSnapshot(j);
      }

      // Bob's very FIRST message (his seq 0) is lost in an outage.
      await bobSvc.postMessage(gid, 'first-and-lost', broadcast: false);
      expect((await ownerSvc.messagesOf(gid)), isEmpty);

      // The owner's boot vector has never seen bob as a message author — bob's
      // reply must include the seq-0 message (old floor 0 dropped it forever).
      toOwner.clear();
      final req = (await ownerSvc.buildGroupSyncRequest(gid))!;
      expect(
        await bobSvc.ingestGroupEntry(owner, jsonEncode(req)),
        isTrue,
        reason: 'the seq-0 entry IS missing and must ship',
      );
      expect(toOwner, hasLength(1));
      await ownerSvc.ingestSnapshot(toOwner.single);
      expect(
        (await ownerSvc.messagesOf(gid)).map((m) => m.body),
        contains('first-and-lost'),
      );
    },
  );

  test('state-log compaction collapses reaction history, preserves fold and '
      'per-author high-water', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner));
    final gid = await svc.createGroup('compact-rx');
    await svc.postMessage(gid, 'target');
    final ref = (await svc.messagesOf(gid)).single.ref;
    await svc.react(gid, ref, '🔥');
    await svc.react(gid, ref, '🎯');
    await svc.react(gid, ref, '🎯'); // clear
    await svc.react(gid, ref, '❤️');
    final beforeFold = await svc.reactionsOf(gid);
    final beforeVector = (await svc.buildGroupSyncRequest(gid))!['r'] as Map;
    expect((await svc.load(gid))!.reactions, hasLength(4));

    final compacted = (await svc.compactStateLogs(gid))!;
    expect(compacted.reactionsBefore, 4);
    expect(compacted.reactionsAfter, 1);
    expect(await svc.reactionsOf(gid), beforeFold);
    expect(
      (await svc.buildGroupSyncRequest(gid))!['r'],
      beforeVector,
      reason: 'author head keeps the gap-fill high-water at seq 3',
    );

    final freshStorage = FakeHvContainer().storage();
    await freshStorage.open(password: 'pw', createIfMissing: true);
    final fresh = GroupService(freshStorage, _FakeSigner(owner));
    await fresh.ingestSnapshot(svc.snapshotJson((await svc.load(gid))!));
    expect(
      await fresh.reactionsOf(gid),
      beforeFold,
      reason: 'a wiped/fresh device reconstructs the same state',
    );
    expect((await fresh.buildGroupSyncRequest(gid))!['r'], beforeVector);

    await svc.react(gid, ref, '❤️'); // clear after compaction
    expect(
      (await svc.load(gid))!.reactions.last.seq,
      4,
      reason: 'next seq must not rewind after old rows are removed',
    );
  });

  test(
    'the sweep always reaches the device group, whatever the budget',
    () async {
      // It grows fastest — every cloud edit appends to it — so a rotating
      // budget that happens to start elsewhere must not leave it uncompacted.
      // Measured live before this: one pass collapsed nothing while a manual
      // run of the same code collapsed 21 rows.
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(storage, _FakeSigner(owner));
      addTearDown(svc.dispose);
      for (var i = 0; i < 5; i++) {
        await svc.createGroup('Filler $i');
      }
      await svc.linkDevice(bob, sovereign: sovereign);
      final deviceGid = NodeId.fromHex((await svc.deviceGroupIdHex())!);
      for (var i = 0; i < 3; i++) {
        await svc.postDeviceEvent(
          DeviceSyncEvent(
            kind: DeviceSyncKind.settingSet,
            key: 'theme',
            tsMs: i + 1,
            payload: {'v': 'theme-$i'},
          ),
        );
      }
      expect((await svc.load(deviceGid))!.messages, hasLength(3));

      // A budget of one: without the device-group priority this spends the
      // whole pass on a filler group.
      final collapsed = await svc.sweepStateLogCompaction(limit: 1);

      expect(collapsed, greaterThan(0));
      expect(
        (await svc.load(deviceGid))!.messages,
        hasLength(1),
        reason: 'the device group must be compacted by every pass',
      );
    },
  );

  test('the hourly sweep compacts superseded rows, not just boot', () async {
    // Compaction used to run only at boot, and replication ships a bundle
    // WHOLE — so what the log accumulated between restarts was paid on every
    // sync. Measured on the stand: 2748 rows / 173 inline images for nine
    // cloud items, collapsed to 233 / 11 by one pass.
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner));
    addTearDown(svc.dispose);
    await svc.linkDevice(bob, sovereign: sovereign);
    final deviceGid = NodeId.fromHex((await svc.deviceGroupIdHex())!);
    for (var i = 0; i < 4; i++) {
      await svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.settingSet,
          key: 'theme',
          tsMs: i + 1,
          payload: {'v': 'theme-$i'},
        ),
      );
    }
    expect((await svc.load(deviceGid))!.messages, hasLength(4));

    final collapsed = await svc.sweepStateLogCompaction();

    expect(collapsed, greaterThan(0), reason: 'the pass must report its work');
    expect(
      (await svc.load(deviceGid))!.messages,
      hasLength(1),
      reason: 'only the last theme row is not superseded',
    );
  });

  test('device-group compaction keeps LWW winners, unknown future events and '
      'author heads; ordinary chat messages are untouched', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner));
    await svc.linkDevice(bob, sovereign: sovereign);
    final deviceGid = NodeId.fromHex((await svc.deviceGroupIdHex())!);
    for (var i = 0; i < 3; i++) {
      await svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.settingSet,
          key: 'theme',
          tsMs: i + 1,
          payload: {'v': 'theme-$i'},
        ),
      );
    }
    await svc.postMessage(deviceGid, '{"v":2,"k":"futureKind"}');
    final vectorBefore =
        (await svc.buildGroupSyncRequest(deviceGid))!['g'] as Map;
    expect((await svc.load(deviceGid))!.messages, hasLength(4));

    final compacted = (await svc.compactStateLogs(deviceGid))!;
    expect(compacted.messagesBefore, 4);
    expect(
      compacted.messagesAfter,
      2,
      reason: 'theme winner + unknown forward-compatible row',
    );
    expect(
      (await svc.deviceSyncState())[(DeviceSyncKind.settingSet, 'theme')]!
          .payload['v'],
      'theme-2',
    );
    expect((await svc.buildGroupSyncRequest(deviceGid))!['g'], vectorBefore);

    final chatGid = await svc.createGroup('history');
    await svc.postMessage(chatGid, 'one');
    await svc.postMessage(chatGid, 'two');
    final chatResult = (await svc.compactStateLogs(chatGid))!;
    expect(chatResult.messagesBefore, 2);
    expect(
      chatResult.messagesAfter,
      2,
      reason: 'ordinary group history is not state and must not compact',
    );
  });

  test(
    'device-group compaction must not collapse an unresolved note DAG: '
    'every branch of a note is a row under the SAME key (the item id), so a '
    'plain LWW-per-key fold keeps one and drops the concurrent edit',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(storage, _FakeSigner(owner));
      await svc.linkDevice(bob, sovereign: sovereign);
      final deviceGid = NodeId.fromHex((await svc.deviceGroupIdHex())!);

      final root = List.filled(64, 'a').join();
      final left = List.filled(64, 'b').join();
      final right = List.filled(64, 'c').join();
      Future<void> revision(
        String cid,
        int rev,
        int ts,
        List<String> parents,
      ) => svc.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.cloudEntry,
          key: 'note_1',
          tsMs: ts,
          payload: {
            'type': 'note',
            'name': 'n',
            'cid': cid,
            'size': 1,
            'created': 1,
            'rev': rev,
            if (parents.isNotEmpty) 'parents': parents,
          },
        ),
      );
      // Two devices edited the same parent revision while offline.
      await revision(root, 1, 10, const []);
      await revision(left, 2, 20, [root]);
      await revision(right, 2, 30, [root]);

      Future<List<String>> heads() async {
        final rows = (await svc.load(deviceGid))!.messages;
        final folded = foldCloudNoteHeads([
          for (final m in rows) ?DeviceSyncEvent.fromBody(m.body),
        ]);
        return [for (final h in folded['note_1'] ?? const []) h.contentId!];
      }

      expect(
        await heads(),
        unorderedEquals([left, right]),
        reason: 'the DAG fold reports both branches before compaction',
      );

      await svc.compactStateLogs(deviceGid);

      expect(
        await heads(),
        unorderedEquals([left, right]),
        reason: 'compaction must not silently resolve a conflict by timestamp',
      );
    },
  );

  test('device-group compaction collects replica claims whose content no '
      'revision can ask for — the cid in the claim key made every claim a '
      'device ever made immortal', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner));
    await svc.linkDevice(bob, sovereign: sovereign);
    final deviceGid = NodeId.fromHex((await svc.deviceGroupIdHex())!);

    final oldCid = List.filled(64, 'a').join();
    final liveCid = List.filled(64, 'b').join();
    final orphanCid = List.filled(64, 'd').join();
    Future<void> claim(String item, String cid, int ts) => svc.postDeviceEvent(
      DeviceSyncEvent(
        kind: DeviceSyncKind.cloudReplica,
        key: '$item|${bob.hex}|$cid',
        tsMs: ts,
        payload: {'device': bob.hex, 'cid': cid, 'present': true, 'size': 1},
      ),
    );
    Future<void> file(String cid, int rev, int ts) => svc.postDeviceEvent(
      DeviceSyncEvent(
        kind: DeviceSyncKind.cloudEntry,
        key: 'file_1',
        tsMs: ts,
        payload: {
          'type': 'file',
          'name': 'f',
          'cid': cid,
          'size': 1,
          'created': 1,
          'rev': rev,
        },
      ),
    );
    await file(oldCid, 1, 10);
    await file(liveCid, 2, 20);
    await claim('file_1', oldCid, 11);
    await claim('file_1', liveCid, 21);
    // No revision row was ever written for this item: a claim can arrive
    // before the row that explains it, so it must NOT be judged garbage.
    await claim('file_9', orphanCid, 30);

    Future<Set<String>> claimKeys() async {
      final rows = (await svc.load(deviceGid))!.messages;
      return {
        for (final m in rows)
          if (DeviceSyncEvent.fromBody(m.body) case final e?)
            if (e.kind == DeviceSyncKind.cloudReplica) e.key,
      };
    }

    expect(await claimKeys(), hasLength(3));
    await svc.compactStateLogs(deviceGid);
    expect(
      await claimKeys(),
      {'file_1|${bob.hex}|$liveCid', 'file_9|${bob.hex}|$orphanCid'},
      reason: 'the superseded cid is unreachable; the unknown item is not',
    );

    // Deleting the item retires its last claim too: those bytes are gone.
    await svc.postDeviceEvent(
      DeviceSyncEvent(
        kind: DeviceSyncKind.cloudEntry,
        key: 'file_1',
        tsMs: 40,
        payload: {'del': true, 'rev': 3},
      ),
    );
    await svc.compactStateLogs(deviceGid);
    expect(await claimKeys(), {'file_9|${bob.hex}|$orphanCid'});
  });

  test('a linked device stamping itself into the future cannot own a key '
      'forever, and compaction must not delete the honest row it beat '
      '(XV-12)', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    var wall = DateTime(2026, 8, 3).millisecondsSinceEpoch;
    final svc = GroupService(storage, _FakeSigner(owner))
      ..debugWallClockMs = () => wall;
    await svc.linkDevice(bob, sovereign: sovereign);
    final deviceGid = NodeId.fromHex((await svc.deviceGroupIdHex())!);

    Future<void> theme(String value, int tsMs) => svc.postDeviceEvent(
      DeviceSyncEvent(
        kind: DeviceSyncKind.settingSet,
        key: 'theme',
        tsMs: tsMs,
        payload: {'v': value},
      ),
    );
    Future<String?> folded() async =>
        (await svc.deviceSyncState())[(DeviceSyncKind.settingSet, 'theme')]
                ?.payload['v']
            as String?;
    Future<Set<String>> stored() async => {
      for (final m in (await svc.load(deviceGid))!.messages)
        if (DeviceSyncEvent.fromBody(m.body) case final e?)
          if (e.kind == DeviceSyncKind.settingSet) e.payload['v'] as String,
    };

    // A compromised sibling posts one event a year ahead. Under a bare LWW on
    // the author's own timestamp this owns 'theme' until 2027.
    final hostileTs = wall + const Duration(days: 365).inMilliseconds;
    await theme('hostile-a', hostileTs);
    expect(await folded(), isNull, reason: 'nothing has honestly been set yet');

    // Every honest edit after it still lands.
    await theme('dark', wall + 1);
    expect(await folded(), 'dark');
    wall += 60000;
    await theme('light', wall);
    expect(await folded(), 'light');

    // Now the same device posts a second future row, LAST — so it is also this
    // author's high-water row, the one thing compaction protects unconditially.
    // If the future row is allowed to win the key, compaction keeps only that
    // row and the honest edit is deleted from disk, permanently.
    await theme('hostile-b', hostileTs + 1000);
    await svc.compactStateLogs(deviceGid);
    expect(await folded(), 'light');
    expect(
      await stored(),
      containsAll(<String>['light', 'hostile-a', 'hostile-b']),
      reason:
          'the honest winner survives on disk; deferred rows are kept, '
          'never resolved',
    );

    // Deferral, not rejection: once wall clock genuinely reaches the stamps the
    // rows take effect like any other. Nothing was destroyed on the way.
    wall = hostileTs + 2000;
    expect(await folded(), 'hostile-b');

    // The bound is the tolerated skew, not zero: a device a minute fast is
    // believed, so an honestly-skewed sibling loses no edit.
    await theme('skewed', wall + 60000);
    expect(await folded(), 'skewed');
    await theme('beyond', wall + kDeviceSyncClockSkew.inMilliseconds + 60000);
    expect(await folded(), 'skewed', reason: 'past the skew bound, deferred');
  });

  test('nudgeDeviceSync (brick 4e): ships the FULL device-group snapshot to '
      'every other device — the boot catch-up for deltas lost during a total '
      'outage; no-op on a solo install', () async {
    final s = FakeHvContainer().storage();
    await s.open(password: 'pw', createIfMissing: true);
    final sent = <String>[];
    final svc = GroupService(
      s,
      _FakeSigner(owner),
      send: (p, g, j) async => sent.add(j),
    );
    expect(await svc.nudgeDeviceSync(), 0, reason: 'no device group yet');

    await svc.linkDevice(bob, sovereign: sovereign);
    await svc.postDeviceEvent(
      DeviceSyncEvent(
        kind: DeviceSyncKind.settingSet,
        key: 'theme',
        tsMs: 1,
        payload: const {'v': 'dark'},
      ),
    );
    // Let the fire-and-forget link/post broadcasts land before isolating the
    // nudge's own send.
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    sent.clear();
    expect(await svc.nudgeDeviceSync(), 1, reason: 'one other device');
    // The nudge is a FULL snapshot (manifest + control + messages), so a
    // sibling that missed any delta converges from it alone.
    final snap = jsonDecode(sent.single) as Map;
    expect(snap['m'], isNotNull);
    expect((snap['c'] as List), isNotEmpty);
    expect((snap['g'] as List).length, 1, reason: 'carries the missed event');
  });

  test(
    "an own-device seed carries the SIBLING's rows, not only the seeder's",
    () async {
      // The live stand: a freshly linked phone received exactly the
      // master's mirrors and none of the second device's — 15 of 22 rows,
      // deterministically. The master HOLDS the sibling's rows (its chains
      // probe counts both writers); the seed it builds must ship them.
      final primaryStorage = FakeHvContainer().storage();
      await primaryStorage.open(password: 'pw', createIfMissing: true);
      final primary = GroupService(
        primaryStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      expect(
        await primary.linkDevice(
          bob,
          sovereign: sovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      final gid = NodeId.fromHex((await primary.deviceGroupIdHex())!);

      final siblingStorage = FakeHvContainer().storage();
      await siblingStorage.open(password: 'pw', createIfMissing: true);
      final sibling = GroupService(
        siblingStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: bob),
        ),
      );
      expect(
        await sibling.ingestSnapshot(
          primary.snapshotJson(
            (await primary.load(gid))!,
            recipient: bob,
            ownDevice: true,
          ),
        ),
        isTrue,
      );
      expect(await sibling.adoptDeviceGroup(gid), isTrue);

      Future<void> mirror(GroupService svc, int ts, String body) =>
          svc.postDeviceEvent(
            DeviceSyncEvent(
              kind: DeviceSyncKind.msgMirror,
              key: 'chat|$body',
              tsMs: ts,
              payload: {'peer': 'aa', 'dir': 'outgoing', 'body': body},
            ),
          );
      await mirror(primary, 10, 'from-the-master');
      await mirror(sibling, 20, 'from-the-sibling');
      expect(
        await primary.ingestSnapshot(
          sibling.snapshotJson((await sibling.load(gid))!, recipient: owner),
        ),
        isTrue,
      );
      // The master really holds both writers' rows.
      final held = (await primary.load(gid))!.messages
          .map((m) => m.body)
          .toList();
      expect(held.join(), contains('from-the-master'));
      expect(held.join(), contains('from-the-sibling'));

      // The live stand's aggravators, in the live order: a THIRD device was
      // revoked (epoch rotation) and the state logs were compacted before
      // the new device was ever linked.
      final doomed = _id(7);
      expect(
        await primary.linkDevice(
          doomed,
          sovereign: sovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      expect(await primary.revokeDevice(doomed, sovereign: sovereign), isTrue);
      await primary.compactStateLogs(gid);

      // Link a third device and build ITS seed, exactly as seedDevice does.
      expect(
        await primary.linkDevice(
          carol,
          sovereign: sovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      final seed =
          jsonDecode(
                primary.snapshotJson(
                  (await primary.load(gid))!,
                  recipient: carol,
                  ownDevice: true,
                ),
              )
              as Map;
      final shipped = [
        for (final row in (seed['g'] as List? ?? const []))
          (row as Map)['b'] ?? row['body'] ?? jsonEncode(row),
      ].join(' ');
      expect(
        shipped,
        contains('from-the-master'),
        reason: "the seeder's own rows ship",
      );
      expect(
        shipped,
        contains('from-the-sibling'),
        reason: "the sibling's rows are the identity's history too",
      );
    },
  );

  test(
    'the device-group sync serves the writer the flat frontier masked',
    () async {
      // The live 15/22: a linked device that had synced ONE writer's chain
      // asked for the rest with a frontier keyed by AUTHOR — the identity —
      // and the responder read that high-water as covering BOTH writers'
      // independently-numbered chains. The sibling's history was never
      // served. The per-scope vector carries each writer's chain apart.
      final primaryStorage = FakeHvContainer().storage();
      await primaryStorage.open(password: 'pw', createIfMissing: true);
      final replies = <String>[];
      final primary = GroupService(
        primaryStorage,
        _FakeSigner(owner),
        send: (peer, _, json) async {
          if (peer == carol) replies.add(json);
        },
      );
      expect(
        await primary.linkDevice(
          bob,
          sovereign: sovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      final gid = NodeId.fromHex((await primary.deviceGroupIdHex())!);

      final siblingStorage = FakeHvContainer().storage();
      await siblingStorage.open(password: 'pw', createIfMissing: true);
      final sibling = GroupService(siblingStorage, _FakeSigner(bob));
      expect(
        await sibling.ingestSnapshot(
          primary.snapshotJson(
            (await primary.load(gid))!,
            recipient: bob,
            ownDevice: true,
          ),
        ),
        isTrue,
      );
      expect(await sibling.adoptDeviceGroup(gid), isTrue);

      Future<void> mirror(GroupService svc, int ts, String body) =>
          svc.postDeviceEvent(
            DeviceSyncEvent(
              kind: DeviceSyncKind.msgMirror,
              key: 'chat|$body',
              tsMs: ts,
              payload: {'peer': 'aa', 'dir': 'outgoing', 'body': body},
            ),
          );
      // Live arithmetic on purpose: the sibling's chain runs strictly BELOW
      // the master's high-water, with no equal-seq collision — the flat
      // frontier then finds NOTHING missing and sends no reply at all.
      await mirror(primary, 10, 'master-1');
      await mirror(primary, 11, 'master-2');
      await mirror(primary, 12, 'master-3');
      await mirror(sibling, 20, 'sibling-1');
      expect(
        await primary.ingestSnapshot(
          sibling.snapshotJson((await sibling.load(gid))!, recipient: owner),
        ),
        isTrue,
      );

      // The third device, exactly as the stand found it: it holds ONLY the
      // master-writer rows (its first sync collapsed the frontier), and it
      // is a linked member.
      expect(
        await primary.linkDevice(
          carol,
          sovereign: sovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      final full = (await primary.load(gid))!;
      final masterOnly = full.copyWith(
        messages: [
          for (final m in full.messages)
            if (_bytesEqual(m.authorPubKey, owner.bytes) ||
                m.authorPubKey.isEmpty)
              m,
        ],
      );
      final thirdStorage = FakeHvContainer().storage();
      await thirdStorage.open(password: 'pw', createIfMissing: true);
      final third = GroupService(
        thirdStorage,
        _FakeSigner(carol),
      );
      addTearDown(third.dispose);
      expect(
        await third.ingestSnapshot(
          primary.snapshotJson(masterOnly, recipient: carol, ownDevice: true),
        ),
        isTrue,
      );
      expect(await third.adoptDeviceGroup(gid), isTrue);
      final before = (await third.load(gid))!.messages
          .map((m) => m.body)
          .join(' ');
      expect(before, contains('master-1'));
      expect(before, isNot(contains('sibling-1')));

      // The ask-and-serve cycle: the third device's frontier goes to the
      // primary, whose reply must carry the sibling's chain.
      final req = (await third.buildGroupSyncRequest(gid))!;
      replies.clear();
      expect(await primary.handleGroupSyncRequest(carol, req), isTrue);
      for (final wire in replies) {
        await third.ingestSnapshot(wire);
      }
      final after = (await third.load(gid))!.messages
          .map((m) => m.body)
          .join(' ');
      expect(
        after,
        contains('sibling-1'),
        reason: "the masked writer's chain is exactly what the sync is for",
      );
    },
  );

  test('an admission outlives its token until the snapshot arrives', () async {
    // The token's expiry is an ACCEPT-time freshness check; the admission it
    // creates is durable consent. Measured live 2026-08-17: a device that
    // restarted after its ~30-minute token lapsed re-read the pending
    // admission, saw the token expired, and dropped every snapshot chunk as
    // "stranger sync request DENIED" forever — only a full re-link revived
    // the join.
    final sourceInvite = BootstrapInvite(
      publicKey: Uint8List.fromList(List.filled(32, 31)),
      nonce: Uint8List.fromList([1, 2, 3, 4]),
    );
    final targetInvite = BootstrapInvite(
      publicKey: Uint8List.fromList(List.filled(32, 32)),
      nonce: Uint8List.fromList([4, 3, 2, 1]),
    );
    final sourceStorage = FakeHvContainer().storage();
    await sourceStorage.open(password: 'pw', createIfMissing: true);
    final source = GroupService(
      sourceStorage,
      _FakeSigner(sourceInvite.nodeId),
    );
    expect(
      await source.linkDevice(
        targetInvite.nodeId,
        sovereign: _FakeSovereign(_id(9)),
        broadcastSnapshot: false,
      ),
      isTrue,
    );
    final token = (await source.createDeviceLinkToken(sourceInvite))!;

    final targetStorage = FakeHvContainer().storage();
    await targetStorage.open(password: 'pw', createIfMissing: true);
    final target = GroupService(
      targetStorage,
      _FakeSigner(targetInvite.nodeId),
    );
    expect(await target.prepareDeviceAdoption(token), isTrue);

    // The token lapses; the admission must not.
    target.debugWallClockMs = () => token.expiresAtMs + 60 * 60 * 1000; // +1h
    expect(
      await target.pendingDeviceAdoption(),
      isNotNull,
      reason: 'consent survives the token TTL',
    );
    expect(
      await target.allowStrangerGroupSync(token.source, token.groupId.hex),
      isTrue,
      reason: 'the admitted ceremony still opens the door after a restart',
    );

    // But not forever: past the grace the stored consent ages out.
    target.debugWallClockMs = () =>
        token.expiresAtMs +
        GroupService.kDeviceAdoptionAdmissionGrace.inMilliseconds +
        60 * 60 * 1000;
    expect(await target.pendingDeviceAdoption(), isNull);
    expect(
      await target.allowStrangerGroupSync(token.source, token.groupId.hex),
      isFalse,
    );

    // And accept-time freshness is unchanged: an expired token is refused.
    target.debugWallClockMs = () => token.expiresAtMs + 1;
    expect(await target.prepareDeviceAdoption(token), isFalse);
  });

  test(
    'the device-group sync reply is batched under the frame budget',
    () async {
      // Measured live 2026-08-16: a 13.8KB monolithic serve travelled by NO
      // path — the live leg never carried it and the mailbox relay silently
      // dropped the oversized deposit — so the requester stayed short forever
      // while the responder logged a healthy verdict. Batches are the fix;
      // each frame must stand alone and stay well under the deposit budget.
      final primaryStorage = FakeHvContainer().storage();
      await primaryStorage.open(password: 'pw', createIfMissing: true);
      final replies = <String>[];
      final primary = GroupService(
        primaryStorage,
        _FakeSigner(owner),
        send: (peer, _, json) async {
          if (peer == carol) replies.add(json);
        },
      );
      expect(
        await primary.linkDevice(
          carol,
          sovereign: sovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      final gid = NodeId.fromHex((await primary.deviceGroupIdHex())!);
      final filler = 'x' * 400;
      for (var i = 0; i < 25; i++) {
        await primary.postDeviceEvent(
          DeviceSyncEvent(
            kind: DeviceSyncKind.msgMirror,
            key: 'chat|bulk-$i',
            tsMs: 1000 + i,
            payload: {'peer': 'aa', 'dir': 'outgoing', 'body': 'bulk-$i $filler'},
          ),
        );
      }

      final thirdStorage = FakeHvContainer().storage();
      await thirdStorage.open(password: 'pw', createIfMissing: true);
      final third = GroupService(thirdStorage, _FakeSigner(carol));
      addTearDown(third.dispose);
      final empty = (await primary.load(gid))!.copyWith(messages: const []);
      expect(
        await third.ingestSnapshot(
          primary.snapshotJson(empty, recipient: carol, ownDevice: true),
        ),
        isTrue,
      );
      expect(await third.adoptDeviceGroup(gid), isTrue);

      final req = (await third.buildGroupSyncRequest(gid))!;
      replies.clear();
      expect(await primary.handleGroupSyncRequest(carol, req), isTrue);
      expect(
        replies.length,
        greaterThan(1),
        reason: '25 padded rows cannot fit one frame',
      );
      for (final wire in replies) {
        expect(
          wire.length,
          lessThan(6000),
          reason: 'every frame stays under the deposit budget',
        );
        await third.ingestSnapshot(wire);
      }
      final after = (await third.load(gid))!.messages
          .map((m) => m.body)
          .join(' ');
      for (var i = 0; i < 25; i++) {
        expect(after, contains('bulk-$i '), reason: 'row $i arrived');
      }
    },
  );

  test(
    'device-group compaction: a revoked device must not delete the honest row '
    'it beat — reads filter by the current ACL, so the key would vanish',
    () async {
      // Reads answer from `_messagesOfBundle`, which keeps only authors who are
      // members of the CURRENT state. Compaction judged a row by its signature
      // alone, so a revoked device still competed for keys here: when its row
      // won, the honest row it beat was deleted from disk, while the winner
      // stayed invisible to every read (report9 X-18).
      final primaryStorage = FakeHvContainer().storage();
      await primaryStorage.open(password: 'pw', createIfMissing: true);
      final primary = GroupService(primaryStorage, _FakeSigner(owner));
      expect(
        await primary.linkDevice(
          bob,
          sovereign: sovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      final gid = NodeId.fromHex((await primary.deviceGroupIdHex())!);

      final siblingStorage = FakeHvContainer().storage();
      await siblingStorage.open(password: 'pw', createIfMissing: true);
      final sibling = GroupService(siblingStorage, _FakeSigner(bob));
      expect(
        await sibling.ingestSnapshot(
          primary.snapshotJson((await primary.load(gid))!, recipient: bob),
        ),
        isTrue,
      );
      expect(await sibling.adoptDeviceGroup(gid), isTrue);

      // Same key, and the sibling's row is NEWER — so on wall clock it wins.
      const key = 'chat|contested';
      Future<void> post(GroupService svc, int tsMs, String body) =>
          svc.postDeviceEvent(
            DeviceSyncEvent(
              kind: DeviceSyncKind.msgMirror,
              key: key,
              tsMs: tsMs,
              payload: {'peer': 'aa', 'dir': 'outgoing', 'body': body},
            ),
          );
      await post(primary, 10, 'honest');
      // A LATER row on another key, so the contested one is no longer this
      // author's head. `heads` keeps every author's newest row for seq
      // allocation, and with a single row per author both survive whatever the
      // LWW says — which is why a first version of this test passed against
      // the bug.
      await primary.postDeviceEvent(
        DeviceSyncEvent(
          kind: DeviceSyncKind.msgMirror,
          key: 'chat|later',
          tsMs: 30,
          payload: const {'peer': 'bb', 'dir': 'outgoing', 'body': 'later'},
        ),
      );
      await post(sibling, 20, 'from the device that is about to be revoked');
      expect(
        await primary.ingestSnapshot(
          sibling.snapshotJson((await sibling.load(gid))!, recipient: owner),
        ),
        isTrue,
      );

      Future<List<String>> rowsFor(NodeId author) async => [
        for (final m in (await primary.load(gid))!.messages)
          if (m.author == author)
            if (DeviceSyncEvent.fromBody(m.body) case final e?)
              if (e.key == key) e.payload['body'] as String,
      ];
      expect(await rowsFor(owner), ['honest']);
      expect(
        await rowsFor(bob),
        hasLength(1),
        reason: 'the sibling row landed',
      );

      expect(await primary.revokeDevice(bob, sovereign: sovereign), isTrue);
      await primary.compactStateLogs(gid);

      expect(
        await rowsFor(owner),
        ['honest'],
        reason:
            'compaction let a revoked device win the key and deleted the row '
            'that answers it — and the winner is filtered out of every read, '
            'so the key is simply gone',
      );
    },
  );

  test('isMyDevice: true only for current device-group members, and the '
      'cache invalidates on revoke (brick 4c mirror exclusion)', () async {
    final s = FakeHvContainer().storage();
    await s.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(s, _FakeSigner(owner));
    expect(await svc.isMyDevice(bob), isFalse, reason: 'no device group yet');
    await svc.linkDevice(bob, sovereign: sovereign);
    expect(await svc.isMyDevice(bob), isTrue);
    expect(await svc.isMyDevice(_id(9)), isFalse);
    await svc.revokeDevice(bob, sovereign: sovereign);
    expect(
      await svc.isMyDevice(bob),
      isFalse,
      reason: 'revoke must invalidate the cached member set',
    );

    // Group seen mirror: apply is monotonic and never fires the local tap.
    final taps = <(String, int)>[];
    svc.onGroupSeen = (g, ts) => taps.add((g, ts));
    expect(await svc.applyMirroredGroupSeen('aa', 500), isTrue);
    expect(await svc.applyMirroredGroupSeen('aa', 400), isFalse);
    expect(taps, isEmpty, reason: 'apply must not echo into the tap');
  });

  test(
    'isMyDevice cache invalidates when a sibling revoke is ingested',
    () async {
      final primaryStorage = FakeHvContainer().storage();
      await primaryStorage.open(password: 'pw', createIfMissing: true);
      final primary = GroupService(primaryStorage, _FakeSigner(owner));
      expect(
        await primary.linkDevice(
          bob,
          sovereign: sovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      expect(
        await primary.linkDevice(
          carol,
          sovereign: sovereign,
          broadcastSnapshot: false,
        ),
        isTrue,
      );
      final gid = NodeId.fromHex((await primary.deviceGroupIdHex())!);

      final siblingStorage = FakeHvContainer().storage();
      await siblingStorage.open(password: 'pw', createIfMissing: true);
      final sibling = GroupService(siblingStorage, _FakeSigner(carol));
      final initial = primary.snapshotJson(
        (await primary.load(gid))!,
        recipient: carol,
      );
      expect(await sibling.ingestSnapshot(initial), isTrue);
      expect(await sibling.adoptDeviceGroup(gid), isTrue);
      expect(await sibling.isMyDevice(bob), isTrue);

      expect(await primary.revokeDevice(bob, sovereign: sovereign), isTrue);
      final revoked = primary.snapshotJson(
        (await primary.load(gid))!,
        recipient: carol,
      );
      expect(await sibling.ingestSnapshot(revoked), isTrue);
      expect(
        await sibling.isMyDevice(bob),
        isFalse,
        reason: 'an ingested device-control update must invalidate the cache',
      );
    },
  );

  test(
    'postDeviceEvent with an attachment ref authorizes the membership pull '
    '(brick 4b: the cid lands in referencedContentIds of the device group)',
    () async {
      final s = FakeHvContainer().storage();
      await s.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(s, _FakeSigner(owner));
      await svc.linkDevice(bob, sovereign: sovereign);
      final gid = NodeId.fromHex((await svc.deviceGroupIdHex())!);

      expect(
        await svc.postDeviceEvent(
          DeviceSyncEvent(
            kind: DeviceSyncKind.msgMirror,
            key: 'f1',
            tsMs: 5,
            payload: const {
              'peer': 'aa',
              'dir': 'outgoing',
              'body': '📎 report.pdf',
              'cid': 'cafe01',
              'fname': 'report.pdf',
              'fsize': 12345,
            },
          ),
          attachment: const GroupAttachment(
            kind: 'file',
            dataB64: 'AA==',
            w: 1,
            h: 1,
            cid: 'cafe01',
          ),
        ),
        isTrue,
      );
      expect(
        await svc.referencedContentIds(gid),
        contains('cafe01'),
        reason: 'the ref is what lets my other device fetch the bytes',
      );
      // The event still parses as a normal msgMirror with the file payload.
      final msgs = await svc.messagesOf(gid);
      final e = DeviceSyncEvent.fromBody(msgs.last.body)!;
      expect(e.payload['cid'], 'cafe01');
      expect(msgs.last.attachment?.cid, 'cafe01');
    },
  );

  // Auto-broadcast is unawaited (fire-and-forget) — let it drain.
  Future<void> pump() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test(
    'postMessage ships a DELTA (only the new message), not the whole log',
    () async {
      final sent = <String>[];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        send: (peer, gid, json) async => sent.add(json),
      );
      final gid = await svc.createGroup('G');
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await svc.postMessage(gid, 'first');
      await svc.postMessage(gid, 'second');
      await pump();
      // The last send is the delta for 'second' — ONLY that message, no control.
      final last = jsonDecode(sent.last) as Map;
      final bodies = (last['g'] as List)
          .map((m) => (m as Map)['body'])
          .toList();
      expect(bodies, ['second'], reason: 'delta carries only the new message');
      expect(last['c'] as List, isEmpty);
      expect(
        last['m'],
        isNotNull,
        reason: 'manifest rides along for a racing join',
      );
    },
  );

  test(
    'addMember ships a FULL snapshot so a joining member gets history',
    () async {
      final sent = <String>[];
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        send: (peer, gid, json) async => sent.add(json),
      );
      final gid = await svc.createGroup('G');
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await svc.postMessage(gid, 'history');
      await pump();
      sent.clear();
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: carol,
        role: GroupRole.member,
      );
      await pump();
      final snap = jsonDecode(sent.last) as Map;
      final bodies = (snap['g'] as List)
          .map((m) => (m as Map)['body'])
          .toList();
      expect(
        bodies,
        contains('history'),
        reason: 'the full snapshot on join carries the prior log',
      );
    },
  );

  test(
    'Space invite requires explicit consent before membership materializes',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await bobStorage.open(password: 'bob', createIfMissing: true);
      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.accepted),
      );
      await bobStorage.upsertContact(
        Contact(nodeId: owner, status: ContactStatus.accepted),
      );
      late GroupService ownerService;
      late GroupService bobService;
      String? proposalJson;
      ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        sendSpaceInvite: (peer, inviteId, json) async {
          expect(peer, bob);
          proposalJson = json;
          expect(await bobService.receiveSpaceInvite(owner, json), isTrue);
        },
        send: (peer, spaceId, json) async {
          if (peer == bob) {
            expect(await bobService.ingestGroupEntry(owner, json), isTrue);
          }
        },
      );
      bobService = GroupService(
        bobStorage,
        _FakeSigner(bob),
        sendSpaceInviteDecision: (peer, inviteId, json) async {
          expect(peer, owner);
          expect(
            await ownerService.receiveSpaceInviteDecision(bob, json),
            isTrue,
          );
        },
      );
      addTearDown(ownerService.dispose);
      addTearDown(bobService.dispose);

      final spaceId = await ownerService.createSpace('Consent lab');
      final unsolicited = ownerService.snapshotJson(
        (await ownerService.load(spaceId))!,
      );
      expect(
        await bobService.ingestGroupEntry(owner, unsolicited),
        isFalse,
        reason: 'an accepted contact cannot plant a new Space snapshot',
      );
      expect(await bobService.load(spaceId), isNull);

      expect(await ownerService.inviteToSpace(spaceId, bob), isTrue);
      final proposal = jsonDecode(proposalJson!) as Map;
      expect(proposal['space'], spaceId.hex);
      for (final privateField in const ['m', 'c', 'g', 'ke']) {
        expect(proposal, isNot(contains(privateField)));
      }
      expect((await ownerService.stateOf(spaceId))!.isMember(bob), isFalse);
      expect(await bobService.load(spaceId), isNull);
      final pending = await bobService.pendingSpaceInvites();
      expect(pending, hasLength(1));
      expect(pending.single.accepted, isFalse);

      expect(
        await bobService.decideSpaceInvite(
          pending.single.invite.inviteId,
          accept: true,
        ),
        isTrue,
      );
      await pump();
      expect(
        (await ownerService.stateOf(spaceId))!.roleOf(bob),
        GroupRole.member,
      );
      expect(
        (await bobService.stateOf(spaceId))!.roleOf(bob),
        GroupRole.member,
      );
      expect(await bobService.pendingSpaceInvites(), isEmpty);
    },
  );

  test('two Space invites arriving at once do not lose one another', () async {
    // The invite store is read, modified and written back across awaits, so
    // without the mutation gate two concurrent arrivals both start from the
    // same snapshot and the second write erases the first. Tests that await
    // one delivery before starting the next never see it.
    final ownerStorage = FakeHvContainer().storage();
    final bobStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'owner', createIfMissing: true);
    await bobStorage.open(password: 'bob', createIfMissing: true);
    await ownerStorage.upsertContact(
      Contact(nodeId: bob, status: ContactStatus.accepted),
    );
    await bobStorage.upsertContact(
      Contact(nodeId: owner, status: ContactStatus.accepted),
    );
    final captured = <String>[];
    final ownerService = GroupService(
      ownerStorage,
      _FakeSigner(owner),
      // Capture instead of delivering, so both arrivals can be started
      // together rather than one after the other.
      sendSpaceInvite: (peer, inviteId, json) async => captured.add(json),
    );
    final bobService = GroupService(bobStorage, _FakeSigner(bob));
    addTearDown(ownerService.dispose);
    addTearDown(bobService.dispose);

    final first = await ownerService.createSpace('Room one');
    final second = await ownerService.createSpace('Room two');
    expect(await ownerService.inviteToSpace(first, bob), isTrue);
    expect(await ownerService.inviteToSpace(second, bob), isTrue);
    expect(captured.length, 2);

    // Both deliveries in flight at the same time.
    final results = await Future.wait([
      bobService.receiveSpaceInvite(owner, captured[0]),
      bobService.receiveSpaceInvite(owner, captured[1]),
    ]);
    expect(results, [isTrue, isTrue]);

    final pending = await bobService.pendingSpaceInvites();
    expect(
      pending.map((entry) => entry.invite.spaceId).toSet(),
      {first, second},
      reason: 'a concurrent arrival must not erase the one before it',
    );
  });

  test(
    'blocking an inviter invalidates decisions and accepted Space invites',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await bobStorage.open(password: 'bob', createIfMissing: true);
      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.accepted),
      );
      await bobStorage.upsertContact(
        Contact(nodeId: owner, status: ContactStatus.accepted),
      );
      late final GroupService bobService;
      final ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        sendSpaceInvite: (peer, inviteId, json) async {
          expect(peer, bob);
          expect(await bobService.receiveSpaceInvite(owner, json), isTrue);
        },
      );
      bobService = GroupService(
        bobStorage,
        _FakeSigner(bob),
        sendSpaceInviteDecision: (peer, inviteId, json) async {
          expect(peer, owner);
        },
      );
      addTearDown(ownerService.dispose);
      addTearDown(bobService.dispose);

      final acceptedSpace = await ownerService.createSpace('Accepted stale');
      final undecidedSpace = await ownerService.createSpace('Undecided stale');
      expect(await ownerService.inviteToSpace(acceptedSpace, bob), isTrue);
      expect(await ownerService.inviteToSpace(undecidedSpace, bob), isTrue);
      final invitations = await bobService.pendingSpaceInvites();
      final acceptedInvite = invitations.singleWhere(
        (entry) => entry.invite.spaceId == acceptedSpace,
      );
      final undecidedInvite = invitations.singleWhere(
        (entry) => entry.invite.spaceId == undecidedSpace,
      );
      expect(
        await bobService.decideSpaceInvite(
          acceptedInvite.invite.inviteId,
          accept: true,
        ),
        isTrue,
      );

      await bobStorage.upsertContact(
        Contact(nodeId: owner, status: ContactStatus.blocked),
      );
      expect(
        await bobService.decideSpaceInvite(
          undecidedInvite.invite.inviteId,
          accept: true,
        ),
        isFalse,
      );
      expect(await bobService.pendingSpaceInvites(), isEmpty);
      expect(await bobService.spaceMemberships(), isEmpty);

      expect(
        await ownerService.addControlOp(
          acceptedSpace,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await bobService.ingestGroupEntry(
          owner,
          ownerService.snapshotJson(
            (await ownerService.load(acceptedSpace))!,
            recipient: bob,
          ),
        ),
        isFalse,
        reason: 'a late grant cannot revive consent after blocking the inviter',
      );
      expect(await bobService.load(acceptedSpace), isNull);
    },
  );

  test(
    'public discovery payload transfers through a genesis-rooted authority chain',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'owner', createIfMissing: true);
      final service = GroupService(storage, _AuthorityFakeSigner(owner));
      addTearDown(service.dispose);

      final privateSpace = await service.createSpace('Private');
      expect(
        await service.buildSpacePublicDiscoveryPayload(privateSpace),
        isNull,
      );
      final hiddenPublic = await service.createSpace(
        'Not indexed',
        visibility: SpaceVisibility.public,
      );
      expect(
        await service.buildSpacePublicDiscoveryPayload(hiddenPublic),
        isNull,
      );

      final spaceId = await service.createSpace(
        'Public index',
        description: 'Genesis summary',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      final initial = await service.buildSpacePublicDiscoveryPayload(spaceId);
      expect(initial, isNotNull);
      expect(
        initial!.verifyAt(
          initial.descriptor.issuedAtMs,
          _AuthorityFakeSigner(owner).verifyDetached,
        ),
        isTrue,
      );
      expect(initial.descriptor.genesisManifest.groupId, spaceId);
      expect(initial.descriptor.genesisManifest.discoverable, isTrue);
      expect(initial.descriptor.name, 'Public index');
      expect(initial.holder.descriptorHash, initial.descriptor.descriptorHash);
      final wire = utf8.decode(initial.toBytes());
      for (final forbidden in const [
        '"members"',
        '"roles"',
        '"channels"',
        '"categoryId"',
        '"epochEnvelopes"',
      ]) {
        expect(wire, isNot(contains(forbidden)));
      }
      expect(
        SpacePublicDiscoveryPayload.fromBytes(initial.toBytes())?.toJson(),
        initial.toJson(),
      );
      final refreshed = await service.buildSpacePublicDiscoveryPayload(spaceId);
      expect(refreshed, isNotNull);
      expect(
        refreshed!.descriptor.descriptorHash,
        initial.descriptor.descriptorHash,
        reason:
            'periodic holder refresh must not split descriptor quorum by hash',
      );
      expect(
        refreshed.holder.issuedAtMs,
        greaterThan(initial.holder.issuedAtMs),
      );

      expect(
        await service.renameGroup(spaceId, 'Current public index'),
        isTrue,
      );
      expect(
        await service.setSpaceDescription(spaceId, 'Current summary'),
        isTrue,
      );
      final updated = await service.buildSpacePublicDiscoveryPayload(spaceId);
      expect(updated, isNotNull);
      expect(updated!.descriptor.name, 'Current public index');
      expect(updated.descriptor.description, 'Current summary');
      expect(
        updated.descriptor.revision,
        greaterThan(initial.descriptor.revision),
      );
      expect(
        updated.descriptor.descriptorHash,
        isNot(initial.descriptor.descriptorHash),
      );

      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(await service.transferSpaceOwnership(spaceId, bob), isTrue);
      expect(
        await service.buildSpacePublicDiscoveryPayload(spaceId),
        isNull,
        reason: 'the revoked publisher must stop immediately after transfer',
      );
      final nextOwnerService = GroupService(storage, _AuthorityFakeSigner(bob));
      addTearDown(nextOwnerService.dispose);
      final transferredBundle = (await nextOwnerService.load(spaceId))!;
      final transferredFold = foldControlLog(
        owner: transferredBundle.manifest.owner,
        entries: transferredBundle.control,
        verify: _AuthorityFakeSigner(bob).verifyControl,
      );
      expect(transferredFold.state.roleOf(bob), GroupRole.owner);
      final publicAuthority = buildSpacePublicAuthorityChain(
        spaceId: spaceId,
        genesisOwner: transferredBundle.manifest.owner,
        acceptedControl: transferredFold.accepted,
      );
      expect(publicAuthority, isNotNull);
      expect(publicAuthority, hasLength(1));
      expect(await nextOwnerService.createSpaceJoinCode(spaceId), isNotNull);
      final transferred = await nextOwnerService
          .buildSpacePublicDiscoveryPublication(spaceId);
      expect(transferred, isNotNull);
      expect(transferred!.discovery.descriptor.publisher, bob);
      expect(transferred.discovery.descriptor.authorityGeneration, 1);
      expect(transferred.discovery.descriptor.publisherPublicKey, bob.bytes);
      expect(
        transferred.discovery.toBytes().length,
        lessThanOrEqualTo(kSpacePublicDiscoveryPayloadMaxBytes),
      );
      expect(
        transferred.discovery.verifyAt(
          transferred.discovery.holder.issuedAtMs,
          _AuthorityFakeSigner(bob).verifyDetached,
        ),
        isTrue,
      );
      expect(
        SpaceJoinCode.parse(transferred.discovery.descriptor.joinCode).approver,
        bob,
      );
      final transferredWire = utf8.decode(transferred.discovery.toBytes());
      for (final forbidden in const [
        '"members"',
        '"roles"',
        '"channels"',
        '"categoryId"',
        '"epochEnvelopes"',
      ]) {
        expect(transferredWire, isNot(contains(forbidden)));
      }
    },
  );

  test(
    'public holder attests a verified feed projection across edit and delete',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'owner', createIfMissing: true);
      final signer = _FakeSigner(owner);
      final service = GroupService(storage, signer);
      addTearDown(service.dispose);

      final spaceId = await service.createSpace(
        'Projected public feed',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      final root = await service.publishSpacePost(
        spaceId,
        title: 'Root',
        body: 'Original body',
        broadcast: false,
      );
      expect(root, isNotNull);

      final published = await service.buildSpacePublicDiscoveryPublication(
        spaceId,
      );
      expect(published, isNotNull);
      expect(published!.discovery.descriptor.publicPostCount, 1);
      expect(published.feed.posts.single.body, 'Original body');
      expect(
        published.discovery.holder.publicFeedManifestHash,
        published.feed.manifest.manifestHash,
      );
      expect(
        published.feed.verifyAt(
          nowMs: DateTime.now().millisecondsSinceEpoch,
          expectedManifestHash:
              published.discovery.descriptor.publicFeedManifestHash,
          expectedSpaceId: spaceId,
          expectedPublisher: owner,
          publisherPublicKey:
              published.discovery.descriptor.genesisManifest.genesisPubKey,
          expectedControlHeadHash:
              published.discovery.descriptor.controlHeadHash,
          verifySignature: signer.verifyDetached,
          verifyPost: signer.verifyPost,
        ),
        isTrue,
      );
      final publishedHash =
          published.discovery.descriptor.publicFeedManifestHash;
      final publishedRevision =
          published.discovery.descriptor.publicFeedRevision;

      final edited = await service.editSpacePost(
        spaceId,
        root!.postId,
        title: 'Root',
        body: 'Edited body',
        broadcast: false,
      );
      expect(edited?.body, 'Edited body');
      final afterEdit = await service.buildSpacePublicDiscoveryPublication(
        spaceId,
      );
      expect(afterEdit, isNotNull);
      expect(afterEdit!.feed.posts.single.body, 'Edited body');
      expect(
        afterEdit.discovery.descriptor.publicFeedRevision,
        greaterThan(publishedRevision),
      );
      expect(
        afterEdit.discovery.descriptor.publicFeedManifestHash,
        isNot(publishedHash),
      );

      expect(
        await service.deleteSpacePost(spaceId, root.postId, broadcast: false),
        isTrue,
      );
      final afterDelete = await service.buildSpacePublicDiscoveryPublication(
        spaceId,
      );
      expect(afterDelete, isNotNull);
      expect(afterDelete!.feed.posts, isEmpty);
      expect(afterDelete.feed.pages, isEmpty);
      expect(afterDelete.discovery.descriptor.publicPostCount, 0);
      expect(
        afterDelete.discovery.descriptor.publicFeedRevision,
        greaterThan(afterEdit.discovery.descriptor.publicFeedRevision),
      );
      expect(
        afterDelete.discovery.holder.publicFeedManifestHash,
        afterDelete.discovery.descriptor.publicFeedManifestHash,
      );
    },
  );

  test(
    'a fork at the tombstone seq does not resurrect a deleted post',
    () async {
      final storageA = FakeHvContainer().storage();
      await storageA.open(password: 'owner', createIfMissing: true);
      final svcA = GroupService(storageA, _FakeSigner(owner));
      addTearDown(svcA.dispose);
      final storageB = FakeHvContainer().storage();
      await storageB.open(password: 'owner', createIfMissing: true);
      final svcB = GroupService(storageB, _FakeSigner(owner));
      addTearDown(svcB.dispose);

      final spaceId = await svcA.createSpace(
        'Fork tombstone',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      final root = await svcA.publishSpacePost(
        spaceId,
        title: 'Root',
        body: 'Original body',
        broadcast: false,
      );
      expect(root, isNotNull);

      // The same identity's second device adopts the space at publish@0.
      expect(
        await svcB.ingestSnapshot(
          svcA.snapshotJson((await svcA.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );
      expect((await svcB.postsOf(spaceId)).single.body, 'Original body');

      // Partitioned: device A deletes the post while device B edits it. Both
      // rows legitimately land at seq 1 (each saw only head seq 0).
      expect(
        await svcA.deleteSpacePost(spaceId, root!.postId, broadcast: false),
        isTrue,
      );
      expect(await svcA.postsOf(spaceId), isEmpty);
      final editedOnB = await svcB.editSpacePost(
        spaceId,
        root.postId,
        title: 'Root',
        body: 'Edited on device B',
        broadcast: false,
      );
      expect(editedOnB?.body, 'Edited on device B');

      // Merging B's divergent seq-1 row forks the tombstone's seq on A.
      expect(
        await svcA.ingestSnapshot(
          svcB.snapshotJson((await svcB.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );
      final merged = (await svcA.load(spaceId))!;
      expect(
        merged.posts.where((p) => p.seq == 1 && p.author == owner).length,
        greaterThanOrEqualTo(2),
        reason: 'the two devices must actually fork seq 1',
      );

      // A tombstone is absorbing: the delete wins over the forked edit and the
      // publication stays gone instead of resurrecting (and re-granting media).
      expect(await svcA.postsOf(spaceId), isEmpty);
    },
  );

  test(
    'public discussion is explicit, author-signed and committed by feed v2',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'owner', createIfMissing: true);
      final signer = _FakeSigner(owner);
      final service = GroupService(
        storage,
        signer,
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      addTearDown(service.dispose);

      final spaceId = await service.createSpace(
        'Public discussion',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      final post = await service.publishSpacePost(
        spaceId,
        body: 'Public root',
        broadcast: false,
      );
      expect(post, isNotNull);

      expect(
        await service.commentOnSpacePost(
          spaceId,
          post!.postId,
          'Member-private comment',
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          post.postId,
          'Explicit public comment',
          publiclyVisible: true,
          broadcast: false,
        ),
        isTrue,
      );
      final memberComments = await service.spacePostCommentsOf(
        spaceId,
        post.postId,
      );
      final publicRoot = memberComments.singleWhere(
        (comment) => comment.body == 'Explicit public comment',
      );
      expect(
        await service.editSpacePostComment(
          spaceId,
          post.postId,
          publicRoot.ref,
          'Edited public comment',
          broadcast: false,
        ),
        isTrue,
      );

      expect(
        await service.reactToSpacePost(
          spaceId,
          post.postId,
          '🔥',
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await service.reactToSpacePost(
          spaceId,
          post.postId,
          '👍',
          publiclyVisible: true,
          broadcast: false,
        ),
        isTrue,
      );

      final bundle = await service.load(spaceId);
      expect(bundle, isNotNull);
      expect(bundle!.publicComments, hasLength(2));
      expect(bundle.publicComments.first.seq, greaterThan(0));
      expect(bundle.publicComments.last.prevHash, isNotEmpty);
      expect(bundle.publicReactions, hasLength(1));
      expect(bundle.publicReactions.single.seq, greaterThan(0));

      final publication = await service.buildSpacePublicDiscoveryPublication(
        spaceId,
      );
      expect(publication, isNotNull);
      expect(
        publication!.feed.manifest.wireVersion,
        SpacePublicFeedManifest.discussionVersion,
      );
      expect(publication.feed.manifest.discussionItemCount, 3);
      expect(
        publication.feed
            .commentsFor(post.postId, signer.verifyDetached)
            .single
            .body,
        'Edited public comment',
      );
      expect(
        publication.feed.reactionsFor(post.postId, signer.verifyDetached),
        {
          '👍': [owner],
        },
      );
      final publicWire = utf8.decode(
        SpacePublicFeedPackage(
          descriptor: publication.discovery.descriptor,
          projection: publication.feed,
        ).toBytes(),
      );
      expect(publicWire, contains('Edited public comment'));
      expect(publicWire, isNot(contains('Member-private comment')));
      expect(publicWire, isNot(contains('membershipEpoch')));
      expect(publicWire, isNot(contains('"enc"')));
    },
  );

  test(
    'public discussion anti-entropy heals a lost private + public pair',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await bobStorage.open(password: 'bob', createIfMissing: true);
      final ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      late final GroupService bobService;
      bobService = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        send: (peer, groupId, json) async {
          expect(peer, owner);
          expect(await ownerService.ingestGroupEntry(bob, json), isTrue);
        },
      );
      addTearDown(ownerService.dispose);
      addTearDown(bobService.dispose);

      final spaceId = await ownerService.createSpace(
        'Recovered public discussion',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final post = await ownerService.publishSpacePost(
        spaceId,
        body: 'Recovery root',
        broadcast: false,
      );
      expect(post, isNotNull);
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );

      expect(
        await bobService.commentOnSpacePost(
          spaceId,
          post!.postId,
          'Recovered public comment',
          publiclyVisible: true,
          broadcast: false,
        ),
        isTrue,
      );
      expect((await ownerService.load(spaceId))!.publicComments, isEmpty);

      final ownerVector = await ownerService.buildGroupSyncRequest(spaceId);
      expect(ownerVector, isNotNull);
      expect(
        await bobService.handleGroupSyncRequest(owner, ownerVector!),
        isTrue,
      );
      expect((await ownerService.load(spaceId))!.publicComments, hasLength(1));
      expect(
        (await ownerService.buildSpacePublicDiscoveryPublication(spaceId))!.feed
            .commentsFor(post.postId, _FakeSigner(owner).verifyDetached)
            .single
            .body,
        'Recovered public comment',
      );
    },
  );

  test(
    'independent holder fetches exact feed objects before signing availability',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final holderStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await holderStorage.open(password: 'holder', createIfMissing: true);
      late final GroupService holderService;
      final ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        sendPublicFeedChunk: (requester, chunkJson) async {
          expect(requester, bob);
          holderService.handlePublicFeedObjectChunk(owner, chunkJson);
        },
      );
      holderService = GroupService(
        holderStorage,
        _FakeSigner(bob),
        sendPublicFeedRequest: (requestedHolder, requestJson) async {
          expect(requestedHolder, owner);
          await ownerService.handlePublicFeedObjectRequest(bob, requestJson);
        },
      );
      addTearDown(ownerService.dispose);
      addTearDown(holderService.dispose);

      final spaceId = await ownerService.createSpace(
        'Replicated public feed',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      expect(
        await ownerService.publishSpacePost(
          spaceId,
          title: 'Verified',
          body: 'Fetched without a private bundle',
          broadcast: false,
        ),
        isNotNull,
      );
      final ownerPublication = await ownerService
          .buildSpacePublicDiscoveryPublication(spaceId);
      expect(ownerPublication, isNotNull);

      final replicated = await holderService
          .replicateVerifiedPublicSpaceDiscovery(
            ownerPublication!.discovery.descriptor,
            [ownerPublication.discovery.holder],
          );
      expect(replicated, isNotNull);
      expect(replicated!.discovery.holder.holder, bob);
      expect(
        replicated.discovery.holder.descriptorHash,
        ownerPublication.discovery.descriptor.descriptorHash,
      );
      expect(
        replicated.discovery.holder.publicFeedManifestHash,
        ownerPublication.feed.manifest.manifestHash,
      );
      expect(
        replicated.feed.posts.single.body,
        'Fetched without a private bundle',
      );
      expect(await holderService.load(spaceId), isNull);
      expect(
        mergeSpacePublicDiscovery(
          descriptors: [ownerPublication.discovery.descriptor],
          holders: [
            ownerPublication.discovery.holder,
            replicated.discovery.holder,
          ],
          nowMs: DateTime.now().millisecondsSinceEpoch,
          verify: _FakeSigner(owner).verifyDetached,
          minimumIndependentHolders: 2,
        ),
        hasLength(1),
      );

      final restartedStorage = holderStorage;
      final downstreamStorage = FakeHvContainer().storage();
      await downstreamStorage.open(
        password: 'downstream',
        createIfMissing: true,
      );
      late final GroupService downstreamService;
      final restartedHolder = GroupService(
        restartedStorage,
        _FakeSigner(bob),
        sendPublicFeedChunk: (requester, chunkJson) async {
          expect(requester, carol);
          downstreamService.handlePublicFeedObjectChunk(bob, chunkJson);
        },
      );
      downstreamService = GroupService(
        downstreamStorage,
        _FakeSigner(carol),
        sendPublicFeedRequest: (requestedHolder, requestJson) async {
          expect(requestedHolder, bob);
          await restartedHolder.handlePublicFeedObjectRequest(
            carol,
            requestJson,
          );
        },
      );
      addTearDown(restartedHolder.dispose);
      addTearDown(downstreamService.dispose);

      final downstream = await downstreamService
          .replicateVerifiedPublicSpaceDiscovery(
            ownerPublication.discovery.descriptor,
            [replicated.discovery.holder],
          );
      expect(downstream, isNotNull);
      expect(downstream!.discovery.holder.holder, carol);
      expect(
        downstream.feed.manifest.manifestHash,
        ownerPublication.feed.manifest.manifestHash,
        reason:
            'a fresh holder process must serve its still-live durable package',
      );
    },
  );

  // The two tests below were written after a break-check on the public feed
  // transport: deleting the holder's signature check, and deleting the binding
  // that ties a reassembly slot to the holder it was opened for, both left the
  // whole suite green. Neither clause was reachable-but-dead — a test reaches
  // both in a few lines — so what was missing was the test, not the code.
  //
  // Each one first performs the honest fetch and asserts it succeeds. Without
  // that half, a broken harness that fetches nothing at all would satisfy the
  // "must not serve" assertion and the test would prove nothing.
  test('a holder serves nothing for a request it cannot verify', () async {
    final ownerStorage = FakeHvContainer().storage();
    final readerStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'owner', createIfMissing: true);
    await readerStorage.open(password: 'reader', createIfMissing: true);
    var forgeSignature = false;
    var chunksServed = 0;
    late final GroupService readerService;
    final ownerService = GroupService(
      ownerStorage,
      _FakeSigner(owner),
      sendPublicFeedChunk: (requester, chunkJson) async {
        chunksServed++;
        readerService.handlePublicFeedObjectChunk(owner, chunkJson);
      },
    );
    readerService = GroupService(
      readerStorage,
      _FakeSigner(bob),
      sendPublicFeedRequest: (holder, requestJson) async {
        var delivered = requestJson;
        if (forgeSignature) {
          final request = jsonDecode(requestJson) as Map<String, dynamic>;
          // 64 bytes, so the request stays structurally valid and it is the
          // signature check — not the shape check — that has to refuse it.
          request['signature'] = base64Encode(Uint8List(64));
          delivered = jsonEncode(request);
        }
        await ownerService.handlePublicFeedObjectRequest(bob, delivered);
      },
    );
    addTearDown(ownerService.dispose);
    addTearDown(readerService.dispose);

    final spaceId = await ownerService.createSpace(
      'Signature-gated public feed',
      visibility: SpaceVisibility.public,
      discoverable: true,
    );
    expect(
      await ownerService.publishSpacePost(
        spaceId,
        body: 'Served only to a verifiable requester',
        broadcast: false,
      ),
      isNotNull,
    );
    final publication = await ownerService.buildSpacePublicDiscoveryPublication(
      spaceId,
    );
    expect(publication, isNotNull);

    expect(
      await readerService.fetchVerifiedPublicSpaceFeed(
        publication!.discovery.descriptor,
        [publication.discovery.holder],
        objectTimeout: const Duration(milliseconds: 300),
      ),
      isNotNull,
      reason: 'the honest path must work, or the refusal below proves nothing',
    );
    expect(chunksServed, greaterThan(0));

    forgeSignature = true;
    chunksServed = 0;
    expect(
      await readerService.fetchVerifiedPublicSpaceFeed(
        publication.discovery.descriptor,
        [publication.discovery.holder],
        objectTimeout: const Duration(milliseconds: 300),
      ),
      isNull,
    );
    expect(
      chunksServed,
      isZero,
      reason:
          'a forged signature must be refused before anything is sent, not '
          'after — the requester public key is bound to the identity by '
          'nothing else',
    );
  });

  test('a chunk from a node other than the asked holder is ignored', () async {
    final ownerStorage = FakeHvContainer().storage();
    final readerStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'owner', createIfMissing: true);
    await readerStorage.open(password: 'reader', createIfMissing: true);
    var impersonateHolder = false;
    late final GroupService readerService;
    final ownerService = GroupService(
      ownerStorage,
      _FakeSigner(owner),
      sendPublicFeedChunk: (requester, chunkJson) async {
        // Byte-identical chunks, correct nonce, correct hashes — the only
        // thing wrong is who hands them over.
        readerService.handlePublicFeedObjectChunk(
          impersonateHolder ? carol : owner,
          chunkJson,
        );
      },
    );
    readerService = GroupService(
      readerStorage,
      _FakeSigner(bob),
      sendPublicFeedRequest: (holder, requestJson) async {
        await ownerService.handlePublicFeedObjectRequest(bob, requestJson);
      },
    );
    addTearDown(ownerService.dispose);
    addTearDown(readerService.dispose);

    final spaceId = await ownerService.createSpace(
      'Holder-bound reassembly',
      visibility: SpaceVisibility.public,
      discoverable: true,
    );
    expect(
      await ownerService.publishSpacePost(
        spaceId,
        body: 'Only the holder we asked may answer',
        broadcast: false,
      ),
      isNotNull,
    );
    final publication = await ownerService.buildSpacePublicDiscoveryPublication(
      spaceId,
    );
    expect(publication, isNotNull);

    expect(
      await readerService.fetchVerifiedPublicSpaceFeed(
        publication!.discovery.descriptor,
        [publication.discovery.holder],
        objectTimeout: const Duration(milliseconds: 300),
      ),
      isNotNull,
      reason: 'the honest path must work, or the refusal below proves nothing',
    );

    impersonateHolder = true;
    expect(
      await readerService.fetchVerifiedPublicSpaceFeed(
        publication.discovery.descriptor,
        [publication.discovery.holder],
        objectTimeout: const Duration(milliseconds: 300),
      ),
      isNull,
      reason:
          'a pending slot belongs to the one holder it was opened for; any '
          'other node that learns the nonce must not be able to fill it',
    );
  });

  test(
    'a FOLLOWED public Space cannot stamp itself into the future either: the '
    'bound is recorded once beside the verified package, never inside it',
    () async {
      Future<void> pump() async {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      final ownerStorage = FakeHvContainer().storage();
      final memberStorage = FakeHvContainer().storage();
      final readerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await memberStorage.open(password: 'member', createIfMissing: true);
      await readerStorage.open(password: 'reader', createIfMissing: true);
      final t0 = DateTime.utc(2026, 8, 3, 12).millisecondsSinceEpoch;
      final hostileTs = t0 + const Duration(days: 365).inMilliseconds;

      var ownerWall = t0 - const Duration(hours: 1).inMilliseconds;
      var readerWall = t0 + 2000;
      late GroupService readerService;
      final ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        sendPublicFeedChunk: (requester, chunkJson) async {
          readerService.handlePublicFeedObjectChunk(owner, chunkJson);
        },
      )..debugWallClockMs = () => ownerWall;
      readerService = GroupService(
        readerStorage,
        _FakeSigner(bob),
        sendPublicFeedRequest: (holder, requestJson) async {
          await ownerService.handlePublicFeedObjectRequest(bob, requestJson);
        },
      )..debugWallClockMs = () => readerWall;
      addTearDown(ownerService.dispose);
      addTearDown(readerService.dispose);

      // The Space, and carol's membership in it, predate the window under
      // test: a member cannot publish dated before its own admission.
      final spaceId = await ownerService.createSpace(
        'Followed public Space',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: carol,
          role: GroupRole.member,
        ),
        isTrue,
      );
      ownerWall = t0;
      expect(
        await ownerService.publishSpacePost(
          spaceId,
          body: 'an honest one',
          broadcast: false,
        ),
        isNotNull,
      );

      // The reachable attack, and it is sharper than a wrong clock. A member
      // publishes at an ordinary `created` and simply signs `published` a year
      // ahead of it. `isStructurallyValid` permits exactly that, and every
      // freshness gate in the public pipeline — the descriptor's `issuedAt`,
      // the feed manifest's `updatedAt`, their expiry windows — is computed
      // from `created`, so this row sails through all of them untouched and
      // lands on a follower's Feed with a 2027 rank.
      final memberSvc = GroupService(memberStorage, _FakeSigner(carol))
        ..debugWallClockMs = () => t0;
      addTearDown(memberSvc.dispose);
      expect(
        await memberSvc.ingestSnapshot(
          ownerService.snapshotJson((await ownerService.load(spaceId))!),
        ),
        isTrue,
      );
      expect(
        await memberSvc.publishSpacePost(
          spaceId,
          body: 'from the future',
          broadcast: false,
        ),
        isNotNull,
      );
      final crafted =
          jsonDecode(memberSvc.snapshotJson((await memberSvc.load(spaceId))!))
              as Map<String, dynamic>;
      var rewrote = 0;
      for (final row in crafted['p'] as List) {
        if ((row as Map)['body'] == 'from the future') {
          row['published'] = hostileTs;
          rewrote++;
        }
      }
      expect(rewrote, 1);
      ownerWall = t0 + 1000;
      expect(await ownerService.ingestSnapshot(jsonEncode(crafted)), isTrue);
      expect(
        (await ownerService.load(
          spaceId,
        ))!.posts.map((post) => post.publishedAtMs),
        contains(hostileTs),
        reason:
            'a `published` a year past `created` is structurally valid and '
            'is stored exactly as signed',
      );

      // The follower's own clock has to stay within the public skew of the
      // publisher's for the fetch itself to be served at all, so both move
      // together below.
      Future<void> follow() async {
        final publication = await ownerService
            .buildSpacePublicDiscoveryPublication(spaceId);
        expect(publication, isNotNull);
        expect(
          await readerService.subscribeToPublicSpace(
            publication!.discovery.descriptor,
            [publication.discovery.holder],
          ),
          isNotNull,
        );
        await pump();
      }

      Future<SpacePostView> followedPost(String body) async =>
          (await readerService.publicSpaceSubscription(
            spaceId,
          ))!.feed.posts.firstWhere((post) => post.body == body);

      await follow();
      expect(
        await readerService.load(spaceId),
        isNull,
        reason: 'a follower holds no membership authority, only a snapshot',
      );

      final hostile = await followedPost('from the future');
      expect(
        hostile.publishedAtMs,
        hostileTs,
        reason: 'the publisher signed this and it is served as signed',
      );
      final landedAt = hostile.orderedAtMs;
      expect(
        landedAt,
        inInclusiveRange(readerWall, readerWall + 1000),
        reason: 'ordered by the one time the follower actually knows',
      );
      final honest = await followedPost('an honest one');
      expect(
        honest.orderedAtMs,
        honest.publishedAtMs,
        reason: 'an ordinary publication keeps its own word, untouched',
      );
      expect(honest.publishedAtMs, inInclusiveRange(t0, t0 + 1000));

      // The badge. `markSpaceFeedSeen` takes the MAX cursor over the posts
      // themselves, so a 2027 publication used to write a 2027 watermark and
      // silently retire this Space's badge until that future arrived.
      expect(await readerService.unreadSpacePosts(spaceId), 2);
      await readerService.markSpaceFeedSeen(spaceId);
      expect(await readerService.unreadSpacePosts(spaceId), 0);

      ownerWall = t0 + 3000;
      expect(
        await ownerService.publishSpacePost(
          spaceId,
          body: 'a later honest one',
          broadcast: false,
        ),
        isNotNull,
      );
      readerWall = t0 + 4000;
      await follow();
      expect(
        await readerService.unreadSpacePosts(spaceId),
        1,
        reason:
            'a publisher cannot retire a follower\'s badge by claiming '
            'to be in 2027',
      );
      expect(
        (await readerService.unreadSpacePostViews(spaceId)).single.body,
        'a later honest one',
      );
      expect(
        (await readerService.spaceFeed())
            .map((item) => item.post.body)
            .toList(),
        ['a later honest one', 'from the future', 'an honest one'],
        reason:
            'newest first, with the 2027 publication at the moment it was '
            'actually handed over — not at the top forever',
      );

      // ONCE. A subscription is re-fetched and re-verified on every refresh
      // against a clock that has moved on; only the first sighting may set the
      // bound, or the post would walk down the Feed on each refresh — and the
      // Feed pages on exactly this order.
      ownerWall = t0 + const Duration(minutes: 15).inMilliseconds;
      expect(
        await ownerService.publishSpacePost(
          spaceId,
          body: 'and another',
          broadcast: false,
        ),
        isNotNull,
      );
      // A quarter of an hour on: far enough that a re-derived bound would be
      // unmistakable, and still close enough to the publisher that the fetch
      // is served.
      readerWall = t0 + const Duration(minutes: 16).inMilliseconds;
      await follow();
      expect(
        (await followedPost('from the future')).orderedAtMs,
        landedAt,
        reason: 'bound on first sight; a refresh must not re-stamp it',
      );
      expect(
        (await readerService.spaceFeed())
            .map((item) => item.post.body)
            .toList(),
        [
          'and another',
          'a later honest one',
          'from the future',
          'an honest one',
        ],
      );

      // Where the bound lives: beside the verified package in the follower's
      // OWN stored snapshot, never inside the signed bytes it verifies.
      final snapshotBytes = await readerStorage.loadFile(
        'space-public-subscription:${spaceId.hex}',
      );
      expect(snapshotBytes, isNotNull);
      final stored = jsonDecode(utf8.decode(snapshotBytes!)) as Map;
      expect(
        stored['prx'],
        hasLength(1),
        reason: 'one entry, for the one publication that needed bounding',
      );
      expect((stored['prx'] as Map).values.single, landedAt);
      // Asked of the decoded KEYS, not of the serialized text: a signature is
      // base64 of random-looking bytes, so a substring search for a three-
      // character field name fires on roughly one run in a thousand for
      // reasons that have nothing to do with this rule.
      bool carriesKey(Object? node, String key) => node is Map
          ? node.containsKey(key) ||
                node.values.any((value) => carriesKey(value, key))
          : node is List && node.any((value) => carriesKey(value, key));
      expect(
        carriesKey(stored['package'], 'prx'),
        isFalse,
        reason: 'nothing local is inside the bytes the publisher signed',
      );
      final snapshot = SpacePublicSubscriptionSnapshot.fromBytes(
        Uint8List.fromList(snapshotBytes),
      );
      expect(snapshot, isNotNull);
      expect(
        snapshot!.package.projection.pages
            .expand((page) => page.posts)
            .map((post) => post.root.publishedAtMs),
        contains(hostileTs),
        reason: 'what is on disk is what the publisher signed',
      );
      expect(
        snapshot.postReceipts,
        {
          for (final entry in (stored['prx'] as Map).entries)
            '${entry.key}': entry.value,
        },
        reason: 'the bound round-trips through the local file',
      );
      expect(
        stored.keys.toSet(),
        {'v', 'kind', 'verifiedAt', 'package', 'prx'},
        reason: 'exactly one new local key, outside the verified package',
      );
      // ...and it survives a restart, so it is persisted, not re-invented —
      // and is still accepted, so a local observation can never fail the
      // signature check the stored snapshot has to pass to be read back.
      final reopened = GroupService(readerStorage, _FakeSigner(bob))
        ..debugWallClockMs = () => t0 + const Duration(days: 2).inMilliseconds;
      addTearDown(reopened.dispose);
      expect(
        (await reopened.publicSpaceSubscription(spaceId))!.feed.posts
            .firstWhere((post) => post.body == 'from the future')
            .orderedAtMs,
        landedAt,
      );
    },
  );

  test(
    'public-only subscription persists verified feed without membership authority',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final readerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await readerStorage.open(password: 'reader', createIfMissing: true);
      late GroupService readerService;
      final ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        sendPublicFeedChunk: (requester, chunkJson) async {
          expect(requester, bob);
          readerService.handlePublicFeedObjectChunk(owner, chunkJson);
        },
      );
      readerService = GroupService(
        readerStorage,
        _FakeSigner(bob),
        sendPublicFeedRequest: (holder, requestJson) async {
          expect(holder, owner);
          await ownerService.handlePublicFeedObjectRequest(bob, requestJson);
        },
        sendSpaceAbuseReport: (reviewer, reportId, reportJson) async {
          expect(reviewer, owner);
          expect(reportId, isNotEmpty);
          if (!await ownerService.receiveSpaceAbuseReport(bob, reportJson)) {
            throw StateError('public-only abuse report rejected');
          }
        },
      );
      addTearDown(ownerService.dispose);
      final publicNotices = <({NodeId spaceId, SpacePostView post})>[];
      final publicNoticeSub = readerService.incomingPublicPosts.listen(
        publicNotices.add,
      );
      final publicCommentNotices =
          <({NodeId spaceId, SpacePublicCommentView comment})>[];
      final publicCommentNoticeSub = readerService.incomingPublicComments
          .listen(publicCommentNotices.add);
      addTearDown(publicNoticeSub.cancel);
      addTearDown(publicCommentNoticeSub.cancel);
      addTearDown(() async {
        if (!identical(readerService, ownerService)) {
          await readerService.dispose();
        }
      });

      const mediaCid =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final spaceId = await ownerService.createSpace(
        'Read-only public Space',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      final root = await ownerService.publishSpacePost(
        spaceId,
        body: 'Signed public publication for an outsider',
        media: [
          const MediaObject(
            kind: 'image',
            contentId: mediaCid,
            name: 'public.png',
            size: 3,
          ),
        ],
        broadcast: false,
      );
      expect(root, isNotNull);
      final first = await ownerService.buildSpacePublicDiscoveryPublication(
        spaceId,
      );
      expect(first, isNotNull);
      expect(
        await ownerService.editSpacePost(
          spaceId,
          root!.postId,
          title: '',
          body: 'Latest owner-committed public publication',
          broadcast: false,
        ),
        isNotNull,
      );
      final current = await ownerService.buildSpacePublicDiscoveryPublication(
        spaceId,
      );
      expect(current, isNotNull);

      final subscribed = await readerService.subscribeToPublicSpace(
        current!.discovery.descriptor,
        [current.discovery.holder],
      );
      expect(subscribed, isNotNull);
      expect(subscribed!.subscription.publicOnly, isTrue);
      expect(
        publicNotices,
        isEmpty,
        reason: 'initial imported history must not create an alert storm',
      );
      expect(subscribed.feed.posts.single.body, contains('Latest'));
      expect(await readerService.load(spaceId), isNull);
      expect(
        await readerStorage.getSetting('groups.index'),
        anyOf(isNull, isNot(contains(spaceId.hex))),
        reason: 'read-only subscription must not create a GroupBundle index',
      );
      expect(
        (await readerService.spaceFeed()).every((item) => item.publicOnly),
        isTrue,
      );
      expect((await readerService.spaceFeed()).single.canManagePosts, isFalse);
      expect(await readerService.unreadSpacePosts(spaceId), 1);
      await readerService.markSpaceFeedSeen(spaceId);
      expect(await readerService.unreadSpacePosts(spaceId), 0);
      expect(
        await readerService.reportSpaceContent(
          spaceId,
          root.postId,
          category: SpaceAbuseCategory.misinformation,
          details: 'Please review this public-only projection.',
        ),
        isTrue,
      );
      final publicOnlyReports = await ownerService.incomingSpaceAbuseReports(
        spaceId: spaceId,
        pendingOnly: true,
      );
      expect(publicOnlyReports, hasLength(1));
      expect(publicOnlyReports.single.report.reporter, bob);
      expect(publicOnlyReports.single.report.reviewer, owner);
      expect(publicOnlyReports.single.report.postId, root.postId);

      expect(
        await ownerService.commentOnSpacePost(
          spaceId,
          root.postId,
          'Public comment for ${encodeMessageMention(bob)}',
          publiclyVisible: true,
          broadcast: false,
        ),
        isTrue,
      );
      final withComment = await ownerService
          .buildSpacePublicDiscoveryPublication(spaceId);
      expect(withComment, isNotNull);
      expect(
        await readerService.subscribeToPublicSpace(
          withComment!.discovery.descriptor,
          [withComment.discovery.holder],
        ),
        isNotNull,
      );
      await pump();
      expect(publicNotices, isEmpty);
      expect(publicCommentNotices, hasLength(1));
      expect(publicCommentNotices.single.spaceId, spaceId);
      expect(
        publicCommentNotices.single.comment.body,
        contains(encodeMessageMention(bob)),
      );
      expect(
        await readerService.publicSpacePostComments(spaceId, root.postId),
        hasLength(1),
      );
      expect(
        await readerService.spaceFeed(
          filter: SpaceFeedFilter(
            types: SpacePostType.values.toSet(),
            mentionsOnly: true,
          ),
        ),
        hasLength(1),
        reason:
            'a public comment mention keeps its root visible in mentions-only Feed',
      );

      await readerService.updateSpaceSubscription(
        spaceId,
        feedEnabled: false,
        notificationsEnabled: false,
        commentNotifications: SpaceCommentNotificationMode.all,
        hiddenFromRecommendations: true,
      );
      expect(await readerService.spaceFeed(), isEmpty);
      final preferences = await readerService.spaceSubscription(spaceId);
      expect(preferences.publicOnly, isTrue);
      expect(preferences.feedEnabled, isFalse);
      expect(preferences.notificationsEnabled, isFalse);
      expect(
        preferences.commentNotifications,
        SpaceCommentNotificationMode.all,
      );
      expect(preferences.hiddenFromRecommendations, isTrue);
      await readerService.setSpaceFeedEnabled(spaceId, true);
      await readerService.setSpaceFeedPostHidden(spaceId, root.postId, true);
      expect(await readerService.spaceFeed(), isEmpty);
      await readerService.setSpaceFeedPostHidden(spaceId, root.postId, false);
      expect(await readerService.spaceFeed(), hasLength(1));

      final mentioned = await ownerService.publishSpacePost(
        spaceId,
        body: 'New verified root for ${encodeMessageMention(bob)}',
        broadcast: false,
      );
      expect(mentioned, isNotNull);
      final refreshed = await ownerService.buildSpacePublicDiscoveryPublication(
        spaceId,
      );
      expect(refreshed, isNotNull);
      expect(
        await readerService.subscribeToPublicSpace(
          refreshed!.discovery.descriptor,
          [refreshed.discovery.holder],
        ),
        isNotNull,
      );
      await pump();
      expect(publicNotices, hasLength(1));
      expect(publicNotices.single.spaceId, spaceId);
      expect(publicNotices.single.post.postId, mentioned!.postId);
      expect(await readerService.unreadSpacePosts(spaceId), 1);

      expect(
        await readerService.subscribeToPublicSpace(
          first!.discovery.descriptor,
          [first.discovery.holder],
        ),
        isNull,
        reason: 'a still-valid signed older feed must not roll back the view',
      );

      final snapshotBytes = await readerStorage.loadFile(
        'space-public-subscription:${spaceId.hex}',
      );
      final snapshot = SpacePublicSubscriptionSnapshot.fromBytes(
        snapshotBytes!,
      );
      expect(snapshot, isNotNull);
      final persisted = snapshot!.toJson();
      expect(persisted.keys, {'v', 'kind', 'verifiedAt', 'package'});
      final package = persisted['package'] as Map;
      expect(package.keys, {
        'v',
        'kind',
        'descriptor',
        'manifest',
        'pages',
        'discussionPages',
      });
      final wire = jsonEncode(persisted);
      for (final privateField in [
        '"members"',
        '"roles"',
        '"channels"',
        '"epochEnvelopes"',
        '"channelEpoch"',
      ]) {
        expect(wire, isNot(contains(privateField)));
      }

      await readerStorage.storeFile(
        mediaCid,
        Uint8List.fromList([1, 2, 3]),
        name: 'public.png',
      );
      expect(
        (await readerService.sweepSharedContentGarbage(
          gracePeriod: Duration.zero,
        )).purged,
        0,
        reason: 'active public projection is a shared-CID GC root',
      );

      await readerService.dispose();
      readerService = GroupService(readerStorage, _FakeSigner(bob));
      final reopened = await readerService.publicSpaceSubscription(spaceId);
      expect(reopened, isNotNull);
      expect(reopened!.subscription.publicOnly, isTrue);
      expect(reopened.subscription.notificationsEnabled, isFalse);
      expect(
        reopened.feed.posts.any((post) => post.body.contains('Latest')),
        isTrue,
      );
      expect(
        (await readerService.spaceFeed()).every((item) => item.publicOnly),
        isTrue,
      );
      expect(await readerService.load(spaceId), isNull);

      final tamperedJson =
          jsonDecode(utf8.decode(snapshotBytes)) as Map<String, dynamic>;
      final tamperedPackage = tamperedJson['package'] as Map;
      final pages = tamperedPackage['pages'] as List;
      final projected = ((pages.single as Map)['posts'] as List).first as Map;
      (projected['effective'] as Map)['body'] = 'forged offline body';
      await readerStorage.storeFile(
        'space-public-subscription:${spaceId.hex}',
        Uint8List.fromList(utf8.encode(jsonEncode(tamperedJson))),
        name: 'tampered-public-space-subscription',
      );
      await readerService.dispose();
      readerService = GroupService(readerStorage, _FakeSigner(bob));
      expect(await readerService.publicSpaceSubscription(spaceId), isNull);
      expect(await readerService.spaceFeed(), isEmpty);

      expect(await readerService.unsubscribeFromPublicSpace(spaceId), isTrue);
      expect(await readerService.publicSpaceSubscriptions(), isEmpty);
      expect(
        (await readerService.sweepSharedContentGarbage(
          gracePeriod: Duration.zero,
        )).purged,
        1,
      );
      expect(await readerStorage.hasFile(mediaCid), isFalse);
    },
  );

  test(
    'public media grant requires an exact cached verified projection',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final readerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await readerStorage.open(password: 'reader', createIfMissing: true);
      final grants = <(NodeId, String)>[];
      final pulls = <(List<NodeId>, String)>[];
      final sentMediaRequests = <String>[];
      late final GroupService readerService;
      final ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        sendPublicFeedChunk: (requester, chunkJson) async {
          expect(requester, bob);
          readerService.handlePublicFeedObjectChunk(owner, chunkJson);
        },
        grantPublicContentServe: (peer, contentId) =>
            grants.add((peer, contentId)),
      );
      readerService = GroupService(
        readerStorage,
        _FakeSigner(bob),
        sendPublicFeedRequest: (holder, requestJson) async {
          expect(holder, owner);
          await ownerService.handlePublicFeedObjectRequest(bob, requestJson);
        },
        sendPublicMediaGrantRequest: (holder, requestJson) async {
          expect(holder, owner);
          sentMediaRequests.add(requestJson);
          await ownerService.handlePublicMediaGrantRequest(bob, requestJson);
        },
        startPublicContentPullFromAny: (holders, contentId) async {
          pulls.add((holders, contentId));
        },
        contentGrantDelay: Duration.zero,
      );
      addTearDown(ownerService.dispose);
      addTearDown(readerService.dispose);

      const mediaCid =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final spaceId = await ownerService.createSpace(
        'Public media',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      expect(
        await ownerService.publishSpacePost(
          spaceId,
          body: 'The exact public reference',
          media: [
            const MediaObject(
              kind: 'image',
              contentId: mediaCid,
              name: 'public.png',
              size: 64,
            ),
          ],
          broadcast: false,
        ),
        isNotNull,
      );
      final ownerPublication = await ownerService
          .buildSpacePublicDiscoveryPublication(spaceId);
      expect(ownerPublication, isNotNull);
      expect(
        await readerService.replicateVerifiedPublicSpaceDiscovery(
          ownerPublication!.discovery.descriptor,
          [ownerPublication.discovery.holder],
        ),
        isNotNull,
      );
      expect(await readerService.load(spaceId), isNull);

      expect(
        await readerService.requestPublicSpaceMedia(
          ownerPublication.discovery.descriptor,
          [ownerPublication.discovery.holder],
          mediaCid,
        ),
        isTrue,
      );
      expect(grants, [(bob, mediaCid)]);
      expect(pulls, hasLength(1));
      expect(pulls.single.$1, [owner]);
      expect(pulls.single.$2, mediaCid);
      expect(sentMediaRequests, hasLength(1));

      await ownerService.handlePublicMediaGrantRequest(
        carol,
        sentMediaRequests.single,
      );
      await ownerService.handlePublicMediaGrantRequest(
        bob,
        sentMediaRequests.single,
      );
      expect(grants, [
        (bob, mediaCid),
      ], reason: 'wrong-source and replayed requests must stay silent');

      expect(
        await readerService.requestPublicSpaceMedia(
          ownerPublication.discovery.descriptor,
          [ownerPublication.discovery.holder],
          'b' * 64,
        ),
        isFalse,
      );
      expect(
        sentMediaRequests,
        hasLength(1),
        reason: 'an uncommitted CID must be rejected before network disclosure',
      );

      // A requester signs its own `createdAtMs`, so it can future-date a
      // request by up to the tolerated clock skew. The replay set used to be
      // pruned after the REQUEST window alone, so the identical signed bytes
      // outlived the memory of having served them and renewed the serve TTL
      // again and again.
      final base = DateTime.now().millisecondsSinceEpoch;
      readerService.debugWallClockMs = () =>
          base + const Duration(minutes: 5).inMilliseconds;
      expect(
        await readerService.requestPublicSpaceMedia(
          ownerPublication.discovery.descriptor,
          [ownerPublication.discovery.holder],
          mediaCid,
        ),
        isTrue,
      );
      expect(sentMediaRequests, hasLength(2));
      expect(grants, hasLength(2), reason: 'the fresh request is served once');

      ownerService.debugWallClockMs = () =>
          base + const Duration(minutes: 3).inMilliseconds;
      await ownerService.handlePublicMediaGrantRequest(
        bob,
        sentMediaRequests.last,
      );
      expect(
        grants,
        hasLength(2),
        reason:
            'a future-dated request must stay remembered for as long as it '
            'stays acceptable',
      );
    },
  );

  test(
    'public-only subscriber advertises its exact verified package as a holder',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final readerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await readerStorage.open(password: 'reader', createIfMissing: true);
      final transport = _FakeSpaceDiscoveryTransport();
      final ownerSigner = _DiscoveryFakeSigner(17);
      final ownerId = ownerSigner.selfId;
      final readerSigner = _DiscoveryFakeSigner(18);
      final readerId = readerSigner.selfId;
      late final GroupService readerService;
      final ownerService = GroupService(
        ownerStorage,
        ownerSigner,
        sendPublicFeedChunk: (requester, chunkJson) async {
          expect(requester, readerId);
          readerService.handlePublicFeedObjectChunk(ownerId, chunkJson);
        },
      );
      readerService = GroupService(
        readerStorage,
        readerSigner,
        sendPublicFeedRequest: (holder, requestJson) async {
          expect(holder, ownerId);
          await ownerService.handlePublicFeedObjectRequest(
            readerId,
            requestJson,
          );
        },
        spaceDiscoveryTransport: transport,
      );
      addTearDown(ownerService.dispose);
      addTearDown(readerService.dispose);

      // Both services read a PINNED clock.
      //
      // Without it this test was ~50% flaky when its file ran alone, and
      // green in the full suite — which is worse, because the green was
      // bought by however long the parallel files happened to take. The
      // publish path is timed twice over: `_replicatePublicSpaceDiscovery`
      // drops a cached verified feed once `retainedUntilMs <= _now()`, and
      // the sweep skips a descriptor republished within 25 minutes. Neither
      // is a race in the product — they are real policies — but a test that
      // lets wall time decide which side of them it lands on is not
      // evidence about either.
      //
      // `debugWallClockMs` is the seam the neighbouring tests already use for
      // exactly this: "retention expiry spans days, so deterministic tests
      // drive the wall clock instead of waiting it out".
      //
      // The reader's clock is deliberately LATER than the owner's, because
      // that is the ordering the product requires: `verifyStored` accepts a
      // snapshot only when `verifiedAtMs >= descriptor.issuedAtMs`, and the
      // reader verifies what the owner already signed.
      //
      // Pinning both to the SAME instant does not model that and fails 8 runs
      // out of 8 — each service's `_now()` is monotonic per instance, so from
      // one shared origin the owner, having taken more readings before it
      // signs, ends up stamped ahead of the reader. With a real clock the
      // milliseconds that pass between the two hide it, which is exactly what
      // made this test ~50% flaky alone and green under load.
      final wall = DateTime.now().millisecondsSinceEpoch;
      ownerService.debugWallClockMs = () => wall;
      readerService.debugWallClockMs = () => wall + 60000;

      final spaceId = await ownerService.createSpace(
        'Subscriber reseed',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      expect(
        await ownerService.publishSpacePost(
          spaceId,
          body: 'Owner-signed public package',
          broadcast: false,
        ),
        isNotNull,
      );
      final ownerPublication = await ownerService
          .buildSpacePublicDiscoveryPublication(spaceId);
      expect(ownerPublication, isNotNull);
      expect(
        await readerService.subscribeToPublicSpace(
          ownerPublication!.discovery.descriptor,
          [ownerPublication.discovery.holder],
        ),
        isNotNull,
      );
      expect(await readerService.load(spaceId), isNull);

      final sweep = await readerService.publishPublicSpaceDiscovery();
      expect(sweep.available, isTrue);
      expect(sweep.spacesScanned, 1);
      expect(sweep.spacesPublished, 1);
      expect(sweep.failures, 0);
      final direct = transport.records
          .map(SpaceDiscoveryCarrier.fromBytes)
          .whereType<SpaceDiscoveryCarrier>()
          .singleWhere(
            (record) =>
                record.route.kind == SpaceDiscoveryCarrierRouteKind.direct,
          );
      final payload = SpacePublicDiscoveryPayload.fromBytes(direct.payload)!;
      expect(payload.descriptor.publisher, ownerId);
      expect(payload.descriptor.spaceId, spaceId);
      expect(payload.holder.holder, readerId);
      expect(
        payload.holder.publicFeedManifestHash,
        ownerPublication.discovery.descriptor.publicFeedManifestHash,
      );
      final wire = utf8.decode(direct.payload);
      expect(wire, isNot(contains('"members"')));
      expect(wire, isNot(contains('"epochEnvelopes"')));
    },
  );

  test(
    'an unreferenced content id costs a subscriber no network round trip',
    () async {
      // This pins a check that is redundant for SECURITY and easy to delete
      // for exactly that reason. Removing either content check inside
      // requestSubscribedPublicSpaceMedia leaves the whole suite green,
      // because the authority is one layer down in requestPublicSpaceMedia
      // (covered by 'public media grant requires an exact cached verified
      // projection'). What the subscriber-side check actually buys is the
      // round trip: without it, asking for a content id that plainly is not
      // in the feed still spends a discovery resolve with an 8 s timeout.
      final ownerStorage = FakeHvContainer().storage();
      final readerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await readerStorage.open(password: 'reader', createIfMissing: true);
      final transport = _FakeSpaceDiscoveryTransport();
      final ownerSigner = _DiscoveryFakeSigner(17);
      final ownerId = ownerSigner.selfId;
      final readerSigner = _DiscoveryFakeSigner(18);
      final readerId = readerSigner.selfId;
      late final GroupService readerService;
      final ownerService = GroupService(
        ownerStorage,
        ownerSigner,
        sendPublicFeedChunk: (requester, chunkJson) async {
          readerService.handlePublicFeedObjectChunk(ownerId, chunkJson);
        },
      );
      readerService = GroupService(
        readerStorage,
        readerSigner,
        sendPublicFeedRequest: (holder, requestJson) async {
          await ownerService.handlePublicFeedObjectRequest(
            readerId,
            requestJson,
          );
        },
        spaceDiscoveryTransport: transport,
      );
      addTearDown(ownerService.dispose);
      addTearDown(readerService.dispose);

      const referencedCid =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const unknownCid =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final spaceId = await ownerService.createSpace(
        'Subscriber media gate',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      expect(
        await ownerService.publishSpacePost(
          spaceId,
          body: 'Carries exactly one referenced object',
          media: [
            const MediaObject(
              kind: 'image',
              contentId: referencedCid,
              name: 'referenced.png',
              size: 3,
            ),
          ],
          broadcast: false,
        ),
        isNotNull,
      );
      final publication = await ownerService
          .buildSpacePublicDiscoveryPublication(spaceId);
      expect(publication, isNotNull);
      expect(
        await readerService.subscribeToPublicSpace(
          publication!.discovery.descriptor,
          [publication.discovery.holder],
        ),
        isNotNull,
      );

      transport.resolvedRoutes.clear();
      expect(
        await readerService.requestSubscribedPublicSpaceMedia(
          spaceId,
          unknownCid,
        ),
        isFalse,
      );
      expect(
        transport.resolvedRoutes,
        isEmpty,
        reason:
            'the subscription snapshot already answers this — refusing after '
            'an 8 s discovery timeout is the failure being guarded against',
      );

      // The other half: a referenced id DOES reach the network. Without this
      // a subscriber that resolves nothing at all would satisfy the assertion
      // above and the test would prove nothing.
      expect(
        await readerService.requestSubscribedPublicSpaceMedia(
          spaceId,
          referencedCid,
        ),
        isFalse,
        reason: 'no holder is published in this transport, so it cannot pull',
      );
      expect(transport.resolvedRoutes, isNotEmpty);
    },
  );

  test(
    'public discovery publishes native routes and keeps global search quorum',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'owner', createIfMissing: true);
      final signer = _DiscoveryFakeSigner(17);
      final transport = _FakeSpaceDiscoveryTransport();
      final service = GroupService(
        storage,
        signer,
        spaceDiscoveryTransport: transport,
      );
      addTearDown(service.dispose);

      final spaceId = await service.createSpace(
        'Открытый Сад',
        description: 'Проверенное публичное сообщество',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      final sweep = await service.publishPublicSpaceDiscovery();
      expect(sweep.available, isTrue);
      expect(sweep.spacesScanned, 1);
      expect(sweep.spacesPublished, 1);
      expect(sweep.recordsPublished, greaterThan(2));
      expect(sweep.failures, 0);
      expect(
        transport.records
            .map(SpaceDiscoveryCarrier.fromBytes)
            .whereType<SpaceDiscoveryCarrier>()
            .where(
              (record) =>
                  record.route.kind == SpaceDiscoveryCarrierRouteKind.direct,
            ),
        hasLength(1),
      );

      final exact = await service.resolvePublicSpace(spaceId);
      expect(exact?.spaceId, spaceId);
      expect(exact?.name, 'Открытый Сад');
      final exactResult = await service.resolvePublicSpaceDiscovery(spaceId);
      expect(exactResult?.descriptor.descriptorHash, exact?.descriptorHash);
      expect(exactResult?.holders, hasLength(1));
      expect(exactResult?.holders.single.holder, signer.selfId);

      final prefixRoute = SpaceDiscoveryCarrierRoute.search(
        spaceDiscoverySearchTokenHash('откр'),
      );
      final prefixRecord = transport.records
          .map(SpaceDiscoveryCarrier.fromBytes)
          .whereType<SpaceDiscoveryCarrier>()
          .firstWhere((record) => record.route.sameAs(prefixRoute));
      expect(
        prefixRecord.verifyAt(
          DateTime.now().millisecondsSinceEpoch,
          signer.verifyDetached,
        ),
        isTrue,
      );
      expect(
        await service.searchPublicSpaces('откр', minimumIndependentHolders: 1),
        hasLength(1),
      );
      final searchable = await service.searchPublicSpaceDiscovery(
        'откр',
        minimumIndependentHolders: 1,
      );
      expect(searchable, hasLength(1));
      expect(searchable.single.holders, hasLength(1));
      final resolvedSearchRoutes = transport.resolvedRoutes
          .where((route) => route.kind == SpaceDiscoveryCarrierRouteKind.search)
          .toList(growable: false);
      expect(resolvedSearchRoutes, isNotEmpty);
      expect(
        resolvedSearchRoutes.any((route) => route.sameAs(prefixRoute)),
        isTrue,
      );
      final routeWire = utf8.decode([
        for (final route in resolvedSearchRoutes) ...route.body,
      ], allowMalformed: true);
      expect(routeWire, isNot(contains('откр')));
      expect(routeWire, isNot(contains('Открытый Сад')));
      expect(
        await service.searchPublicSpaces('откр'),
        isEmpty,
        reason:
            'one publishing identity must not satisfy global discovery quorum',
      );
      final partial = await service.searchPublicSpaceDiscoveryOutcome('откр');
      expect(partial.status, SpacePublicDiscoverySearchStatus.partialQuorum);
      expect(
        partial.results,
        isEmpty,
        reason: 'a partial quorum is diagnostic state, not a public result',
      );

      final offlineStorage = FakeHvContainer().storage();
      await offlineStorage.open(password: 'offline', createIfMissing: true);
      final offlineService = GroupService(offlineStorage, signer);
      addTearDown(offlineService.dispose);
      final unavailable = await offlineService
          .searchPublicSpaceDiscoveryOutcome('откр');
      expect(unavailable.status, SpacePublicDiscoverySearchStatus.unavailable);
      expect(unavailable.results, isEmpty);

      final second = await service.publishPublicSpaceDiscovery();
      expect(second.complete, isTrue);
      final directRecords = transport.records
          .map(SpaceDiscoveryCarrier.fromBytes)
          .whereType<SpaceDiscoveryCarrier>()
          .where(
            (record) =>
                record.route.kind == SpaceDiscoveryCarrierRouteKind.direct,
          )
          .toList();
      expect(directRecords, hasLength(2));
      final firstPayload = SpacePublicDiscoveryPayload.fromBytes(
        directRecords.first.payload,
      );
      final refreshedPayload = SpacePublicDiscoveryPayload.fromBytes(
        directRecords.last.payload,
      );
      expect(
        refreshedPayload?.descriptor.descriptorHash,
        firstPayload?.descriptor.descriptorHash,
      );
      expect(
        refreshedPayload!.holder.issuedAtMs,
        greaterThan(firstPayload!.holder.issuedAtMs),
      );

      final beforeSuppressedRefresh = transport.records.length;
      final suppressed = await service.publishPublicSpaceDiscovery(
        forceHolderRefresh: false,
      );
      expect(suppressed.spacesPublished, 0);
      expect(transport.records, hasLength(beforeSuppressedRefresh));

      expect(await service.renameGroup(spaceId, 'Открытый Сад 2'), isTrue);
      final changed = await service.publishPublicSpaceDiscovery(
        forceHolderRefresh: false,
      );
      expect(changed.spacesPublished, 1);
      expect(transport.records.length, greaterThan(beforeSuppressedRefresh));
    },
  );

  test(
    'public Space join link admits a non-contact only after signed approval',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final requesterStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await requesterStorage.open(password: 'requester', createIfMissing: true);
      late GroupService ownerService;
      late GroupService requesterService;
      ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        sendSpaceJoinDecision: (peer, requestId, json) async {
          expect(peer, bob);
          if (!await requesterService.receiveSpaceJoinDecision(owner, json)) {
            throw StateError('requester rejected a valid decision');
          }
        },
        send: (peer, spaceId, json) async {
          if (peer == bob &&
              !await requesterService.ingestGroupEntryFromStranger(
                owner,
                json,
              )) {
            throw StateError('requester rejected approved Space snapshot');
          }
        },
      );
      requesterService = GroupService(
        requesterStorage,
        _FakeSigner(bob),
        sendSpaceJoinRequest: (peer, requestId, json) async {
          expect(peer, owner);
          if (!await ownerService.receiveSpaceJoinRequest(bob, json)) {
            throw StateError('approver rejected a valid join request');
          }
        },
      );
      addTearDown(ownerService.dispose);
      addTearDown(requesterService.dispose);

      final groupChat = await ownerService.createGroup('Team chat');
      expect(
        await ownerService.createSpaceJoinCode(groupChat),
        isNull,
        reason: 'group chats remain chats and never become public Spaces',
      );
      final privateSpace = await ownerService.createSpace('Private lab');
      expect(await ownerService.createSpaceJoinCode(privateSpace), isNull);
      final spaceId = await ownerService.createSpace(
        'Public lab',
        visibility: SpaceVisibility.public,
      );
      final code = await ownerService.createSpaceJoinCode(spaceId);
      expect(code, startsWith('xveil://space/v1#'));
      expect(
        (await ownerService.currentSpaceJoinCode(spaceId)),
        code,
        reason: 'copying the same active link must not rotate its capability',
      );

      final unsolicited = ownerService.snapshotJson(
        (await ownerService.load(spaceId))!,
        recipient: bob,
      );
      expect(
        await requesterService.ingestGroupEntryFromStranger(owner, unsolicited),
        isFalse,
      );
      expect(await requesterService.load(spaceId), isNull);

      expect(await requesterService.requestToJoinSpace(code!), isTrue);
      expect(
        await ownerService.pendingSpaceJoinRequests(spaceId),
        hasLength(1),
      );
      final outgoing = await requesterService.outgoingSpaceJoinRequests();
      expect(outgoing, hasLength(1));
      expect(outgoing.single.ticket.spaceName, 'Public lab');
      expect(
        outgoing.single.request.ticketHash,
        spaceJoinTicketHash(outgoing.single.ticket),
      );

      // A second request for the same Space reuses the durable id instead of
      // creating a spam row or a second membership ceremony.
      expect(await requesterService.requestToJoinSpace(code), isTrue);
      expect(
        await ownerService.pendingSpaceJoinRequests(spaceId),
        hasLength(1),
      );

      final requestId = outgoing.single.request.requestId;
      expect(
        await ownerService.decideSpaceJoinRequest(requestId, accept: true),
        isTrue,
      );
      await pump();
      expect(
        (await ownerService.stateOf(spaceId))!.roleOf(bob),
        GroupRole.member,
      );
      expect(
        (await requesterService.stateOf(spaceId))!.roleOf(bob),
        GroupRole.member,
      );
      expect(await requesterService.outgoingSpaceJoinRequests(), isEmpty);
      expect(await ownerService.pendingSpaceJoinRequests(spaceId), isEmpty);
    },
  );

  test('two join requests arriving at once do not lose one another', () async {
    // Same shape as the invite store and worse in consequence: a lost join
    // request means a person silently never gets admitted, with nothing on
    // either side to show why.
    final ownerStorage = FakeHvContainer().storage();
    final bobStorage = FakeHvContainer().storage();
    final carolStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'owner', createIfMissing: true);
    await bobStorage.open(password: 'bob', createIfMissing: true);
    await carolStorage.open(password: 'carol', createIfMissing: true);
    final captured = <NodeId, String>{};
    final ownerService = GroupService(
      ownerStorage,
      _FakeSigner(owner),
      sendSpaceJoinDecision: (peer, requestId, json) async {},
    );
    final bobService = GroupService(
      bobStorage,
      _FakeSigner(bob),
      // Capture instead of delivering, so both arrivals can be started
      // together rather than one after the other.
      sendSpaceJoinRequest: (peer, requestId, json) async =>
          captured[bob] = json,
    );
    final carolService = GroupService(
      carolStorage,
      _FakeSigner(carol),
      sendSpaceJoinRequest: (peer, requestId, json) async =>
          captured[carol] = json,
    );
    addTearDown(ownerService.dispose);
    addTearDown(bobService.dispose);
    addTearDown(carolService.dispose);

    final spaceId = await ownerService.createSpace(
      'Concurrent arrivals',
      visibility: SpaceVisibility.public,
    );
    final code = (await ownerService.createSpaceJoinCode(spaceId))!;
    expect(await bobService.requestToJoinSpace(code), isTrue);
    expect(await carolService.requestToJoinSpace(code), isTrue);
    expect(captured.length, 2);

    final results = await Future.wait([
      ownerService.receiveSpaceJoinRequest(bob, captured[bob]!),
      ownerService.receiveSpaceJoinRequest(carol, captured[carol]!),
    ]);
    expect(results, [isTrue, isTrue]);

    final pending = await ownerService.pendingSpaceJoinRequests(spaceId);
    expect(
      pending.map((entry) => entry.request.requester).toSet(),
      {bob, carol},
      reason: 'a concurrent arrival must not erase the one before it',
    );
  });

  test(
    'blocking a requester invalidates a received public Space join request',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final requesterStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await requesterStorage.open(password: 'requester', createIfMissing: true);
      late final GroupService ownerService;
      final requesterService = GroupService(
        requesterStorage,
        _FakeSigner(bob),
        sendSpaceJoinRequest: (peer, requestId, json) async {
          expect(peer, owner);
          expect(await ownerService.receiveSpaceJoinRequest(bob, json), isTrue);
        },
      );
      ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        sendSpaceJoinDecision: (peer, requestId, json) async {},
      );
      addTearDown(ownerService.dispose);
      addTearDown(requesterService.dispose);

      final spaceId = await ownerService.createSpace(
        'Blocked requester',
        visibility: SpaceVisibility.public,
      );
      final code = (await ownerService.createSpaceJoinCode(spaceId))!;
      expect(await requesterService.requestToJoinSpace(code), isTrue);
      final request = (await ownerService.pendingSpaceJoinRequests(
        spaceId,
      )).single;

      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.blocked),
      );
      expect(
        await ownerService.decideSpaceJoinRequest(
          request.request.requestId,
          accept: true,
        ),
        isFalse,
      );
      expect(await ownerService.pendingSpaceJoinRequests(spaceId), isEmpty);
      expect((await ownerService.stateOf(spaceId))!.isMember(bob), isFalse);
    },
  );

  test(
    'blocking during public join epoch sealing aborts membership atomically',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final requesterStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await requesterStorage.open(password: 'requester', createIfMissing: true);
      final crypto = _GatedMailboxCrypto(
        senderForOpen: owner,
        heldRecipient: bob,
      );
      addTearDown(() {
        if (!crypto.release.isCompleted) crypto.release.complete();
      });
      late final GroupService ownerService;
      final decisions = <String>[];
      final requesterService = GroupService(
        requesterStorage,
        _FakeSigner(bob),
        sendSpaceJoinRequest: (peer, requestId, json) async {
          expect(await ownerService.receiveSpaceJoinRequest(bob, json), isTrue);
        },
      );
      ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(crypto),
        sendSpaceJoinDecision: (peer, requestId, json) async {
          decisions.add(json);
        },
      );
      addTearDown(ownerService.dispose);
      addTearDown(requesterService.dispose);

      final spaceId = await ownerService.createSpace(
        'Concurrent block',
        visibility: SpaceVisibility.public,
      );
      final code = (await ownerService.createSpaceJoinCode(spaceId))!;
      expect(await requesterService.requestToJoinSpace(code), isTrue);
      final request = (await ownerService.pendingSpaceJoinRequests(
        spaceId,
      )).single;

      final deciding = ownerService.decideSpaceJoinRequest(
        request.request.requestId,
        accept: true,
      );
      await crypto.entered.future;
      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.blocked),
      );
      ownerService.notifyContactAccessChanged(bob);
      crypto.release.complete();

      expect(await deciding, isFalse);
      expect((await ownerService.stateOf(spaceId))!.isMember(bob), isFalse);
      expect(await ownerService.pendingSpaceJoinRequests(spaceId), isEmpty);
      expect(decisions, isEmpty);
      expect(
        (await ownerService.load(spaceId))!.control
            .where(
              (entry) => entry.target == bob && entry.op == ControlOp.addMember,
            )
            .toList(),
        isEmpty,
        reason:
            'the guard runs after epoch sealing and before durable membership',
      );
    },
  );

  test(
    'blocking during accepted invite epoch sealing retires the consent',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.accepted),
      );
      final crypto = _GatedMailboxCrypto(
        senderForOpen: owner,
        heldRecipient: bob,
      );
      addTearDown(() {
        if (!crypto.release.isCompleted) crypto.release.complete();
      });
      SpaceInvite? invite;
      final ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(crypto),
        sendSpaceInvite: (peer, inviteId, json) async {
          invite = SpaceInvite.fromJson(jsonDecode(json));
        },
      );
      addTearDown(ownerService.dispose);
      final spaceId = await ownerService.createSpace('Invite race');
      expect(await ownerService.inviteToSpace(spaceId, bob), isTrue);
      final sentInvite = invite!;
      final decision = SpaceInviteDecision(
        inviteId: sentInvite.inviteId,
        spaceId: spaceId,
        accepted: true,
        decidedAtMs: sentInvite.createdAtMs + 1,
      );

      final receiving = ownerService.receiveSpaceInviteDecision(
        bob,
        jsonEncode(decision.toJson()),
      );
      await crypto.entered.future;
      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.blocked),
      );
      ownerService.notifyContactAccessChanged(bob);
      crypto.release.complete();

      expect(await receiving, isFalse);
      expect((await ownerService.stateOf(spaceId))!.isMember(bob), isFalse);
      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.accepted),
      );
      ownerService.notifyContactAccessChanged(bob);
      expect(
        await ownerService.receiveSpaceInviteDecision(
          bob,
          jsonEncode(decision.toJson()),
        ),
        isFalse,
        reason: 'unblocking cannot revive the retired invitation consent',
      );
    },
  );

  test(
    'blocking during durable join write preserves a persisted compensation',
    () async {
      final ownerStorage = _PostWriteGatedStorage();
      final requesterStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await requesterStorage.open(password: 'requester', createIfMissing: true);
      addTearDown(() {
        if (!ownerStorage.release.isCompleted) ownerStorage.release.complete();
      });
      var failBroadcasts = false;
      var rejectedBroadcasts = 0;
      late final GroupService ownerService;
      final requesterService = GroupService(
        requesterStorage,
        _FakeSigner(bob),
        sendSpaceJoinRequest: (peer, requestId, json) async {
          expect(await ownerService.receiveSpaceJoinRequest(bob, json), isTrue);
        },
      );
      ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
        send: (peer, groupId, json) async {
          if (failBroadcasts) {
            rejectedBroadcasts++;
            throw StateError('offline after durable compensation');
          }
        },
        sendSpaceJoinDecision: (peer, requestId, json) async {},
      );
      addTearDown(ownerService.dispose);
      addTearDown(requesterService.dispose);

      final spaceId = await ownerService.createSpace(
        'Durable compensation',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: carol,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerService.createChannel(
          spaceId,
          name: 'protected',
          kind: SpaceChannelKind.text,
          access: SpaceChannelAccess.restricted,
          members: [carol],
        ),
        isNotNull,
      );
      final code = (await ownerService.createSpaceJoinCode(spaceId))!;
      expect(await requesterService.requestToJoinSpace(code), isTrue);
      final request = (await ownerService.pendingSpaceJoinRequests(
        spaceId,
      )).single;

      ownerStorage.gateNextGroupWrite = true;
      final deciding = ownerService.decideSpaceJoinRequest(
        request.request.requestId,
        accept: true,
      );
      final first = await Future.any<String>([
        ownerStorage.entered.future.then((_) => 'write'),
        deciding.then((result) => 'decision:$result'),
      ]).timeout(const Duration(seconds: 5), onTimeout: () => 'timeout');
      expect(first, 'write');
      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.blocked),
      );
      ownerService.notifyContactAccessChanged(bob);
      failBroadcasts = true;
      ownerStorage.release.complete();

      expect(
        await deciding.timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              throw StateError('compensating decision did not finish'),
        ),
        isFalse,
      );
      expect(rejectedBroadcasts, greaterThan(0));
      expect((await ownerService.stateOf(spaceId))!.isMember(bob), isFalse);
      final controls = (await ownerService.load(
        spaceId,
      ))!.control.where((entry) => entry.target == bob).toList();
      expect(
        controls.map((entry) => entry.op),
        containsAllInOrder([ControlOp.addMember, ControlOp.removeMember]),
        reason:
            'append-only history records both the raced add and its durable '
            'compensation even when the immediate snapshot retry is offline',
      );
    },
  );

  test(
    'blocking an approver invalidates requester consent before a late grant',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final requesterStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await requesterStorage.open(password: 'requester', createIfMissing: true);
      late final GroupService ownerService;
      final requesterService = GroupService(
        requesterStorage,
        _FakeSigner(bob),
        sendSpaceJoinRequest: (peer, requestId, json) async {
          expect(peer, owner);
          expect(await ownerService.receiveSpaceJoinRequest(bob, json), isTrue);
        },
      );
      ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        sendSpaceJoinDecision: (peer, requestId, json) async {},
      );
      addTearDown(ownerService.dispose);
      addTearDown(requesterService.dispose);

      final spaceId = await ownerService.createSpace(
        'Blocked approver',
        visibility: SpaceVisibility.public,
      );
      final code = (await ownerService.createSpaceJoinCode(spaceId))!;
      expect(await requesterService.requestToJoinSpace(code), isTrue);
      final request = (await ownerService.pendingSpaceJoinRequests(
        spaceId,
      )).single;

      await requesterStorage.upsertContact(
        Contact(nodeId: owner, status: ContactStatus.blocked),
      );
      expect(await requesterService.outgoingSpaceJoinRequests(), isEmpty);
      expect(await requesterService.spaceMemberships(), isEmpty);
      expect(
        await ownerService.decideSpaceJoinRequest(
          request.request.requestId,
          accept: true,
        ),
        isTrue,
      );
      expect(
        await requesterService.ingestGroupEntryFromStranger(
          owner,
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isFalse,
        reason:
            'a late grant cannot revive a request after blocking the approver',
      );
      expect(await requesterService.load(spaceId), isNull);
    },
  );

  test(
    'Space membership projection derives active suspended left and banned from signed facts',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(storage, _FakeSigner(owner));
      final bobService = GroupService(storage, _FakeSigner(bob));
      addTearDown(ownerService.dispose);
      addTearDown(bobService.dispose);

      final spaceId = await ownerService.createSpace(
        'Membership lab',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      var membership = (await bobService.spaceMemberships()).singleWhere(
        (entry) => entry.spaceId == spaceId,
      );
      expect(membership.status, SpaceMembershipStatus.active);
      expect(membership.source, SpaceMembershipSource.controlLog);
      expect(membership.isMember, isTrue);

      final until =
          DateTime.now().millisecondsSinceEpoch +
          const Duration(hours: 1).inMilliseconds;
      final timeoutId = await ownerService.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.timeout,
        target: bob,
        scope: SpaceModerationScope.space,
        reason: 'cool down',
        expiresAtMs: until,
      );
      expect(timeoutId, isNotNull);
      membership = (await bobService.spaceMemberships()).singleWhere(
        (entry) => entry.spaceId == spaceId,
      );
      expect(membership.status, SpaceMembershipStatus.suspended);
      expect(membership.source, SpaceMembershipSource.moderation);
      expect(membership.isMember, isTrue);
      expect(membership.untilMs, until);
      expect(membership.reason, 'cool down');

      expect(
        await ownerService.revokeSpaceModeration(
          spaceId,
          timeoutId!,
          reason: 'reviewed',
        ),
        isTrue,
      );
      expect(
        (await bobService.spaceMemberships())
            .singleWhere((entry) => entry.spaceId == spaceId)
            .status,
        SpaceMembershipStatus.active,
      );

      expect(await bobService.leaveGroup(spaceId), isTrue);
      membership = (await bobService.spaceMemberships()).singleWhere(
        (entry) => entry.spaceId == spaceId,
      );
      expect(membership.status, SpaceMembershipStatus.left);
      expect(membership.isMember, isFalse);
      expect(await bobService.listSpaces(), isEmpty);

      final bannedSpace = await ownerService.createSpace(
        'Ban lab',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerService.addControlOp(
          bannedSpace,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerService.moderateSpace(
          bannedSpace,
          kind: SpaceModerationKind.permanentBan,
          target: bob,
          scope: SpaceModerationScope.space,
          reason: 'signed ban',
        ),
        isNotNull,
      );
      membership = (await bobService.spaceMemberships()).singleWhere(
        (entry) => entry.spaceId == bannedSpace,
      );
      expect(membership.status, SpaceMembershipStatus.banned);
      expect(membership.isMember, isFalse);
      expect(membership.reason, 'signed ban');
    },
  );

  test(
    'a retained left Space may request rejoin but a signed ban may not',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await bobStorage.open(password: 'bob', createIfMissing: true);
      late final GroupService ownerService;
      late final GroupService bobService;
      ownerService = GroupService(ownerStorage, _FakeSigner(owner));
      bobService = GroupService(
        bobStorage,
        _FakeSigner(bob),
        sendSpaceJoinRequest: (peer, requestId, requestJson) async {
          expect(peer, owner);
          expect(
            await ownerService.receiveSpaceJoinRequest(bob, requestJson),
            isTrue,
          );
        },
      );
      addTearDown(ownerService.dispose);
      addTearDown(bobService.dispose);

      final spaceId = await ownerService.createSpace(
        'Returnable',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(await bobService.leaveGroup(spaceId), isTrue);
      expect(
        await ownerService.ingestSnapshot(
          bobService.snapshotJson(
            (await bobService.load(spaceId))!,
            recipient: owner,
          ),
        ),
        isTrue,
      );
      expect((await ownerService.stateOf(spaceId))!.isMember(bob), isFalse);
      expect(
        (await bobService.spaceMemberships())
            .singleWhere((entry) => entry.spaceId == spaceId)
            .status,
        SpaceMembershipStatus.left,
      );

      final code = await ownerService.createSpaceJoinCode(spaceId);
      expect(code, isNotNull);
      expect(await bobService.requestToJoinSpace(code!), isTrue);
      expect(
        await ownerService.pendingSpaceJoinRequests(spaceId),
        hasLength(1),
      );
      expect(await bobService.outgoingSpaceJoinRequests(), hasLength(1));
      expect(
        (await bobService.spaceMemberships())
            .singleWhere((entry) => entry.spaceId == spaceId)
            .status,
        SpaceMembershipStatus.pending,
      );

      final bannedSpace = await ownerService.createSpace(
        'Blocked return',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerService.addControlOp(
          bannedSpace,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(bannedSpace))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        await ownerService.moderateSpace(
          bannedSpace,
          kind: SpaceModerationKind.permanentBan,
          target: bob,
          scope: SpaceModerationScope.space,
          reason: 'no rejoin',
        ),
        isNotNull,
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(bannedSpace))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final bannedCode = await ownerService.createSpaceJoinCode(bannedSpace);
      expect(bannedCode, isNotNull);
      expect(await bobService.requestToJoinSpace(bannedCode!), isFalse);
      expect(await ownerService.pendingSpaceJoinRequests(bannedSpace), isEmpty);
    },
  );

  /// A join request names its requester, and the approver must refuse one
  /// relayed by anybody else. Nothing covered that: deleting the check let a
  /// third party hand over somebody's signed request, putting a stranger in the
  /// owner's pending queue under a name they never authenticated as.
  test('a join request relayed by a third party is refused', () async {
    final ownerStorage = FakeHvContainer().storage();
    final carolStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'owner', createIfMissing: true);
    await carolStorage.open(password: 'carol', createIfMissing: true);
    String? requestJson;
    final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
    final carolSvc = GroupService(
      carolStorage,
      _FakeSigner(carol),
      sendSpaceJoinRequest: (peer, requestId, json) async {
        requestJson = json;
      },
    );
    addTearDown(ownerSvc.dispose);
    addTearDown(carolSvc.dispose);

    final spaceId = await ownerSvc.createSpace(
      'Open',
      visibility: SpaceVisibility.public,
    );
    final code = await ownerSvc.createSpaceJoinCode(spaceId);
    expect(code, isNotNull);
    expect(await carolSvc.requestToJoinSpace(code!), isTrue);
    expect(requestJson, isNotNull);

    // Carol signed it; bob hands it over. The ticket is live and the request
    // is well-formed — the only thing wrong is who delivered it.
    expect(
      await ownerSvc.receiveSpaceJoinRequest(bob, requestJson!),
      isFalse,
      reason: 'the authenticated source must be the requester itself',
    );
    expect(await ownerSvc.pendingSpaceJoinRequests(spaceId), isEmpty);

    // Control: delivered by carol herself it is accepted, so the refusal above
    // is about the relay and not about the request being unusable.
    expect(await ownerSvc.receiveSpaceJoinRequest(carol, requestJson!), isTrue);
    expect(await ownerSvc.pendingSpaceJoinRequests(spaceId), hasLength(1));
  });

  /// An invite names its invitee, and a node must refuse one addressed to
  /// somebody else even when it arrives from an accepted contact over an
  /// authenticated transport. Nothing covered that: deleting the check let a
  /// third party's invite land in this node's pending queue, where accepting
  /// it would start a membership proposal it was never offered.
  test('an invite addressed to someone else is refused', () async {
    final ownerStorage = FakeHvContainer().storage();
    final bobStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'owner', createIfMissing: true);
    await bobStorage.open(password: 'bob', createIfMissing: true);
    await ownerStorage.upsertContact(
      Contact(nodeId: carol, status: ContactStatus.accepted),
    );
    await bobStorage.upsertContact(
      Contact(nodeId: owner, status: ContactStatus.accepted),
    );
    String? forCarol;
    final ownerSvc = GroupService(
      ownerStorage,
      _FakeSigner(owner),
      sendSpaceInvite: (peer, inviteId, json) async {
        expect(peer, carol);
        forCarol = json;
      },
    );
    final bobSvc = GroupService(bobStorage, _FakeSigner(bob));
    addTearDown(ownerSvc.dispose);
    addTearDown(bobSvc.dispose);

    final spaceId = await ownerSvc.createSpace('Invite-only');
    expect(await ownerSvc.inviteToSpace(spaceId, carol), isTrue);
    expect(forCarol, isNotNull);

    // Bob is an accepted contact of the inviter and the transport source is
    // genuinely the inviter — everything matches except who it is FOR.
    expect(
      await bobSvc.receiveSpaceInvite(owner, forCarol!),
      isFalse,
      reason: 'the invitee named in the invite is the only valid recipient',
    );
    expect(await bobSvc.pendingSpaceInvites(), isEmpty);

    // And the mirror case: an invite that IS for bob, but relayed by someone
    // other than its inviter. The transport source has to be the inviter, or
    // any accepted contact could hand over invites minted by third parties.
    String? forBob;
    final ownerSvc2 = GroupService(
      ownerStorage,
      _FakeSigner(owner),
      sendSpaceInvite: (peer, inviteId, json) async {
        forBob = json;
      },
    );
    addTearDown(ownerSvc2.dispose);
    await ownerStorage.upsertContact(
      Contact(nodeId: bob, status: ContactStatus.accepted),
    );
    await bobStorage.upsertContact(
      Contact(nodeId: carol, status: ContactStatus.accepted),
    );
    final second = await ownerSvc2.createSpace('Relayed');
    expect(await ownerSvc2.inviteToSpace(second, bob), isTrue);
    expect(forBob, isNotNull);
    expect(
      await bobSvc.receiveSpaceInvite(carol, forBob!),
      isFalse,
      reason: 'the authenticated source must be the inviter itself',
    );
    expect(await bobSvc.pendingSpaceInvites(), isEmpty);
  });

  /// Carrying a recommendation card is gated on distributeContent, not on
  /// merely being able to see the Space — otherwise any member could spray
  /// cards at their contacts, which is the spam vector the permission exists
  /// for. It was uncovered: relaxing the check to SpacePermission.view left
  /// the whole suite green.
  ///
  /// The check has to run against a plain MEMBER. An owner is exempt from
  /// denials by construction (SpaceAcl.authorize skips them for
  /// GroupRole.owner), so an owner-only test cannot tell the two permissions
  /// apart and would pass either way.
  test('sharing a recommendation needs distribute, not just view', () async {
    final ownerStorage = FakeHvContainer().storage();
    final memberStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'owner', createIfMissing: true);
    await memberStorage.open(password: 'member', createIfMissing: true);
    final sent = <NodeId>[];
    final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
    final memberSvc = GroupService(
      memberStorage,
      _FakeSigner(bob),
      sendSpaceRecommendation: (peer, card) async {
        sent.add(peer);
        return 'message-${sent.length}';
      },
    );
    addTearDown(ownerSvc.dispose);
    addTearDown(memberSvc.dispose);

    final spaceId = await ownerSvc.createSpace(
      'Open community',
      description: 'Public',
      visibility: SpaceVisibility.public,
    );
    expect(
      await ownerSvc.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      ),
      isTrue,
    );
    final campaign = await ownerSvc.createSpaceRecommendationCampaign(
      spaceId,
      'Tell your friends',
    );
    expect(campaign, isNotNull);

    final denyRoleId = sha256
        .convert(utf8.encode('no-recommendation-distribution'))
        .toString();
    expect(
      await ownerSvc.replaceSpaceAccessPolicy(
        spaceId,
        expectedRevision: 0,
        roles: [
          SpaceRoleDefinition(
            roleId: denyRoleId,
            name: 'No distribution',
            grants: const <SpacePermissionGrant>[],
            denials: const [
              SpacePermissionDenial(
                permission: SpacePermission.distributeContent,
                scope: SpacePermissionScope.space(),
              ),
            ],
          ),
        ],
        groups: const <SpaceMemberGroup>[],
        directAssignments: [
          SpaceMemberRoleAssignment(member: bob, roleIds: [denyRoleId]),
        ],
      ),
      isNotNull,
    );
    expect(
      await memberSvc.ingestSnapshot(
        ownerSvc.snapshotJson((await ownerSvc.load(spaceId))!, recipient: bob),
      ),
      isTrue,
    );
    await memberStorage.upsertContact(
      Contact(nodeId: carol, status: ContactStatus.accepted),
    );

    expect(
      await memberSvc.shareSpaceRecommendation(
        spaceId,
        campaign!.campaignId,
        carol,
      ),
      SpaceRecommendationShareResult.notAllowed,
      reason: 'view alone must not be enough to carry a recommendation card',
    );
    expect(sent, isEmpty, reason: 'and nothing may go out on the wire');
  });

  test(
    'public Space recommendation campaign is signed and revocable',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'owner', createIfMissing: true);
      final sent = <({NodeId peer, String campaign})>[];
      final revoked = <({NodeId peer, String messageId})>[];
      final service = GroupService(
        storage,
        _FakeSigner(owner),
        sendSpaceRecommendation: (peer, card) async {
          sent.add((peer: peer, campaign: card.campaignId));
          return 'message-${sent.length}';
        },
        revokeSpaceRecommendation: (peer, messageId) async {
          revoked.add((peer: peer, messageId: messageId));
          return true;
        },
      );
      addTearDown(service.dispose);

      final groupId = await service.createGroup('Chat');
      final privateSpace = await service.createSpace('Private');
      final publicSpace = await service.createSpace(
        'Public',
        description: 'Open community',
        visibility: SpaceVisibility.public,
      );
      expect(
        await service.createSpaceRecommendationCampaign(groupId, 'Share it'),
        isNull,
      );
      expect(
        await service.createSpaceRecommendationCampaign(
          privateSpace,
          'Share it',
        ),
        isNull,
      );

      final campaign = await service.createSpaceRecommendationCampaign(
        publicSpace,
        '  Расскажите друзьям  ',
      );
      expect(campaign, isNotNull);
      expect(campaign!.text, 'Расскажите друзьям');
      expect(campaign.joinCode, startsWith('xveil://space/v1#'));
      final listed = await service.spaceRecommendationCampaigns(publicSpace);
      expect(listed, hasLength(1));
      expect(listed.single.campaignId, campaign.campaignId);
      final bundle = (await service.load(publicSpace))!;
      final control = bundle.control.last;
      expect(control.version, 13);
      expect(control.op, ControlOp.setRecommendationCampaign);
      expect(control.recommendationCampaign?.campaignId, campaign.campaignId);

      await storage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.accepted),
      );
      expect(
        await service.shareSpaceRecommendation(
          publicSpace,
          campaign.campaignId,
          bob,
        ),
        SpaceRecommendationShareResult.sent,
      );
      expect(sent.single.peer, bob);
      expect(
        await service.shareSpaceRecommendation(
          publicSpace,
          campaign.campaignId,
          bob,
        ),
        SpaceRecommendationShareResult.duplicate,
      );

      final shareAudit = await service.spaceRecommendationShareAudit();
      expect(shareAudit, hasLength(1));
      expect(shareAudit.single.recipient, bob);
      expect(shareAudit.single.messageId, 'message-1');

      final disabled = await service.setSpaceRecommendationPolicy(
        publicSpace,
        expectedRevision: 0,
        enabled: false,
      );
      expect(disabled?.revision, 1);
      expect(
        (await service.stateOf(publicSpace))!.recommendationsEnabled,
        false,
      );
      expect(
        await service.setSpaceRecommendationPolicy(
          publicSpace,
          expectedRevision: 0,
          enabled: true,
        ),
        isNull,
      );
      expect(
        await service.createSpaceRecommendationCampaign(
          publicSpace,
          'Blocked while disabled',
        ),
        isNull,
      );
      expect(
        await service.shareSpaceRecommendation(
          publicSpace,
          campaign.campaignId,
          bob,
        ),
        SpaceRecommendationShareResult.notAllowed,
      );
      final enabled = await service.setSpaceRecommendationPolicy(
        publicSpace,
        expectedRevision: 1,
        enabled: true,
      );
      expect(enabled?.revision, 2);
      expect(
        (await service.spacePolicyAudit(
          publicSpace,
        )).whereType<SpaceRecommendationPolicyAuditEntry>(),
        hasLength(2),
      );

      expect(
        await service.revokeSentSpaceRecommendation(shareAudit.single.stableId),
        SpaceRecommendationRevokeResult.revoked,
      );
      expect(revoked.single.peer, bob);
      expect(revoked.single.messageId, 'message-1');
      final revokedAudit = await service.spaceRecommendationShareAudit(
        spaceId: publicSpace,
      );
      expect(revokedAudit.single.revokedAtMs, isNotNull);
      expect(revokedAudit.single.canRevoke, isFalse);
      expect(
        await service.revokeSentSpaceRecommendation(shareAudit.single.stableId),
        SpaceRecommendationRevokeResult.alreadyRevoked,
      );

      for (var seed = 30; seed < 34; seed++) {
        final peer = _id(seed);
        await storage.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
        expect(
          await service.shareSpaceRecommendation(
            publicSpace,
            campaign.campaignId,
            peer,
          ),
          SpaceRecommendationShareResult.sent,
        );
      }
      final overLimit = _id(34);
      await storage.upsertContact(
        Contact(nodeId: overLimit, status: ContactStatus.accepted),
      );
      expect(
        await service.shareSpaceRecommendation(
          publicSpace,
          campaign.campaignId,
          overLimit,
        ),
        SpaceRecommendationShareResult.rateLimited,
      );
      expect(sent, hasLength(5));
      final observations = await service.spaceObservabilitySnapshot();
      expect(observations.counters['recommendationShared.succeeded'], 5);
      expect(observations.counters['recommendationShared.rejected'], 3);
      expect(observations.counters['recommendationShared.reason.duplicate'], 1);
      expect(
        observations.counters['recommendationShared.reason.permissionDenied'],
        1,
      );
      expect(
        observations.counters['recommendationShared.reason.rateLimited'],
        1,
      );
      expect(observations.counters['recommendationRevoked.succeeded'], 1);
      expect(observations.counters['recommendationRevoked.rejected'], 1);
      expect(observations.counters['aclDenied.reason.permissionDenied'], 1);

      expect(
        await service.revokeSpaceRecommendationCampaign(
          publicSpace,
          campaign.campaignId,
        ),
        isTrue,
      );
      expect(await service.spaceRecommendationCampaigns(publicSpace), isEmpty);
      final campaignAudit = await service.spaceRecommendationCampaigns(
        publicSpace,
        includeRevoked: true,
      );
      expect(campaignAudit.single.active, isFalse);
      expect(campaignAudit.single.joinCode, isEmpty);
    },
  );

  test(
    'revoking a public Space join link purges its pending request',
    () async {
      final storage = FakeHvContainer().storage();
      final requesterStorage = FakeHvContainer().storage();
      await storage.open(password: 'owner', createIfMissing: true);
      await requesterStorage.open(password: 'requester', createIfMissing: true);
      late GroupService ownerService;
      ownerService = GroupService(storage, _FakeSigner(owner));
      final requesterService = GroupService(
        requesterStorage,
        _FakeSigner(bob),
        sendSpaceJoinRequest: (peer, requestId, json) async {
          if (!await ownerService.receiveSpaceJoinRequest(bob, json)) {
            throw StateError('revoked ticket rejected');
          }
        },
      );
      addTearDown(ownerService.dispose);
      addTearDown(requesterService.dispose);
      final spaceId = await ownerService.createSpace(
        'Revocation lab',
        visibility: SpaceVisibility.public,
      );
      final code = (await ownerService.createSpaceJoinCode(spaceId))!;
      final ticket = SpaceJoinCode.parse(code);
      final tampered = SpaceJoinRequest(
        requestId: 'ef' * 32,
        ticketId: ticket.ticketId,
        ticketHash: '00' * 32,
        spaceId: spaceId,
        requester: bob,
        approver: owner,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      expect(
        await ownerService.receiveSpaceJoinRequest(
          bob,
          jsonEncode(tampered.toJson()),
        ),
        isFalse,
        reason: 'the request must be bound to the exact bearer ticket',
      );
      expect(await requesterService.requestToJoinSpace(code), isTrue);
      final pending = await ownerService.pendingSpaceJoinRequests(spaceId);
      expect(pending, hasLength(1));
      expect(await ownerService.revokeSpaceJoinCode(spaceId), isTrue);
      expect(await requesterService.requestToJoinSpace(code), isFalse);
      expect(await ownerService.pendingSpaceJoinRequests(spaceId), isEmpty);
      expect(
        await ownerService.decideSpaceJoinRequest(
          pending.single.request.requestId,
          accept: true,
        ),
        isFalse,
      );
      expect((await ownerService.stateOf(spaceId))!.isMember(bob), isFalse);
    },
  );

  test(
    'an expired public Space ticket purges its already received request',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final requesterStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await requesterStorage.open(password: 'requester', createIfMissing: true);
      late final GroupService ownerService;
      final requesterService = GroupService(
        requesterStorage,
        _FakeSigner(bob),
        sendSpaceJoinRequest: (peer, requestId, json) async {
          expect(peer, owner);
          expect(await ownerService.receiveSpaceJoinRequest(bob, json), isTrue);
        },
      );
      ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        sendSpaceJoinDecision: (peer, requestId, json) async {},
      );
      addTearDown(ownerService.dispose);
      addTearDown(requesterService.dispose);

      final spaceId = await ownerService.createSpace(
        'Expired request',
        visibility: SpaceVisibility.public,
      );
      final code = (await ownerService.createSpaceJoinCode(spaceId))!;
      expect(await requesterService.requestToJoinSpace(code), isTrue);
      final pending = (await ownerService.pendingSpaceJoinRequests(
        spaceId,
      )).single;

      final ticket = SpaceJoinCode.parse(code);
      final expiredTicket = SpaceJoinTicket(
        ticketId: ticket.ticketId,
        spaceId: ticket.spaceId,
        approver: ticket.approver,
        spaceName: ticket.spaceName,
        createdAtMs: ticket.createdAtMs,
        expiresAtMs: pending.request.createdAtMs + 1,
      );
      final raw =
          jsonDecode(
                (await ownerStorage.getSetting('spaces.join_requests.v1'))!,
              )
              as Map<String, dynamic>;
      raw['tickets'] = [expiredTicket.toJson()];
      final incoming = (raw['incoming'] as List).single as Map<String, dynamic>;
      final request = incoming['request'] as Map<String, dynamic>;
      request['ticketHash'] = spaceJoinTicketHash(expiredTicket);
      await ownerStorage.putSetting('spaces.join_requests.v1', jsonEncode(raw));
      await Future<void>.delayed(const Duration(milliseconds: 2));

      expect(await ownerService.pendingSpaceJoinRequests(spaceId), isEmpty);
      expect(
        await ownerService.decideSpaceJoinRequest(
          pending.request.requestId,
          accept: true,
        ),
        isFalse,
      );
      expect((await ownerService.stateOf(spaceId))!.isMember(bob), isFalse);
    },
  );

  test('a mute op ships a control DELTA (no messages re-sent)', () async {
    final sent = <String>[];
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(
      storage,
      _FakeSigner(owner),
      send: (peer, gid, json) async => sent.add(json),
    );
    final gid = await svc.createGroup('G');
    await svc.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );
    await svc.postMessage(gid, 'msg');
    await pump();
    sent.clear();
    await svc.addControlOp(gid, ControlOp.mute, target: bob);
    await pump();
    final delta = jsonDecode(sent.last) as Map;
    expect(delta['g'] as List, isEmpty, reason: 'a mute re-sends no messages');
    expect((delta['c'] as List).length, 1, reason: 'just the mute entry');
  });

  test(
    'a member leaves: removed from state + hidden from their list; owner cannot',
    () async {
      final (svc, member) = await setup();
      final gid = await svc.createGroup('G');
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      expect((await svc.stateOf(gid))!.isMember(bob), isTrue);

      final bobDev = member(bob);
      expect(await bobDev.leaveGroup(gid), isTrue);
      expect(
        (await svc.stateOf(gid))!.isMember(bob),
        isFalse,
        reason: 'the leave op removes the author',
      );
      expect(
        (await bobDev.listGroups()).where((g) => g.groupId == gid),
        isEmpty,
        reason: 'a left group is hidden from the leaver',
      );
      expect(
        (await svc.listGroups()).where((g) => g.groupId == gid),
        isNotEmpty,
        reason: 'the owner still sees it',
      );

      // The owner is the genesis and cannot leave.
      expect(await svc.leaveGroup(gid), isFalse);
      expect((await svc.stateOf(gid))!.isMember(owner), isTrue);
    },
  );

  test(
    'Space owner transfers atomically, then the previous owner may leave',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(storage, _FakeSigner(owner));
      final bobService = GroupService(storage, _FakeSigner(bob));
      final spaceId = await ownerService.createSpace('Transferable');
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      expect(await ownerService.transferSpaceOwnership(spaceId, bob), isTrue);
      final transferred = (await ownerService.load(spaceId))!;
      expect(
        transferred.manifest.owner,
        owner,
        reason: 'genesis root is immutable',
      );
      expect(transferred.control.last.version, 6);
      expect(transferred.control.last.op, ControlOp.transferOwnership);
      expect(
        (await ownerService.stateOf(spaceId))!.roleOf(owner),
        GroupRole.admin,
      );
      expect(
        (await ownerService.stateOf(spaceId))!.roleOf(bob),
        GroupRole.owner,
      );
      expect(
        await ownerService.transferSpaceOwnership(spaceId, owner),
        isFalse,
        reason: 'the previous owner lost owner-only authority atomically',
      );

      expect(await ownerService.leaveGroup(spaceId), isTrue);
      final finalState = (await bobService.stateOf(spaceId))!;
      expect(finalState.isMember(owner), isFalse);
      expect(finalState.roleOf(bob), GroupRole.owner);
      expect(await bobService.leaveGroup(spaceId), isFalse);
    },
  );

  test(
    'ownership transfer rekeys protected channel control for the new owner',
    () async {
      final storage = _ControlledGroupWriteStorage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await service.createSpace('Protected transfer');
      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final channelId = await service.createChannel(
        spaceId,
        name: 'owners only',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
      );
      expect(channelId, isNotNull);
      expect(await service.channelMembersOf(spaceId, channelId!), [owner]);
      expect(
        await service.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.keepForever,
            channelId: channelId,
          ),
        ),
        isTrue,
      );

      storage.resetGroupWriteAttempts();
      expect(await service.transferSpaceOwnership(spaceId, bob), isTrue);
      expect(
        storage.groupWriteAttempts,
        1,
        reason: 'the channel key and role must share one durable commit',
      );
      expect(
        await service.channelMembersOf(spaceId, channelId),
        containsAllInOrder([owner, bob]),
        reason: 'the effective owner must never inherit a stranded ACL subtree',
      );
      expect(
        (await service.spaceRetentionPolicyOf(
          spaceId,
          channelId: channelId,
        ))?.mode,
        SpaceRetentionMode.keepForever,
        reason:
            'the outgoing owner must preserve the encrypted retention policy '
            'inside the same ownership transaction',
      );
      final controls = (await service.load(spaceId))!.control;
      expect(
        controls.any(
          (entry) =>
              entry.version == 6 && entry.op == ControlOp.transferOwnership,
        ),
        isTrue,
      );
      final channelRevision = controls.lastWhere(
        (entry) => entry.channelControl?.channelId == channelId,
      );
      expect(
        channelRevision.channelControl?.channelEpoch,
        2,
        reason: 'role transfer rotates opaque channel control immediately',
      );
      expect(
        controls.indexOf(channelRevision),
        lessThan(
          controls.lastIndexWhere(
            (entry) => entry.op == ControlOp.transferOwnership,
          ),
        ),
        reason:
            'the current owner must preserve protected policy/key authority '
            'before the signed ownership hand-off in the atomic bundle',
      );
    },
  );

  test(
    'admin demotion atomically removes implicit protected channel access',
    () async {
      final storage = _ControlledGroupWriteStorage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await service.createSpace('Atomic roles');
      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.admin,
        ),
        isTrue,
      );
      final channelId = await service.createChannel(
        spaceId,
        name: 'admins',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
      );
      expect(channelId, isNotNull);
      expect(
        await service.channelMembersOf(spaceId, channelId!),
        containsAll([owner, bob]),
      );

      storage.resetGroupWriteAttempts();
      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.setRole,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(storage.groupWriteAttempts, 1);
      expect(await service.channelMembersOf(spaceId, channelId), [owner]);
      expect(
        (await service.stateOf(
          spaceId,
        ))!.protectedChannels[channelId.hex]!.channelEpoch,
        2,
      );
    },
  );

  test(
    'permanent Space ban atomically revokes membership and every protected key',
    () async {
      final storage = _ControlledGroupWriteStorage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await service.createSpace('Atomic moderation ban');
      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final channelId = await service.createChannel(
        spaceId,
        name: 'protected incident room',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
        members: [bob],
      );
      expect(channelId, isNotNull);
      final before = (await service.stateOf(spaceId))!;
      final beforeChannelEpoch =
          before.protectedChannels[channelId!.hex]!.channelEpoch;

      storage.resetGroupWriteAttempts();
      final actionId = await service.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.permanentBan,
        target: bob,
        scope: SpaceModerationScope.space,
        reason: 'Repeated abuse',
      );

      expect(actionId, isNotNull);
      expect(
        storage.groupWriteAttempts,
        1,
        reason:
            'moderation audit, membership epoch and protected ACLs are one commit',
      );
      final after = (await service.stateOf(spaceId))!;
      expect(after.isMember(bob), isFalse);
      expect(after.epoch, before.epoch + 1);
      expect(
        after.protectedChannels[channelId.hex]!.channelEpoch,
        beforeChannelEpoch + 1,
      );
      expect(await service.channelMembersOf(spaceId, channelId), [owner]);
      final record = (await service.spaceModerationAudit(
        spaceId,
      )).singleWhere((entry) => entry.actionId == actionId);
      expect(record.action.kind, SpaceModerationKind.permanentBan);
      expect(record.action.reason, 'Repeated abuse');

      final blockedSnapshot =
          jsonDecode(
                service.snapshotJson(
                  (await service.load(spaceId))!,
                  recipient: bob,
                ),
              )
              as Map<String, dynamic>;
      expect(blockedSnapshot['ke'], isNull);
      expect(blockedSnapshot['cke'], isNull);
      expect(blockedSnapshot['g'], isEmpty);
      expect(blockedSnapshot['p'], isNull);
    },
  );

  test('a channel cannot claim to be secret while nothing hides it', () async {
    // `secret` exists in the enum but a channel is never created as one: the
    // protected-channel writer takes `restricted` and nothing else. That is
    // the right answer while the Space control chain still shows a
    // non-recipient that a protected channel exists, who wrote to it, when,
    // how large and to how many — a name promising invisibility over that
    // would be a claim the transport does not keep.
    //
    // The day a real secret scope arrives, this fails, and whoever writes it
    // has to revisit the same claim everywhere else it is made: the API's
    // advertised access values and the label and lock icon in
    // space_screen.dart.
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(
      storage,
      _FakeSigner(owner),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
    );
    final spaceId = await service.createSpace('Claims');

    expect(
      await service.createChannel(
        spaceId,
        name: 'restricted',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
      ),
      isNotNull,
      reason: 'the protection that IS delivered still works',
    );
    expect(
      await service.createChannel(
        spaceId,
        name: 'secret',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.secret,
      ),
      isNull,
      reason:
          'refused, rather than quietly made into a restricted channel '
          'wearing a better name',
    );

    final state = (await service.stateOf(spaceId))!;
    expect(
      state.protectedChannels.length,
      1,
      reason: 'the refusal left nothing behind',
    );
    expect(
      state.channels.values.any(
        (channel) => channel.access == SpaceChannelAccess.secret,
      ),
      isFalse,
    );

    await storage.close();
  });

  // WHAT A NON-RECIPIENT MEMBER LEARNS ABOUT A RESTRICTED CHANNEL.
  //
  // These are not a wish list. They assert the CURRENT truth so that the leak
  // table in doc/SECRET-CHANNEL-DESIGN.md is an executable fact rather than
  // prose I wrote — the whole argument for refusing `access: secret` today
  // rests on that table being right.
  //
  // Every expectation below is a LEAK. A secret-channel implementation must
  // make each of them fail; until then it would have hidden nothing, only
  // renamed it. If one starts failing without such an implementation, the
  // design document is wrong and must be corrected before anything is built.
  group('secret-channel groundwork: what the control chain gives away', () {
    Future<(GroupService, NodeId)> spaceWithTwoHiddenChannels() async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      // A protected channel's control entry carries a key descriptor, so the
      // epoch service is not optional here: without it createChannel returns
      // null and the chain is empty — which is how the first version of these
      // tests "passed" by asserting nothing.
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      addTearDown(svc.dispose);
      final spaceId = await svc.createSpace('Leak');
      for (final member in [bob, carol]) {
        await svc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: member,
          role: GroupRole.member,
        );
      }
      await svc.createChannel(
        spaceId,
        name: 'One',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
        members: [bob],
      );
      await svc.createChannel(
        spaceId,
        name: 'Two',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
        members: [bob, carol],
      );
      return (svc, spaceId);
    }

    /// Exactly what a non-recipient member holds: the signed chain, no keys.
    Future<List<SpaceChannelControlEnvelope>> chain(
      GroupService svc,
      NodeId spaceId,
    ) async {
      final bundle = (await svc.load(spaceId))!;
      return [for (final entry in bundle.control) ?entry.channelControl];
    }

    test('LEAK: a non-recipient can COUNT the hidden channels', () async {
      final (svc, spaceId) = await spaceWithTwoHiddenChannels();
      final ids = (await chain(svc, spaceId)).map((e) => e.channelId).toSet();
      expect(
        ids,
        hasLength(2),
        reason: 'the channel id is in the CLEARTEXT of every control entry',
      );
    });

    test('LEAK: the recipient count is a headcount', () async {
      final (svc, spaceId) = await spaceWithTwoHiddenChannels();
      final counts = [
        for (final e in await chain(svc, spaceId))
          e.keyDescriptor.recipientCount,
      ]..sort();
      // members + the administrator, who is a recipient of their own channel.
      expect(counts, [
        2,
        3,
      ], reason: 'how many people read each hidden channel, in the clear');
    });

    test('LEAK: entries of one channel are linkable, and a rotation shows as '
        'an epoch bump', () async {
      final (svc, spaceId) = await spaceWithTwoHiddenChannels();
      final target = (await chain(svc, spaceId)).first.channelId;

      expect(await svc.rotateChannelKey(spaceId, target), isTrue);

      final same = (await chain(
        svc,
        spaceId,
      )).where((e) => e.channelId == target).toList();
      expect(
        same.length,
        greaterThan(1),
        reason: 'entries are linked by a stable cleartext id',
      );
      expect(
        same.map((e) => e.channelEpoch).toSet(),
        hasLength(greaterThan(1)),
        reason: 'the key was replaced, and the chain says so',
      );
    });

    test('LEAK: the chain names who administers a hidden channel', () async {
      final (svc, spaceId) = await spaceWithTwoHiddenChannels();
      final bundle = (await svc.load(spaceId))!;
      final authors = {
        for (final entry in bundle.control)
          if (entry.channelControl != null) entry.author,
      };
      expect(authors, {
        owner,
      }, reason: 'signed by the account, not by the channel');
    });

    test(
      'NOT leaked: the name and the substance stay inside the ciphertext',
      () async {
        // The decisive fact for the product decision recorded in
        // doc/SECRET-CHANNEL-DESIGN.md: what a restricted channel already hides
        // is exactly what the owner asked to hide. A control entry carries
        // EITHER a cleartext channel descriptor OR the encrypted envelope,
        // never both, so the name never reaches the shared chain in the clear.
        final (svc, spaceId) = await spaceWithTwoHiddenChannels();
        final bundle = (await svc.load(spaceId))!;

        final wire = jsonEncode([
          for (final entry in bundle.control) entry.toJson(),
        ]);

        expect(
          wire.contains('"One"'),
          isFalse,
          reason: 'the channel name would be the whole point of hiding it',
        );
        expect(wire.contains('"Two"'), isFalse);
        expect(
          bundle.control.where(
            (e) => e.channel != null && e.channelControl != null,
          ),
          isEmpty,
          reason: 'cleartext descriptor and sealed envelope are exclusive',
        );
      },
    );

    test(
      'and `secret` is still refused, so none of this is promised away',
      () async {
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'pw', createIfMissing: true);
        final svc = GroupService(
          storage,
          _FakeSigner(owner),
          epochService: GroupEpochService(
            LoopbackMailboxCrypto(senderForOpen: owner),
          ),
        );
        addTearDown(svc.dispose);
        final spaceId = await svc.createSpace('Refusal');
        await svc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        );
        expect(
          await svc.createChannel(
            spaceId,
            name: 'Nope',
            kind: SpaceChannelKind.text,
            access: SpaceChannelAccess.secret,
            members: [bob],
          ),
          isNull,
          reason: 'shipping `secret` over this envelope would hide nothing',
        );
      },
    );
  });

  test(
    'a protected channel key can be replaced without touching its ACL',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await service.createSpace('Rotation');
      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final channelId = await service.createChannel(
        spaceId,
        name: 'private',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
      );
      expect(channelId, isNotNull);
      expect(
        await service.setChannelMembers(spaceId, channelId!, [bob]),
        isTrue,
      );

      final before = (await service.stateOf(spaceId))!;
      final beforeEpoch = before.protectedChannels[channelId.hex]!.channelEpoch;
      final beforeMembers = await service.channelMembersOf(spaceId, channelId);

      expect(await service.rotateChannelKey(spaceId, channelId), isTrue);

      final after = (await service.stateOf(spaceId))!;
      expect(
        after.protectedChannels[channelId.hex]!.channelEpoch,
        beforeEpoch + 1,
        reason: 'a replaced key is a new epoch',
      );
      expect(
        await service.channelMembersOf(spaceId, channelId),
        beforeMembers,
        reason: 'and nobody gained or lost access by it',
      );

      await storage.close();
    },
  );

  test('only someone who may edit the ACL may replace the key', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final ownerSvc = GroupService(
      storage,
      _FakeSigner(owner),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
    );
    final spaceId = await ownerSvc.createSpace('Rotation rights');
    expect(
      await ownerSvc.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      ),
      isTrue,
    );
    final channelId = await ownerSvc.createChannel(
      spaceId,
      name: 'private',
      kind: SpaceChannelKind.text,
      access: SpaceChannelAccess.restricted,
    );
    expect(channelId, isNotNull);
    expect(
      await ownerSvc.setChannelMembers(spaceId, channelId!, [bob]),
      isTrue,
    );

    final bobStorage = FakeHvContainer().storage();
    await bobStorage.open(password: 'pw', createIfMissing: true);
    final bobSvc = GroupService(
      bobStorage,
      _FakeSigner(bob),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: bob),
      ),
    );
    expect(
      await bobSvc.ingestSnapshot(
        ownerSvc.snapshotJson((await ownerSvc.load(spaceId))!, recipient: bob),
      ),
      isTrue,
    );
    final epochForBob = (await bobSvc.stateOf(
      spaceId,
    ))!.protectedChannels[channelId.hex]!.channelEpoch;

    expect(
      await bobSvc.rotateChannelKey(spaceId, channelId),
      isFalse,
      reason: 'a reader of the channel is not thereby its key holder',
    );
    expect(
      (await bobSvc.stateOf(
        spaceId,
      ))!.protectedChannels[channelId.hex]!.channelEpoch,
      epochForBob,
    );

    await bobStorage.close();
    await storage.close();
  });

  test('a key that has served too long is replaced by maintenance', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    var clock = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
    final service = GroupService(
      storage,
      _FakeSigner(owner),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
    )..debugWallClockMs = () => clock;
    final spaceId = await service.createSpace('Aging key');
    final channelId = await service.createChannel(
      spaceId,
      name: 'private',
      kind: SpaceChannelKind.text,
      access: SpaceChannelAccess.restricted,
    );
    expect(channelId, isNotNull);
    final epochAtRest = (await service.stateOf(
      spaceId,
    ))!.protectedChannels[channelId!.hex]!.channelEpoch;

    expect(
      await service.sweepStaleChannelKeys(),
      0,
      reason: 'a key in service is left alone',
    );

    // Past the threshold with room to spare: the frozen clock makes each
    // timestamp one millisecond later than the last, so the revision is
    // stamped a few ticks after the clock value the test set.
    clock += GroupService.protectedChannelKeyMaxAgeMs + 60000;
    expect(await service.sweepStaleChannelKeys(), 1);
    final rotated = (await service.stateOf(
      spaceId,
    ))!.protectedChannels[channelId.hex]!.channelEpoch;
    expect(rotated, epochAtRest + 1);

    expect(
      await service.sweepStaleChannelKeys(),
      0,
      reason: 'the fresh key restarts the clock — this must not loop',
    );

    await storage.close();
  });

  test('a key that has carried too much is replaced by maintenance', () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(
      storage,
      _FakeSigner(owner),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
    );
    final spaceId = await service.createSpace('Busy key');
    final channelId = await service.createChannel(
      spaceId,
      name: 'private',
      kind: SpaceChannelKind.text,
      access: SpaceChannelAccess.restricted,
    );
    expect(channelId, isNotNull);
    final epochAtRest = (await service.stateOf(
      spaceId,
    ))!.protectedChannels[channelId!.hex]!.channelEpoch;

    for (var i = 0; i < GroupService.protectedChannelKeyMaxMessages; i++) {
      expect(
        await service.postMessage(spaceId, 'm$i', channelId: channelId),
        isTrue,
      );
    }
    expect(await service.sweepStaleChannelKeys(), 1);
    expect(
      (await service.stateOf(
        spaceId,
      ))!.protectedChannels[channelId.hex]!.channelEpoch,
      epochAtRest + 1,
    );
    expect(
      await service.sweepStaleChannelKeys(),
      0,
      reason: 'the messages belong to the old epoch, so the new one is idle',
    );

    await storage.close();
  });

  test(
    'a channel epoch dated into the future used to mean the key never rotated '
    'by age at all — and it must still rotate, on this device, on time',
    () async {
      final t0 = DateTime.utc(2026, 8, 3, 12).millisecondsSinceEpoch;
      final hostileTs = t0 + const Duration(days: 365).inMilliseconds;
      String keyIdOf(NodeId channelId, int epoch) => '${channelId.hex}:$epoch';

      // The device that mints the epoch reads 2027 while it does so. Whether
      // that is a broken clock or a chosen number is exactly what nobody can
      // tell afterwards, and the signature over the control entry says nothing
      // about it — it proves who wrote the number, never that a clock produced
      // it.
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final wrongClock = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      )..debugWallClockMs = () => hostileTs;
      final spaceId = await wrongClock.createSpace('Aging key');
      final channelId = await wrongClock.createChannel(
        spaceId,
        name: 'private',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
      );
      expect(channelId, isNotNull);
      wrongClock.dispose();

      // Same device, same volume, same signing identity — restarted with the
      // clock corrected. Nothing in the log records that anything was ever
      // wrong; the 2027 stamp is simply what the epoch says about itself now.
      var wall = t0;
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      )..debugWallClockMs = () => wall;
      addTearDown(svc.dispose);
      final hostileEpoch = (await svc.stateOf(
        spaceId,
      ))!.protectedChannels[channelId!.hex]!.channelEpoch;
      expect(
        (await svc.load(spaceId))!.control
            .lastWhere(
              (entry) =>
                  entry.channelControl?.channelId == channelId &&
                  entry.channelControl?.channelEpoch == hostileEpoch,
            )
            .createdAtMs,
        greaterThanOrEqualTo(hostileTs),
        reason:
            'the epoch in service really does claim to have started in 2027',
      );
      final hostileKey = (await svc.load(
        spaceId,
      ))!.localChannelEpochKeys[keyIdOf(channelId, hostileEpoch)];
      expect(hostileKey, isNotNull);

      expect(
        await svc.sweepStaleChannelKeys(),
        0,
        reason:
            'the key has only just entered service as far as this device '
            'can tell',
      );

      // Thirty days and a minute of REAL service. Read off the entry's own
      // stamp the age is minus eleven months, so `now - started` never reached
      // the bound and this key was going to serve until 2027 — with no error,
      // no refusal and nothing at all to notice.
      wall = t0 + GroupService.protectedChannelKeyMaxAgeMs + 60000;
      expect(
        await svc.sweepStaleChannelKeys(),
        1,
        reason:
            'a key that has served its thirty days must be replaced, and '
            'this is the only assertion that can show a fail-OPEN closed: the '
            'absence of an error proves nothing here',
      );
      final rotatedEpoch = (await svc.stateOf(
        spaceId,
      ))!.protectedChannels[channelId.hex]!.channelEpoch;
      expect(rotatedEpoch, hostileEpoch + 1);
      final rotatedKey = (await svc.load(
        spaceId,
      ))!.localChannelEpochKeys[keyIdOf(channelId, rotatedEpoch)];
      expect(rotatedKey, isNotNull);
      expect(
        rotatedKey,
        isNot(hostileKey),
        reason: 'a rotation is new key MATERIAL, not a counter going up',
      );

      expect(
        await svc.sweepStaleChannelKeys(),
        0,
        reason: 'and the fresh key restarts the clock — this must not loop',
      );

      // Not once, by luck. The replacement ages at the same real rate and is
      // itself replaced thirty days later, which is what tells a clock that is
      // running apart from one that happened to fire.
      wall += GroupService.protectedChannelKeyMaxAgeMs + 60000;
      expect(await svc.sweepStaleChannelKeys(), 1);
      expect(
        (await svc.stateOf(
          spaceId,
        ))!.protectedChannels[channelId.hex]!.channelEpoch,
        rotatedEpoch + 1,
      );

      await storage.close();
    },
  );

  test(
    'a channel epoch dated into the past must not make a key born stale — one '
    'cheap entry per rekey of the whole channel is the other half of the same '
    'defect',
    () async {
      final t0 = DateTime.utc(2026, 8, 3, 12).millisecondsSinceEpoch;
      final ancient = t0 - const Duration(days: 3650).inMilliseconds;
      String keyIdOf(NodeId channelId, int epoch) => '${channelId.hex}:$epoch';

      // This device's whole life reads 2016. Nothing in the Space can
      // contradict it, and every epoch it introduces carries that number.
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      )..debugWallClockMs = () => ancient;
      addTearDown(ownerSvc.dispose);
      final spaceId = await ownerSvc.createSpace('Churned key');
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.setRole,
          target: bob,
          role: GroupRole.admin,
        ),
        isTrue,
      );
      final channelId = await ownerSvc.createChannel(
        spaceId,
        name: 'private',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
      );
      expect(channelId, isNotNull);
      expect(
        await ownerSvc.setChannelMembers(spaceId, channelId!, [bob]),
        isTrue,
      );

      // Bob's clock is honest, and bob is the device that runs maintenance.
      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      var wall = t0;
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      )..debugWallClockMs = () => wall;
      addTearDown(bobSvc.dispose);

      // Twice, because one rekey could be a legitimate replacement. Every
      // entry the wrong-clocked device writes used to cost the whole channel
      // another ML-KEM rekey per recipient on the very next maintenance pass,
      // for as long as it kept writing them.
      for (var round = 0; round < 2; round++) {
        if (round > 0) {
          expect(await ownerSvc.rotateChannelKey(spaceId, channelId), isTrue);
        }
        expect(
          await bobSvc.ingestSnapshot(
            ownerSvc.snapshotJson(
              (await ownerSvc.load(spaceId))!,
              recipient: bob,
            ),
          ),
          isTrue,
        );
        final servedEpoch = (await bobSvc.stateOf(
          spaceId,
        ))!.protectedChannels[channelId.hex]!.channelEpoch;
        final servedKey = (await bobSvc.load(
          spaceId,
        ))!.localChannelEpochKeys[keyIdOf(channelId, servedEpoch)];
        expect(servedKey, isNotNull);
        expect(
          (await bobSvc.load(spaceId))!.control
              .lastWhere(
                (entry) =>
                    entry.channelControl?.channelId == channelId &&
                    entry.channelControl?.channelEpoch == servedEpoch,
              )
              .createdAtMs,
          lessThan(t0),
          reason: 'round $round: the epoch really is stamped a decade ago',
        );

        expect(
          await bobSvc.sweepStaleChannelKeys(),
          0,
          reason:
              'round $round: a key that entered service here a moment ago '
              'is not thirty days old because its author says so',
        );
        expect(
          (await bobSvc.stateOf(
            spaceId,
          ))!.protectedChannels[channelId.hex]!.channelEpoch,
          servedEpoch,
          reason: 'round $round: and no epoch of this device\'s own was minted',
        );
        expect(
          (await bobSvc.load(spaceId))!.localChannelEpochKeys[keyIdOf(
            channelId,
            servedEpoch,
          )],
          servedKey,
          reason: 'round $round: the key in service is untouched',
        );
      }

      // Peers re-ship whole snapshots on every reconnect, and each one rewrites
      // this bundle. If ingest rebuilt the arrival moments instead of carrying
      // them, the age would restart on every sync and the bound would never
      // fire again — the same fail-open, reached from the other side.
      final servingEpoch = (await bobSvc.stateOf(
        spaceId,
      ))!.protectedChannels[channelId.hex]!.channelEpoch;
      expect(await ownerSvc.postMessage(spaceId, 'unrelated traffic'), isTrue);
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        (await bobSvc.stateOf(
          spaceId,
        ))!.protectedChannels[channelId.hex]!.channelEpoch,
        servingEpoch,
        reason: 'that sync changed no key — only the log around it',
      );

      // The bound is not disabled, only re-anchored — and this device really
      // can rotate this channel, so the zeroes above are a decision and not an
      // inability.
      wall = t0 + GroupService.protectedChannelKeyMaxAgeMs + 60000;
      expect(await bobSvc.sweepStaleChannelKeys(), 1);
      expect(
        (await bobSvc.stateOf(
          spaceId,
        ))!.protectedChannels[channelId.hex]!.channelEpoch,
        servingEpoch + 1,
      );

      await bobStorage.close();
      await ownerStorage.close();
    },
  );

  test(
    'a control row backdated by its author is floored at the moment this '
    'device first held it — and the floor never moves a claim earlier',
    () async {
      final t0 = DateTime.utc(2026, 8, 4, 9).millisecondsSinceEpoch;
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      var ownerWall = t0;
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner))
        ..debugWallClockMs = () => ownerWall;
      addTearDown(ownerSvc.dispose);
      final spaceId = await ownerSvc.createSpace('Floors');
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.setRole,
          target: bob,
          role: GroupRole.admin,
        ),
        isTrue,
      );

      // Bob's device joins here and now, holding the whole history in one
      // batch. It was not present for any of it.
      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      var bobWall = t0 + const Duration(minutes: 5).inMilliseconds;
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob))
        ..debugWallClockMs = () => bobWall;
      addTearDown(bobSvc.dispose);
      Future<void> sync() async {
        expect(
          await bobSvc.ingestSnapshot(
            ownerSvc.snapshotJson(
              (await ownerSvc.load(spaceId))!,
              recipient: bob,
            ),
          ),
          isTrue,
        );
      }

      await sync();
      final joined = (await bobSvc.load(spaceId))!;
      expect(joined.control, isNotEmpty);
      for (final entry in joined.control) {
        expect(
          joined.effectiveControlTimeMs(entry),
          entry.createdAtMs,
          reason:
              'a device that joined a moment ago knows nothing about when a '
              'row that predates it arrived, and must not invent "now" for '
              'the whole history it was handed',
        );
        expect(joined.controlReceipts[controlReceiptKey(entry)], 0);
      }

      // Now the owner writes a row and dates it a week before this Space
      // existed. Bob's device sees it for the first time today.
      bobWall = t0 + const Duration(hours: 1).inMilliseconds;
      final backdated = t0 - const Duration(days: 7).inMilliseconds;
      // A separate instance, because a live service's own stamps are
      // monotonic. Whether the number is a wrong clock or a chosen one is
      // exactly what nobody downstream can tell.
      final rewound = GroupService(ownerStorage, _FakeSigner(owner))
        ..debugWallClockMs = () => backdated;
      expect(
        await rewound.addControlOp(spaceId, ControlOp.setName, text: 'Renamed'),
        isTrue,
      );
      rewound.dispose();
      await sync();
      final after = (await bobSvc.load(spaceId))!;
      final lie = after.control.lastWhere(
        (entry) => entry.op == ControlOp.setName,
      );
      expect(lie.createdAtMs, backdated, reason: 'the claim is untouched');
      expect(
        after.effectiveControlTimeMs(lie),
        t0 + const Duration(hours: 1).inMilliseconds,
        reason:
            'but nothing this device decides may believe it is older '
            'than the moment it arrived here',
      );
      // The rows that were already here keep the zero they were given: the
      // floor is recorded once, on first sight, and never revised.
      for (final entry in after.control) {
        if (entry.op == ControlOp.setName) continue;
        expect(after.controlReceipts[controlReceiptKey(entry)], 0);
        expect(after.effectiveControlTimeMs(entry), entry.createdAtMs);
      }

      // A FLOOR, not a stamp: a row dated forward keeps its own claim, which
      // is what leaves `compareHeads` the only thing that orders the log.
      final forwardTs = t0 + const Duration(days: 365).inMilliseconds;
      final fastForward = GroupService(ownerStorage, _FakeSigner(owner))
        ..debugWallClockMs = () => forwardTs;
      expect(
        await fastForward.addControlOp(
          spaceId,
          ControlOp.setDescription,
          text: 'next year',
        ),
        isTrue,
      );
      fastForward.dispose();
      bobWall = t0 + const Duration(hours: 2).inMilliseconds;
      await sync();
      final withFuture = (await bobSvc.load(spaceId))!;
      final forward = withFuture.control.lastWhere(
        (entry) => entry.op == ControlOp.setDescription,
      );
      expect(
        withFuture.effectiveControlTimeMs(forward),
        forwardTs,
        reason:
            'the floor may only raise; a forward lie is not this map\'s '
            'problem and pretending otherwise would make it an order key',
      );

      // Re-shipped snapshots must not re-stamp anything. A peer reconnects and
      // sends the whole bundle again on every sync; if ingest rebuilt these,
      // every row would look as if it had just arrived and the floor under the
      // backdated one would be gone exactly when it is needed.
      bobWall = t0 + const Duration(days: 3).inMilliseconds;
      await sync();
      await sync();
      final resynced = (await bobSvc.load(spaceId))!;
      expect(
        resynced.effectiveControlTimeMs(lie),
        t0 + const Duration(hours: 1).inMilliseconds,
        reason: 'first sight, not last sight',
      );
      expect(
        resynced.controlReceipts,
        {
          ...after.controlReceipts,
          controlReceiptKey(forward):
              t0 + const Duration(hours: 2).inMilliseconds,
        },
        reason: 'two more syncs added nothing and moved nothing',
      );

      // Where it lives: beside the signed rows in this device's own blob, and
      // nowhere a peer could set it. A moment a peer chose would be the same
      // unauthenticated claim wearing a second name.
      final blob = await bobStorage.loadFile('group:${spaceId.hex}');
      expect(blob, isNotNull);
      final storedBundle = jsonDecode(utf8.decode(blob!)) as Map;
      expect(storedBundle['crx'], isA<Map>());
      expect(
        (storedBundle['crx'] as Map)[controlReceiptKey(lie)],
        t0 + const Duration(hours: 1).inMilliseconds,
      );
      bool carriesKey(Object? node, String key) => node is Map
          ? node.containsKey(key) ||
                node.values.any((value) => carriesKey(value, key))
          : node is List && node.any((value) => carriesKey(value, key));
      expect(
        carriesKey(
          jsonDecode(
            ownerSvc.snapshotJson(
              (await ownerSvc.load(spaceId))!,
              recipient: bob,
            ),
          ),
          'crx',
        ),
        isFalse,
        reason: 'never on the wire',
      );
      expect(
        carriesKey(storedBundle['c'], 'crx'),
        isFalse,
        reason: 'and never inside the bytes an author signed',
      );

      // It survives a restart, so it is persisted rather than re-invented.
      final reopened = GroupService(bobStorage, _FakeSigner(bob))
        ..debugWallClockMs = () => t0 + const Duration(days: 9).inMilliseconds;
      addTearDown(reopened.dispose);
      expect(
        (await reopened.load(spaceId))!.effectiveControlTimeMs(lie),
        t0 + const Duration(hours: 1).inMilliseconds,
      );

      await bobStorage.close();
      await ownerStorage.close();
    },
  );

  test(
    'failed membership transaction preserves member and protected channel epoch',
    () async {
      final storage = _ControlledGroupWriteStorage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await service.createSpace('Atomic membership');
      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final channelId = await service.createChannel(
        spaceId,
        name: 'private',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
      );
      expect(channelId, isNotNull);
      expect(
        await service.setChannelMembers(spaceId, channelId!, [bob]),
        isTrue,
      );
      final before = (await service.load(spaceId))!;
      final beforeState = (await service.stateOf(spaceId))!;
      final beforeChannelEpoch =
          beforeState.protectedChannels[channelId.hex]!.channelEpoch;

      storage.resetGroupWriteAttempts();
      storage.failNextGroupWrite = true;
      expect(
        await service.addControlOp(
          spaceId,
          ControlOp.removeMember,
          target: bob,
        ),
        isFalse,
      );
      expect(
        storage.groupWriteAttempts,
        1,
        reason: 'there must be no second, independently failing ACL write',
      );

      final after = (await service.load(spaceId))!;
      final afterState = (await service.stateOf(spaceId))!;
      expect(after.control, hasLength(before.control.length));
      expect(afterState.epoch, beforeState.epoch);
      expect(afterState.isMember(bob), isTrue);
      expect(
        afterState.protectedChannels[channelId.hex]!.channelEpoch,
        beforeChannelEpoch,
      );
      expect(
        await service.channelMembersOf(spaceId, channelId),
        containsAll([owner, bob]),
      );
      expect(
        after.localChannelEpochKeys.keys,
        unorderedEquals(before.localChannelEpochKeys.keys),
      );
    },
  );

  test(
    'the owner withdraws a moderator\'s authority from a date: what they did '
    'after it stops counting, what they did before it stands, and another '
    'moderator is not touched',
    () async {
      final t0 = DateTime.utc(2026, 8, 4, 8).millisecondsSinceEpoch;
      final boundaryMs = t0 + const Duration(hours: 6).inMilliseconds;
      final dave = _id(8);
      final erin = _id(9);
      final frank = _id(10);

      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      var ownerWall = t0;
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner))
        ..debugWallClockMs = () => ownerWall;
      addTearDown(ownerSvc.dispose);
      final spaceId = await ownerSvc.createSpace('Withdrawal');
      Future<void> add(NodeId member, GroupRole role) async {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: member,
            role: role,
          ),
          isTrue,
        );
      }

      await add(bob, GroupRole.admin);
      await add(carol, GroupRole.admin);
      await add(dave, GroupRole.member);
      await add(erin, GroupRole.member);
      await add(frank, GroupRole.member);
      await add(stranger, GroupRole.member);

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final carolStorage = FakeHvContainer().storage();
      await carolStorage.open(password: 'pw', createIfMissing: true);
      Future<void> push(GroupService to, NodeId recipient) async {
        expect(
          await to.ingestSnapshot(
            ownerSvc.snapshotJson(
              (await ownerSvc.load(spaceId))!,
              recipient: recipient,
            ),
          ),
          isTrue,
        );
      }

      Future<void> pull(GroupService from, NodeId sender) async {
        expect(
          await ownerSvc.ingestSnapshot(
            from.snapshotJson((await from.load(spaceId))!, recipient: owner),
          ),
          isTrue,
        );
      }

      // Two hours in: an honest silencing by the moderator who will later be
      // revoked. It is BEFORE the line the owner draws, and it must survive.
      ownerWall = t0 + const Duration(hours: 2).inMilliseconds;
      final bobEarly = GroupService(bobStorage, _FakeSigner(bob))
        ..debugWallClockMs = () => t0 + const Duration(hours: 2).inMilliseconds;
      await push(bobEarly, bob);
      expect(
        await bobEarly.addControlOp(spaceId, ControlOp.mute, target: dave),
        isTrue,
      );
      await pull(bobEarly, bob);
      bobEarly.dispose();

      // Carol, a second moderator nobody is accusing of anything, removes
      // frank AFTER the line. Nothing about this may move.
      ownerWall = t0 + const Duration(hours: 8).inMilliseconds;
      final carolSvc = GroupService(carolStorage, _FakeSigner(carol))
        ..debugWallClockMs = () => t0 + const Duration(hours: 8).inMilliseconds;
      await push(carolSvc, carol);
      expect(
        await carolSvc.addControlOp(spaceId, ControlOp.ban, target: frank),
        isTrue,
      );
      await pull(carolSvc, carol);
      carolSvc.dispose();

      // And bob removes erin after the line — the row the owner is about to
      // unmake.
      ownerWall = t0 + const Duration(hours: 9).inMilliseconds;
      final bobLate = GroupService(bobStorage, _FakeSigner(bob))
        ..debugWallClockMs = () => t0 + const Duration(hours: 9).inMilliseconds;
      await push(bobLate, bob);
      expect(
        await bobLate.addControlOp(spaceId, ControlOp.ban, target: erin),
        isTrue,
      );
      await pull(bobLate, bob);
      bobLate.dispose();

      final before = (await ownerSvc.stateOf(spaceId))!;
      expect(before.isMember(erin), isFalse);
      expect(before.isMember(frank), isFalse);
      expect(before.memberOf(dave)!.muted, isTrue);

      ownerWall = t0 + const Duration(hours: 10).inMilliseconds;
      expect(
        await ownerSvc.setSpaceAuthorityBoundary(
          spaceId,
          bob,
          effectiveFromMs: boundaryMs,
        ),
        isTrue,
      );

      final after = (await ownerSvc.stateOf(spaceId))!;
      expect(
        after.isMember(erin),
        isTrue,
        reason:
            'the removal was written with authority the owner has now '
            'declared void over that stretch of bob\'s chain, so it never '
            'happened and erin is in the Space',
      );
      expect(
        after.memberOf(dave)!.muted,
        isTrue,
        reason:
            'bob\'s honest silencing predates the line and stands — a '
            'withdrawal is not a pardon for everything its target ever did',
      );
      expect(
        after.isMember(frank),
        isFalse,
        reason:
            'carol was not named and nothing of hers moves, even though '
            'her row is later than the line',
      );
      expect(
        after.roleOf(bob),
        GroupRole.admin,
        reason:
            'withdrawing past authority is not the same statement as '
            'taking the role away going forward; that is a separate row',
      );
      final withdrawal = after.authorityWithdrawalFor(bob);
      expect(withdrawal, isNotNull);
      expect(withdrawal!.effectiveFromMs, boundaryMs);
      expect(withdrawal.fromSeq, 0, reason: 'bob\'s first row keeps its force');
      expect(after.authorityWithdrawalFor(carol), isNull);

      // Every member folds the same log to the same answer, including one that
      // was not here for any of it.
      final strangerStorage = FakeHvContainer().storage();
      await strangerStorage.open(password: 'pw', createIfMissing: true);
      final strangerSvc = GroupService(strangerStorage, _FakeSigner(stranger))
        ..debugWallClockMs = () => t0 + const Duration(days: 40).inMilliseconds;
      addTearDown(strangerSvc.dispose);
      await push(strangerSvc, stranger);
      final theirs = (await strangerSvc.stateOf(spaceId))!;
      expect(theirs.isMember(erin), isTrue);
      expect(theirs.memberOf(dave)!.muted, isTrue);
      expect(theirs.isMember(frank), isFalse);

      await strangerStorage.close();
      await carolStorage.close();
      await bobStorage.close();
      await ownerStorage.close();
    },
  );

  test(
    'a moderator who dates the ban before the line does not slip under it, '
    'because the owner drew the line where its OWN device first saw the rows',
    () async {
      final t0 = DateTime.utc(2026, 8, 4, 8).millisecondsSinceEpoch;
      final boundaryMs = t0 + const Duration(hours: 6).inMilliseconds;
      final dave = _id(8);
      final erin = _id(9);

      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      var ownerWall = t0;
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner))
        ..debugWallClockMs = () => ownerWall;
      addTearDown(ownerSvc.dispose);
      final spaceId = await ownerSvc.createSpace('Backdating');
      for (final (member, role) in [
        (bob, GroupRole.admin),
        (dave, GroupRole.member),
        (erin, GroupRole.member),
      ]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: member,
            role: role,
          ),
          isTrue,
        );
      }

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      Future<void> exchange(GroupService peer, NodeId who) async {
        expect(
          await peer.ingestSnapshot(
            ownerSvc.snapshotJson(
              (await ownerSvc.load(spaceId))!,
              recipient: who,
            ),
          ),
          isTrue,
        );
      }

      Future<void> deliver(GroupService peer) async {
        expect(
          await ownerSvc.ingestSnapshot(
            peer.snapshotJson((await peer.load(spaceId))!, recipient: owner),
          ),
          isTrue,
        );
      }

      // Hour two, honest and on time. The owner's device holds it well before
      // the line, so this row's arrival moment is below it too.
      ownerWall = t0 + const Duration(hours: 2).inMilliseconds;
      final honest = GroupService(bobStorage, _FakeSigner(bob))
        ..debugWallClockMs = () => t0 + const Duration(hours: 2).inMilliseconds;
      await exchange(honest, bob);
      expect(
        await honest.addControlOp(spaceId, ControlOp.mute, target: dave),
        isTrue,
      );
      await deliver(honest);
      honest.dispose();

      // Hour nine, and bob can see what is coming. The row is written now and
      // dated to hour one: signed, structurally perfect, and claiming to
      // predate any line an owner would draw over today.
      final backdatedTs = t0 + const Duration(hours: 1).inMilliseconds;
      ownerWall = t0 + const Duration(hours: 9).inMilliseconds;
      final lying = GroupService(bobStorage, _FakeSigner(bob))
        ..debugWallClockMs = () => backdatedTs;
      await exchange(lying, bob);
      expect(
        await lying.addControlOp(spaceId, ControlOp.ban, target: erin),
        isTrue,
      );
      await deliver(lying);
      lying.dispose();

      final bundle = (await ownerSvc.load(spaceId))!;
      final lie = bundle.control.lastWhere(
        (entry) => entry.author == bob && entry.op == ControlOp.ban,
      );
      expect(
        lie.createdAtMs,
        lessThan(boundaryMs),
        reason: 'the row really does claim to predate the line',
      );
      expect(
        bundle.effectiveControlTimeMs(lie),
        greaterThan(boundaryMs),
        reason: 'and this device really did first hold it afterwards',
      );
      expect((await ownerSvc.stateOf(spaceId))!.isMember(erin), isFalse);

      ownerWall = t0 + const Duration(hours: 10).inMilliseconds;
      expect(
        await ownerSvc.setSpaceAuthorityBoundary(
          spaceId,
          bob,
          effectiveFromMs: boundaryMs,
        ),
        isTrue,
      );

      final after = (await ownerSvc.stateOf(spaceId))!;
      expect(
        after.isMember(erin),
        isTrue,
        reason:
            'a date the row chose for itself must not decide whether the '
            'owner\'s line reaches it — this is the assertion the whole '
            'arrival-moment floor exists for',
      );
      expect(
        after.memberOf(dave)!.muted,
        isTrue,
        reason:
            'and the honest row that really was early is untouched, so '
            'the line is a line and not a blanket',
      );
      expect(after.authorityWithdrawalFor(bob)!.fromSeq, 0);

      await bobStorage.close();
      await ownerStorage.close();
    },
  );

  test(
    'two devices holding different arrival moments fold the withdrawn log to '
    'the same state, because what travels is a chain position',
    () async {
      final t0 = DateTime.utc(2026, 8, 4, 8).millisecondsSinceEpoch;
      final dave = _id(8);
      final erin = _id(9);
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      var ownerWall = t0;
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner))
        ..debugWallClockMs = () => ownerWall;
      addTearDown(ownerSvc.dispose);
      final spaceId = await ownerSvc.createSpace('Convergence');
      for (final (member, role) in [
        (bob, GroupRole.admin),
        (carol, GroupRole.member),
        (dave, GroupRole.member),
        (erin, GroupRole.member),
      ]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: member,
            role: role,
          ),
          isTrue,
        );
      }

      // Carol's device is here for all of it and stamps every row as it
      // arrives, minute by minute.
      final carolStorage = FakeHvContainer().storage();
      await carolStorage.open(password: 'pw', createIfMissing: true);
      var carolWall = t0 + const Duration(minutes: 1).inMilliseconds;
      final carolSvc = GroupService(carolStorage, _FakeSigner(carol))
        ..debugWallClockMs = () => carolWall;
      addTearDown(carolSvc.dispose);
      Future<void> carolSyncs() async {
        expect(
          await carolSvc.ingestSnapshot(
            ownerSvc.snapshotJson(
              (await ownerSvc.load(spaceId))!,
              recipient: carol,
            ),
          ),
          isTrue,
        );
      }

      await carolSyncs();

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      ownerWall = t0 + const Duration(hours: 2).inMilliseconds;
      carolWall = t0 + const Duration(hours: 2).inMilliseconds;
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob))
        ..debugWallClockMs = () => t0 + const Duration(hours: 2).inMilliseconds;
      addTearDown(bobSvc.dispose);
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        await bobSvc.addControlOp(spaceId, ControlOp.mute, target: dave),
        isTrue,
      );
      expect(
        await bobSvc.addControlOp(spaceId, ControlOp.ban, target: erin),
        isTrue,
      );
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );
      await carolSyncs();

      ownerWall = t0 + const Duration(hours: 3).inMilliseconds;
      carolWall = t0 + const Duration(hours: 3).inMilliseconds;
      expect(
        await ownerSvc.setSpaceAuthorityBoundary(
          spaceId,
          bob,
          effectiveFromMs: t0 + const Duration(hours: 1).inMilliseconds,
        ),
        isTrue,
      );
      await carolSyncs();

      // Dave's device sees the whole thing, finished, a month later. Every row
      // it holds arrived in one batch it was not present for, so it has no
      // arrival moment for any of them — the opposite end of the range.
      final daveStorage = FakeHvContainer().storage();
      await daveStorage.open(password: 'pw', createIfMissing: true);
      final daveSvc = GroupService(daveStorage, _FakeSigner(dave))
        ..debugWallClockMs = () => t0 + const Duration(days: 30).inMilliseconds;
      addTearDown(daveSvc.dispose);
      expect(
        await daveSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: dave,
          ),
        ),
        isTrue,
      );

      final ownerBundle = (await ownerSvc.load(spaceId))!;
      final carolBundle = (await carolSvc.load(spaceId))!;
      final daveBundle = (await daveSvc.load(spaceId))!;
      expect(
        carolBundle.controlReceipts,
        isNot(ownerBundle.controlReceipts),
        reason:
            'the premise: these devices genuinely disagree about when '
            'these rows turned up',
      );
      expect(
        daveBundle.controlReceipts.values.toSet(),
        {0},
        reason: 'and this one has no opinion about it at all',
      );
      expect(daveBundle.controlReceipts, isNot(carolBundle.controlReceipts));

      String shape(GroupState state) => jsonEncode({
        'members': {
          for (final member in state.members.values)
            member.nodeId.hex: '${member.role.name}:${member.muted}',
        },
        'epoch': state.epoch,
        'policyVersion': state.policyVersion,
        'withdrawn': {
          for (final entry in state.authorityBoundaries.entries)
            entry.key: [
              for (final boundary in entry.value)
                '${boundary.fromSeq}:${boundary.restore}',
            ],
        },
      });

      final ownerShape = shape((await ownerSvc.stateOf(spaceId))!);
      expect(shape((await carolSvc.stateOf(spaceId))!), ownerShape);
      expect(shape((await daveSvc.stateOf(spaceId))!), ownerShape);
      expect(
        (await daveSvc.stateOf(spaceId))!.isMember(erin),
        isTrue,
        reason:
            'and the shared answer is the withdrawn one, not a fold that '
            'quietly skipped the boundary',
      );
      expect(
        (await daveSvc.stateOf(spaceId))!.memberOf(dave)!.muted,
        isFalse,
        reason:
            'both of bob\'s rows fall after this line, and a device with '
            'no arrival moments of its own reaches the same conclusion as one '
            'that watched them land',
      );

      await daveStorage.close();
      await carolStorage.close();
      await bobStorage.close();
      await ownerStorage.close();
    },
  );

  test(
    'authority can be returned, and returning it is forward-only: the rows '
    'already withdrawn stay withdrawn and the next ones count again',
    () async {
      final t0 = DateTime.utc(2026, 8, 4, 8).millisecondsSinceEpoch;
      final erin = _id(9);
      final frank = _id(10);
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      var ownerWall = t0;
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner))
        ..debugWallClockMs = () => ownerWall;
      addTearDown(ownerSvc.dispose);
      final spaceId = await ownerSvc.createSpace('Return');
      for (final (member, role) in [
        (bob, GroupRole.admin),
        (erin, GroupRole.member),
        (frank, GroupRole.member),
      ]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: member,
            role: role,
          ),
          isTrue,
        );
      }

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      Future<GroupService> bobAt(int at) async {
        final svc = GroupService(bobStorage, _FakeSigner(bob))
          ..debugWallClockMs = () => at;
        expect(
          await svc.ingestSnapshot(
            ownerSvc.snapshotJson(
              (await ownerSvc.load(spaceId))!,
              recipient: bob,
            ),
          ),
          isTrue,
        );
        return svc;
      }

      Future<void> collect(GroupService svc) async {
        expect(
          await ownerSvc.ingestSnapshot(
            svc.snapshotJson((await svc.load(spaceId))!, recipient: owner),
          ),
          isTrue,
        );
      }

      ownerWall = t0 + const Duration(hours: 2).inMilliseconds;
      final first = await bobAt(t0 + const Duration(hours: 2).inMilliseconds);
      expect(
        await first.addControlOp(spaceId, ControlOp.ban, target: erin),
        isTrue,
      );
      await collect(first);
      first.dispose();

      ownerWall = t0 + const Duration(hours: 3).inMilliseconds;
      expect(
        await ownerSvc.setSpaceAuthorityBoundary(
          spaceId,
          bob,
          effectiveFromMs: t0 + const Duration(hours: 1).inMilliseconds,
        ),
        isTrue,
      );
      expect((await ownerSvc.stateOf(spaceId))!.isMember(erin), isTrue);

      ownerWall = t0 + const Duration(hours: 4).inMilliseconds;
      expect(
        await ownerSvc.setSpaceAuthorityBoundary(
          spaceId,
          bob,
          effectiveFromMs: t0 + const Duration(hours: 4).inMilliseconds,
          restore: true,
        ),
        isTrue,
      );

      final restored = (await ownerSvc.stateOf(spaceId))!;
      expect(
        restored.authorityWithdrawalFor(bob),
        isNull,
        reason: 'bob may act again',
      );
      expect(
        restored.isMember(erin),
        isTrue,
        reason:
            'returning a role is not a statement that what was done '
            'without one was fine — the withdrawn removal stays withdrawn',
      );

      // And the next row bob writes counts, which is the entire point of
      // being able to return authority at all.
      ownerWall = t0 + const Duration(hours: 5).inMilliseconds;
      final second = await bobAt(t0 + const Duration(hours: 5).inMilliseconds);
      expect(
        await second.addControlOp(spaceId, ControlOp.ban, target: frank),
        isTrue,
        reason:
            'bob\'s device must be able to continue a chain whose earlier '
            'row was withdrawn, and must see the row it writes survive the '
            'fold — a client that cannot write again is a restoration in name '
            'only',
      );
      await collect(second);
      second.dispose();
      expect(
        (await ownerSvc.stateOf(spaceId))!.isMember(frank),
        isFalse,
        reason:
            'a returned moderator is a moderator; if the old ban was in '
            'fact deserved it costs one row to issue it again',
      );

      // A second withdrawal after the return still reaches only forward of
      // where it is drawn.
      ownerWall = t0 + const Duration(hours: 6).inMilliseconds;
      expect(
        await ownerSvc.setSpaceAuthorityBoundary(
          spaceId,
          bob,
          effectiveFromMs:
              t0 + const Duration(hours: 4, minutes: 30).inMilliseconds,
        ),
        isTrue,
      );
      expect(
        (await ownerSvc.stateOf(spaceId))!.isMember(frank),
        isTrue,
        reason: 'the later row falls after the later line and is withdrawn too',
      );

      await bobStorage.close();
      await ownerStorage.close();
    },
  );

  test('only the owner may withdraw authority, never against the owner, and a '
      'withdrawal does not undo a deleted message or a key rotation', () async {
    final t0 = DateTime.utc(2026, 8, 4, 8).millisecondsSinceEpoch;
    final erin = _id(9);
    final ownerStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'pw', createIfMissing: true);
    final ownerSvc = GroupService(
      ownerStorage,
      _FakeSigner(owner),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
    )..debugWallClockMs = () => t0;
    addTearDown(ownerSvc.dispose);
    final spaceId = await ownerSvc.createSpace('Limits');
    for (final (member, role) in [
      (bob, GroupRole.admin),
      (carol, GroupRole.admin),
      (erin, GroupRole.member),
    ]) {
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: member,
          role: role,
        ),
        isTrue,
      );
    }

    // An admin is not allowed to reach backwards over another admin: this is
    // the one operation that rewrites what already happened, and two of them
    // pointed at each other is a way to unmake authority for the price of a
    // control row.
    final carolStorage = FakeHvContainer().storage();
    await carolStorage.open(password: 'pw', createIfMissing: true);
    final carolSvc = GroupService(carolStorage, _FakeSigner(carol))
      ..debugWallClockMs = () => t0 + const Duration(hours: 1).inMilliseconds;
    addTearDown(carolSvc.dispose);
    expect(
      await carolSvc.ingestSnapshot(
        ownerSvc.snapshotJson(
          (await ownerSvc.load(spaceId))!,
          recipient: carol,
        ),
      ),
      isTrue,
    );
    expect(
      await carolSvc.setSpaceAuthorityBoundary(
        spaceId,
        bob,
        effectiveFromMs: t0,
      ),
      isFalse,
      reason: 'an admin holds no such thing',
    );
    // Nor may the owner aim it at the owner: the boundary that cannot touch
    // ownership is what keeps it from unmaking the authority that issued it.
    expect(
      await ownerSvc.setSpaceAuthorityBoundary(
        spaceId,
        owner,
        effectiveFromMs: t0,
      ),
      isFalse,
    );

    // A removal by the revoked moderator rotated the key. The withdrawal
    // puts erin back — and does NOT pretend the rotation never happened.
    final bobStorage = FakeHvContainer().storage();
    await bobStorage.open(password: 'pw', createIfMissing: true);
    final bobSvc = GroupService(
      bobStorage,
      _FakeSigner(bob),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
    )..debugWallClockMs = () => t0 + const Duration(hours: 2).inMilliseconds;
    addTearDown(bobSvc.dispose);
    expect(
      await bobSvc.ingestSnapshot(
        ownerSvc.snapshotJson((await ownerSvc.load(spaceId))!, recipient: bob),
      ),
      isTrue,
    );
    expect(
      await bobSvc.addControlOp(spaceId, ControlOp.ban, target: erin),
      isTrue,
    );
    expect(
      await ownerSvc.ingestSnapshot(
        bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
      ),
      isTrue,
    );
    final banned = (await ownerSvc.stateOf(spaceId))!;
    expect(banned.isMember(erin), isFalse);
    final rotatedEpoch = banned.epoch;

    ownerSvc.debugWallClockMs = () =>
        t0 + const Duration(hours: 3).inMilliseconds;
    expect(
      await ownerSvc.setSpaceAuthorityBoundary(
        spaceId,
        bob,
        effectiveFromMs: t0 + const Duration(hours: 1).inMilliseconds,
      ),
      isTrue,
    );
    final after = (await ownerSvc.stateOf(spaceId))!;
    expect(after.isMember(erin), isTrue);
    expect(
      after.epoch,
      rotatedEpoch + 1,
      reason:
          'exactly one more than the removal left behind: the key '
          'material reached every member the moment that row was published '
          'and no later row recalls it, so the withdrawal keeps the count '
          'and the follow-up rotation adds the one key erin can be given. '
          'Un-counting the removal would leave every later descriptor in '
          'this Space off by one, which is a whole line of rotations lost '
          'to undo a single ban',
    );
    expect(
      after.epochDescriptor,
      isNotNull,
      reason:
          'and the Space still has a key a returning member can be '
          'given, which is what the follow-up rotation is for',
    );
    // Another author's rotation, precomputed against the roster as it was
    // before erin came back, must still land. This is the cascade the kept
    // count and the relaxed recipient check exist to prevent.
    final carolRotator = GroupService(
      carolStorage,
      _FakeSigner(carol),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
    )..debugWallClockMs = () => t0 + const Duration(hours: 4).inMilliseconds;
    addTearDown(carolRotator.dispose);
    expect(
      await carolRotator.ingestSnapshot(
        ownerSvc.snapshotJson(
          (await ownerSvc.load(spaceId))!,
          recipient: carol,
        ),
      ),
      isTrue,
    );
    expect(
      await carolRotator.addControlOp(spaceId, ControlOp.rotateEpoch),
      isTrue,
    );
    expect(
      await ownerSvc.ingestSnapshot(
        carolRotator.snapshotJson(
          (await carolRotator.load(spaceId))!,
          recipient: owner,
        ),
      ),
      isTrue,
    );
    final rotated = (await ownerSvc.stateOf(spaceId))!;
    expect(
      rotated.epoch,
      after.epoch + 1,
      reason: 'an untouched moderator\'s rotation is not collateral damage',
    );
    expect(rotated.epochDescriptor, isNotNull);

    await bobStorage.close();
    await carolStorage.close();
    await ownerStorage.close();
  });

  test(
    'reactions: toggle on/off, aggregate, and survive snapshot round-trip',
    () async {
      final s1 = FakeHvContainer().storage();
      await s1.open(password: 'pw', createIfMissing: true);
      final owned = GroupService(s1, _FakeSigner(owner));
      final gid = await owned.createGroup('G');
      await owned.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );
      await owned.postMessage(gid, 'react to me');
      final msg = (await owned.messagesOf(gid)).single;
      final ref = msg.ref;

      // Owner reacts 👍.
      expect(await owned.react(gid, ref, '👍'), isTrue);
      var agg = await owned.reactionsOf(gid);
      expect(agg[ref]!['👍'], contains(owner));

      // Bob (same store) reacts ❤ on the same message → both counted.
      final bobDev = GroupService(s1, _FakeSigner(bob));
      await bobDev.react(gid, ref, '❤');
      agg = await owned.reactionsOf(gid);
      expect(agg[ref]!['👍'], contains(owner));
      expect(agg[ref]!['❤'], contains(bob));

      // Owner taps 👍 again → toggles OFF (latest-per-author-target wins).
      await owned.react(gid, ref, '👍');
      agg = await owned.reactionsOf(gid);
      expect(agg[ref]?['👍'] ?? const [], isNot(contains(owner)));
      expect(agg[ref]!['❤'], contains(bob), reason: 'bob still reacts');

      // A fresh device materializes the reactions via the full snapshot.
      final s2 = FakeHvContainer().storage();
      await s2.open(password: 'pw', createIfMissing: true);
      final carolDev = GroupService(s2, _FakeSigner(carol));
      await carolDev.ingestSnapshot(
        owned.snapshotJson((await owned.load(gid))!),
      );
      final got = await carolDev.reactionsOf(gid);
      expect(got[ref]!['❤'], contains(bob));
    },
  );

  test('replyTo is signed + round-trips; a plain message omits it', () {
    GroupMessage base({String? rt}) => GroupMessage(
      groupId: _id(2),
      author: owner,
      seq: 1,
      prevHash: '',
      body: 'reply body',
      policyVersion: 0,
      createdAtMs: 9,
      signature: Uint8List(0),
      replyTo: rt,
    );
    final withReply = base(rt: '${bob.hex}:3').canonicalBytes();
    final plain = base().canonicalBytes();
    expect(
      withReply,
      isNot(equals(plain)),
      reason: 'the reply ref is inside the signed bytes (tamper-evident)',
    );
    expect(
      String.fromCharCodes(plain).contains('"rt"'),
      isFalse,
      reason: 'a non-reply message signs as before the field existed',
    );
    final rt = GroupMessage.fromJson(base(rt: '${bob.hex}:3').toJson())!;
    expect(rt.replyTo, '${bob.hex}:3');
    // The ref of a message resolves to its (author, seq) identity.
    expect(base().ref, '${owner.hex}:1');
  });

  test('a delta merges on a peer that already has the group', () async {
    // Owner device.
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    String? lastDelta;
    final owned = GroupService(
      s1,
      _FakeSigner(owner),
      send: (peer, gid, json) async => lastDelta = json,
    );
    final gid = await owned.createGroup('Shared');
    await owned.addControlOp(
      gid,
      ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
    );

    // Bob materializes from the FULL snapshot (the addMember broadcast).
    final s2 = FakeHvContainer().storage();
    await s2.open(password: 'pw', createIfMissing: true);
    final bobDev = GroupService(s2, _FakeSigner(bob));
    await bobDev.ingestSnapshot(owned.snapshotJson((await owned.load(gid))!));
    expect(await bobDev.messagesOf(gid), isEmpty);

    // Owner posts → only the delta is sent; Bob ingests it and sees the message.
    await owned.postMessage(gid, 'hi bob');
    await pump();
    expect(lastDelta, isNotNull);
    await bobDev.ingestSnapshot(lastDelta!);
    expect((await bobDev.messagesOf(gid)).single.body, 'hi bob');
  });

  test('ingestControl dedups on (author, seq)', () async {
    final (svc, _) = await setup();
    final gid = await svc.createGroup('G');
    final initial = await svc.load(gid);
    final authored = initial!.control
        .where((entry) => entry.author == owner)
        .toList();
    final head = authored.isEmpty
        ? null
        : authored.reduce((left, right) => left.seq > right.seq ? left : right);
    final e = _FakeSigner(owner).signControl(
      ControlEntry(
        version: 2,
        groupId: gid,
        author: owner,
        seq: head == null ? 0 : head.seq + 1,
        prevHash: head == null ? '' : controlEntryHash(head),
        op: ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: 1,
        signature: Uint8List(0),
      ),
    );
    await svc.ingestControl(gid, e);
    await svc.ingestControl(gid, e); // duplicate
    final b = await svc.load(gid);
    expect(
      b!.control.where((entry) => entry.op == ControlOp.addMember).length,
      1,
    );
    expect((await svc.stateOf(gid))!.isMember(bob), isTrue);
  });

  test('new control rows form a contiguous signed v2/v3 chain', () async {
    final (svc, _) = await setup();
    final gid = await svc.createGroup('Control chain');
    expect(
      await svc.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      ),
      isTrue,
    );
    expect(await svc.addControlOp(gid, ControlOp.mute, target: bob), isTrue);

    final authored =
        (await svc.load(
            gid,
          ))!.control.where((entry) => entry.author == owner).toList()
          ..sort((left, right) => left.seq.compareTo(right.seq));
    expect(authored, isNotEmpty);
    for (var index = 0; index < authored.length; index++) {
      final entry = authored[index];
      expect(entry.version, 2);
      expect(entry.seq, index);
      expect(
        entry.prevHash,
        index == 0 ? isEmpty : controlEntryHash(authored[index - 1]),
      );
      final roundTrip = ControlEntry.fromJson(entry.toJson());
      expect(roundTrip, isNotNull);
      expect(controlEntryHash(roundTrip!), controlEntryHash(entry));
    }
  });

  test(
    'control fork evidence converges through same-seq head-hash sync',
    () async {
      final baseStorage = FakeHvContainer().storage();
      await baseStorage.open(password: 'pw', createIfMissing: true);
      final base = GroupService(baseStorage, _FakeSigner(owner));
      final gid = await base.createGroup('Fork convergence');
      final initial = (await base.load(gid))!;
      final head = initial.control.isEmpty ? null : initial.control.single;

      ControlEntry fork(NodeId target, int timestamp) =>
          _FakeSigner(owner).signControl(
            ControlEntry(
              version: 2,
              groupId: gid,
              author: owner,
              seq: head == null ? 0 : head.seq + 1,
              prevHash: head == null ? '' : controlEntryHash(head),
              op: ControlOp.addMember,
              target: target,
              role: GroupRole.member,
              policyVersion: 0,
              createdAtMs: timestamp,
              signature: Uint8List(0),
            ),
          );

      final leftOut = <String>[];
      final rightOut = <String>[];
      final leftStorage = FakeHvContainer().storage();
      final rightStorage = FakeHvContainer().storage();
      await leftStorage.open(password: 'pw', createIfMissing: true);
      await rightStorage.open(password: 'pw', createIfMissing: true);
      final left = GroupService(
        leftStorage,
        _FakeSigner(owner),
        send: (_, _, payload) async => leftOut.add(payload),
      );
      final right = GroupService(
        rightStorage,
        _FakeSigner(owner),
        send: (_, _, payload) async => rightOut.add(payload),
      );
      final genesis = base.snapshotJson(initial, recipient: owner);
      expect(await left.ingestSnapshot(genesis), isTrue);
      expect(await right.ingestSnapshot(genesis), isTrue);
      await left.ingestControl(gid, fork(bob, 2000));
      await right.ingestControl(gid, fork(carol, 2001));
      expect((await left.stateOf(gid))!.isMember(bob), isTrue);
      expect((await right.stateOf(gid))!.isMember(carol), isTrue);

      final leftVector = (await left.buildGroupSyncRequest(gid))!;
      final rightVector = (await right.buildGroupSyncRequest(gid))!;
      expect(
        ((leftVector['c'] as Map)[owner.hex] as Map)['s'],
        head == null ? 0 : head.seq + 1,
      );
      expect(
        ((leftVector['c'] as Map)[owner.hex] as Map)['h'],
        isNot(((rightVector['c'] as Map)[owner.hex] as Map)['h']),
      );

      expect(await left.handleGroupSyncRequest(owner, rightVector), isTrue);
      expect(await right.handleGroupSyncRequest(owner, leftVector), isTrue);
      expect(leftOut, hasLength(1));
      expect(rightOut, hasLength(1));
      await left.ingestSnapshot(rightOut.single);
      await right.ingestSnapshot(leftOut.single);

      final leftState = (await left.stateOf(gid))!;
      final rightState = (await right.stateOf(gid))!;
      expect(leftState.isMember(bob), isFalse);
      expect(leftState.isMember(carol), isFalse);
      expect(rightState.isMember(bob), isFalse);
      expect(rightState.isMember(carol), isFalse);
      expect((await left.load(gid))!.control, hasLength(2));
      expect((await right.load(gid))!.control, hasLength(2));
      expect(
        await left.renameGroup(gid, 'must not build on a fork'),
        isFalse,
        reason: 'local writers fail closed until equivocation is resolved',
      );
      expect((await left.stateOf(gid))!.name, 'Fork convergence');
    },
  );

  test(
    'rename: owner renames, name folds + lists; a plain member cannot',
    () async {
      // Owner device, capturing what gets broadcast so we can confirm it's a
      // DELTA (a setName control op ships without re-sending the whole log).
      final s1 = FakeHvContainer().storage();
      await s1.open(password: 'pw', createIfMissing: true);
      String? lastDelta;
      final owned = GroupService(
        s1,
        _FakeSigner(owner),
        send: (peer, gid, json) async => lastDelta = json,
      );
      final gid = await owned.createGroup('Old name');
      await owned.addControlOp(
        gid,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );

      // Owner renames → state folds the new name and the list reflects it.
      expect(await owned.renameGroup(gid, 'New name'), isTrue);
      expect((await owned.stateOf(gid))!.name, 'New name');
      expect((await owned.listGroups()).single.name, 'New name');
      expect(lastDelta, isNotNull); // a delta, not a full snapshot

      // Bob materializes from the owner's snapshot: he inherits the new name.
      final s2 = FakeHvContainer().storage();
      await s2.open(password: 'pw', createIfMissing: true);
      final bobDev = GroupService(s2, _FakeSigner(bob));
      await bobDev.ingestSnapshot(owned.snapshotJson((await owned.load(gid))!));
      expect((await bobDev.stateOf(gid))!.name, 'New name');

      // A plain member cannot rename: the op is rejected, the name is unchanged
      // on the owner's authoritative view.
      expect(await bobDev.renameGroup(gid, 'Hijacked'), isFalse);
      expect((await bobDev.stateOf(gid))!.name, 'New name');
    },
  );

  test(
    'Space profile keeps genesis visibility and replicates signed description edits',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      String? lastDelta;
      final ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (_, _, payload) async => lastDelta = payload,
      );
      final spaceId = await ownerService.createSpace(
        'Field lab',
        description: 'Initial field notes',
        visibility: SpaceVisibility.secret,
      );
      await ownerService.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      );

      final initial = (await ownerService.listSpaces()).single;
      expect(initial.description, 'Initial field notes');
      expect(initial.visibility, SpaceVisibility.secret);
      expect(initial.discoverable, isFalse);

      expect(
        await ownerService.setSpaceDescription(
          spaceId,
          'Verified protocols and meetups',
        ),
        isTrue,
      );
      expect(
        (await ownerService.stateOf(spaceId))!.description,
        'Verified protocols and meetups',
      );
      expect(lastDelta, isNotNull);

      final memberStorage = FakeHvContainer().storage();
      await memberStorage.open(password: 'pw', createIfMissing: true);
      final memberService = GroupService(memberStorage, _FakeSigner(bob));
      expect(
        await memberService.ingestSnapshot(
          ownerService.snapshotJson((await ownerService.load(spaceId))!),
        ),
        isTrue,
      );
      expect(
        (await memberService.stateOf(spaceId))!.description,
        'Verified protocols and meetups',
      );
      expect(
        await memberService.setSpaceDescription(spaceId, 'forged'),
        isFalse,
      );
      expect(
        await ownerService.setSpaceDescription(spaceId, 'x' * 4097),
        isFalse,
      );
    },
  );

  test(
    'Space rules and member acceptance converge through P2P deltas',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'owner', createIfMissing: true);
      await bobStorage.open(password: 'bob', createIfMissing: true);
      late GroupService ownerService;
      late GroupService bobService;
      var bobMaterialized = false;
      ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (peer, spaceId, payload) async {
          if (peer == bob && bobMaterialized) {
            expect(await bobService.ingestGroupEntry(owner, payload), isTrue);
          }
        },
      );
      bobService = GroupService(
        bobStorage,
        _FakeSigner(bob),
        send: (peer, spaceId, payload) async {
          if (peer == owner) {
            expect(await ownerService.ingestGroupEntry(bob, payload), isTrue);
          }
        },
      );

      final spaceId = await ownerService.createSpace('Rules replication');
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      await pump();
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      bobMaterialized = true;
      expect((await bobService.stateOf(spaceId))!.isMember(bob), isTrue);

      expect(
        await ownerService.publishSpaceRules(
          spaceId,
          fullText: 'Distribute only data that your current ACL permits.',
          summary: 'Respect ACL while redistributing.',
        ),
        isTrue,
      );
      await pump();
      expect((await bobService.stateOf(spaceId))!.currentRules?.version, 1);
      expect(
        (await bobService.stateOf(spaceId))!.requiresRulesAcceptance(bob),
        isTrue,
      );

      expect(await bobService.acceptSpaceRules(spaceId), isTrue);
      await pump();
      final ownerView = (await ownerService.stateOf(spaceId))!;
      expect(ownerView.rulesAcceptanceOf(bob)?.rulesVersion, 1);
      expect(ownerView.requiresRulesAcceptance(bob), isFalse);
    },
  );

  test(
    'Space post drafts persist locally, support large bodies and never enter P2P logs',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      final spaceId = await service.createSpace(
        'Draft lab',
        visibility: SpaceVisibility.public,
      );
      final largeBody = List.filled(6000, 'draft').join();
      final draftMedia = MediaObject(
        contentId: 'd' * 64,
        kind: 'video',
        name: 'draft.mp4',
        size: 512,
      );

      expect(
        await service.saveSpacePostDraft(
          spaceId,
          title: 'Work in progress',
          body: largeBody,
          type: SpacePostType.shortVideo,
          media: [draftMedia],
          scheduledAtMs:
              DateTime.now().millisecondsSinceEpoch +
              const Duration(hours: 1).inMilliseconds,
        ),
        isTrue,
      );
      final stored = await storage.loadFile(
        'space.post-draft.v1:${spaceId.hex}',
      );
      expect(stored, isNotNull);
      final storedJson = jsonDecode(utf8.decode(stored!)) as Map;
      // Keep this assertion close to persistence: the local draft must not be
      // confused with opaque content bytes or a signed post row.
      expect(storedJson['v'], 3);
      expect(storedJson['sid'], spaceId.hex);
      expect(storedJson['type'], SpacePostType.shortVideo.name);
      expect(storedJson['title'], 'Work in progress');
      expect((storedJson['body'] as String).length, largeBody.length);
      expect(storedJson['updatedAt'], isA<int>());
      expect((storedJson['media'] as List).single['cid'], 'd' * 64);
      final draft = await service.spacePostDraft(spaceId);
      expect(draft?.title, 'Work in progress');
      expect(draft?.body, largeBody);
      expect(draft?.type, SpacePostType.shortVideo);
      expect(draft?.media.single.name, 'draft.mp4');
      expect(draft?.scheduledAtMs, isA<int>());
      expect((await service.load(spaceId))!.posts, isEmpty);

      final reopened = GroupService(storage, _FakeSigner(owner));
      expect((await reopened.spacePostDraft(spaceId))?.body, largeBody);

      await Future.wait([
        service.saveSpacePostDraft(
          spaceId,
          title: 'First queued value',
          body: '',
          type: SpacePostType.post,
        ),
        service.saveSpacePostDraft(
          spaceId,
          title: 'Last queued value',
          body: '',
          type: SpacePostType.article,
        ),
      ]);
      expect(
        (await service.spacePostDraft(spaceId))?.title,
        'Last queued value',
      );

      expect(await service.clearSpacePostDraft(spaceId), isTrue);
      expect(await service.spacePostDraft(spaceId), isNull);
      expect(
        await service.saveSpacePostDraft(
          await service.createGroup('Not a community'),
          title: 'Must stay unavailable',
          body: '',
          type: SpacePostType.post,
        ),
        isFalse,
      );
    },
  );

  test('two posts scheduled at once do not lose one another', () async {
    // The queue index is read and written back across awaits, so without the
    // mutation gate both calls start from the same snapshot and the second
    // write drops the first job. Scheduling is a local action, but two
    // composer screens — or one impatient double-tap — reach it together.
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final service = GroupService(storage, _FakeSigner(owner));
    addTearDown(service.dispose);
    final spaceId = await service.createSpace(
      'Concurrent scheduling',
      visibility: SpaceVisibility.public,
    );
    final dueAt =
        DateTime.now().millisecondsSinceEpoch +
        const Duration(minutes: 10).inMilliseconds;

    final both = await Future.wait([
      service.scheduleSpacePost(
        spaceId,
        title: 'First',
        body: 'Queued together with the second.',
        scheduledAtMs: dueAt,
      ),
      service.scheduleSpacePost(
        spaceId,
        title: 'Second',
        body: 'Queued together with the first.',
        scheduledAtMs: dueAt + 1000,
      ),
    ]);
    expect(both.every((job) => job != null), isTrue);

    final queued = await service.scheduledSpacePosts(spaceId);
    expect(
      queued.map((job) => job.id).toSet(),
      both.map((job) => job!.id).toSet(),
      reason: 'a concurrent schedule must not drop the job before it',
    );
  });

  test(
    'scheduled Space posts stay local, survive restart and publish once when due',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      final spaceId = await service.createSpace(
        'Scheduled lab',
        visibility: SpaceVisibility.public,
      );
      final dueAt =
          DateTime.now().millisecondsSinceEpoch +
          const Duration(minutes: 10).inMilliseconds;
      final scheduled = await service.scheduleSpacePost(
        spaceId,
        title: 'Release later',
        body: 'This must not enter P2P before the due time.',
        type: SpacePostType.article,
        media: [MediaObject(contentId: 'e' * 64, kind: 'image')],
        scheduledAtMs: dueAt,
      );
      expect(scheduled, isNotNull);
      expect(await service.postsOf(spaceId), isEmpty);
      expect(
        (await service.scheduledSpacePosts(spaceId)).single.id,
        scheduled!.id,
      );
      final index = await storage.getSetting('space.scheduled-posts.index.v1');
      expect(index, contains(scheduled.id));
      expect(index, isNot(contains('This must not enter P2P')));

      await service.dispose();
      final reopened = GroupService(storage, _FakeSigner(owner));
      expect(
        (await reopened.scheduledSpacePosts(spaceId)).single.id,
        scheduled.id,
      );
      final early = await reopened.runDueScheduledSpacePosts(nowMs: dueAt - 1);
      expect(early.scanned, 0);
      expect(await reopened.postsOf(spaceId), isEmpty);

      final executionAt = dueAt + 1234;
      final sweep = await reopened.runDueScheduledSpacePosts(
        nowMs: executionAt,
      );
      expect(sweep.published, 1);
      expect(sweep.failed, 0);
      expect(await reopened.scheduledSpacePosts(spaceId), isEmpty);
      final published = (await reopened.postsOf(spaceId)).single;
      expect(published.title, 'Release later');
      expect(published.createdAtMs, executionAt);
      expect(published.publishedAtMs, executionAt);
      expect((await reopened.load(spaceId))!.messages, isEmpty);

      final again = await reopened.runDueScheduledSpacePosts(
        nowMs: executionAt + 1,
      );
      expect(again.published, 0);
      expect(await reopened.postsOf(spaceId), hasLength(1));

      final publishNow = await reopened.scheduleSpacePost(
        spaceId,
        body: 'Explicitly publish now',
        scheduledAtMs: executionAt + const Duration(hours: 2).inMilliseconds,
      );
      expect(publishNow, isNotNull);
      expect(
        await reopened.publishScheduledSpacePostNow(spaceId, publishNow!.id),
        isTrue,
      );
      expect(await reopened.postsOf(spaceId), hasLength(2));
    },
  );

  test(
    'scheduled Space post fails closed after membership generation changes',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(ownerStorage, _FakeSigner(owner));
      final spaceId = await ownerService.createSpace(
        'Revoked schedule',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobService = GroupService(bobStorage, _FakeSigner(bob));
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final dueAt =
          DateTime.now().millisecondsSinceEpoch +
          const Duration(minutes: 5).inMilliseconds;
      final scheduled = await bobService.scheduleSpacePost(
        spaceId,
        body: 'Must never revive after revoke',
        scheduledAtMs: dueAt,
      );
      expect(scheduled, isNotNull);

      expect(
        await ownerService.addControlOp(spaceId, ControlOp.ban, target: bob),
        isTrue,
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final sweep = await bobService.runDueScheduledSpacePosts(nowMs: dueAt);
      expect(sweep.published, 0);
      expect(sweep.failed, 1);
      final failed = (await bobService.scheduledSpacePosts(spaceId)).single;
      expect(failed.status, ScheduledSpacePostStatus.failed);
      expect(await bobService.postsOf(spaceId), isEmpty);
      expect(
        (await bobService.runDueScheduledSpacePosts(nowMs: dueAt + 1)).scanned,
        0,
        reason: 'failed authority is never retried silently',
      );
      expect(
        await bobService.publishScheduledSpacePostNow(spaceId, failed.id),
        isFalse,
      );
      expect(
        await bobService.cancelScheduledSpacePost(spaceId, failed.id),
        isTrue,
      );
    },
  );

  test(
    'public Space posts are a separate signed log with stable feed paging',
    () async {
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace(
        'Public updates',
        visibility: SpaceVisibility.public,
      );
      final first = await svc.publishSpacePost(
        spaceId,
        title: 'One',
        body: 'first publication',
        type: SpacePostType.article,
        media: [MediaObject(contentId: 'a' * 64, kind: 'image')],
        broadcast: false,
      );
      final second = await svc.publishSpacePost(
        spaceId,
        body: 'second publication',
        broadcast: false,
      );
      expect(first, isNotNull);
      expect(second, isNotNull);
      final raw = (await svc.load(spaceId))!;
      expect(raw.messages, isEmpty);
      expect(raw.posts, hasLength(2));
      expect(raw.posts.every((post) => !post.isEncrypted), isTrue);
      expect(raw.posts.every((post) => post.version == 5), isTrue);
      expect(
        raw.posts.every(
          (post) =>
              post.controlFrontier == null &&
              post.controlCheckpointHash != null,
        ),
        isTrue,
      );
      expect(
        raw.posts.map((post) => post.controlCheckpointHash).toSet(),
        hasLength(1),
        reason: 'unchanged ACL state reuses one checkpoint',
      );
      expect(
        raw.posts.every(
          (post) => post.visibility == SpacePostVisibility.public,
        ),
        isTrue,
      );
      expect(await svc.referencedContentIds(spaceId), {'a' * 64});

      expect(
        await svc.reactToSpacePost(
          spaceId,
          first!.postId,
          '🔥',
          broadcast: false,
        ),
        isTrue,
      );
      expect(await svc.postMessage(spaceId, 'same-id message'), isTrue);
      final message = (await svc.messagesOf(spaceId)).single;
      expect(message.ref, first.postId);
      expect(
        await svc.react(spaceId, message.ref, '👍', broadcast: false),
        isTrue,
      );
      final postReactions = await svc.spacePostReactionsOf(spaceId);
      expect(postReactions[first.postId]?['🔥'], [owner]);
      expect((await svc.reactionsOf(spaceId))[message.ref]?['👍'], [owner]);
      expect(
        (await svc.reactionsOf(spaceId))[message.ref],
        isNot(contains('🔥')),
      );
      final reactionRows = (await svc.load(spaceId))!.reactions;
      expect(reactionRows, hasLength(2));
      expect(reactionRows.every((row) => row.version == 3), isTrue);
      expect(reactionRows.map((row) => row.targetKind).toSet(), {
        ReactionTargetKind.message,
        ReactionTargetKind.spacePost,
      });

      final page1 = await svc.spaceFeed(limit: 1);
      expect(page1.single.post.body, 'second publication');
      final page2 = await svc.spaceFeed(
        before: SpaceFeedCursor.fromView(page1.single.post),
        limit: 1,
      );
      expect(page2.single.post.body, 'first publication');
      expect(page2.single.spaceName, 'Public updates');
      expect(page2.single.reactions['🔥'], [owner]);

      await svc.updateSpaceSubscription(
        spaceId,
        feedEnabled: true,
        notificationsEnabled: true,
        hiddenFromRecommendations: false,
      );
      await Future.wait([
        svc.setSpaceFeedEnabled(spaceId, false),
        svc.setSpaceNotificationsEnabled(spaceId, false),
        svc.setSpaceCommentNotifications(
          spaceId,
          SpaceCommentNotificationMode.all,
        ),
        svc.setSpaceHiddenFromRecommendations(spaceId, true),
      ]);
      expect(await svc.spaceFeed(), isEmpty);
      expect((await svc.stateOf(spaceId))!.isMember(owner), isTrue);
      final preferences = await svc.spaceSubscription(spaceId);
      expect(preferences.feedEnabled, isFalse);
      expect(preferences.notificationsEnabled, isFalse);
      expect(
        preferences.commentNotifications,
        SpaceCommentNotificationMode.all,
      );
      expect(preferences.hiddenFromRecommendations, isTrue);
      await svc.setSpaceFeedEnabled(spaceId, true);
      expect(await svc.spaceFeed(), hasLength(2));
      expect(
        await svc.unreadSpacePosts(spaceId),
        0,
        reason: 'own posts are read-neutral',
      );
    },
  );

  test(
    'Space post comments are encrypted, scoped to their root and absent from Chats',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await service.createSpace(
        'Discussion lab',
        visibility: SpaceVisibility.public,
      );
      final otherSpace = await service.createSpace(
        'Other discussion',
        visibility: SpaceVisibility.public,
      );
      final groupId = await service.createGroup('Ordinary group chat');
      final first = (await service.publishSpacePost(
        spaceId,
        body: 'First root',
        broadcast: false,
      ))!;
      final second = (await service.publishSpacePost(
        spaceId,
        body: 'Second root',
        broadcast: false,
      ))!;
      await service.publishSpacePost(
        otherSpace,
        body: 'Foreign root',
        broadcast: false,
      );
      final commentMedia = MediaObject(
        contentId: 'c' * 64,
        kind: 'file',
        name: 'review.pdf',
        mimeType: 'application/pdf',
        size: 128,
      );

      expect(
        await service.commentOnSpacePost(
          spaceId,
          first.postId,
          '  First comment  ',
          broadcast: false,
        ),
        isTrue,
      );
      final firstComment = (await service.spacePostCommentsOf(
        spaceId,
        first.postId,
      )).single;
      expect(firstComment.body, 'First comment');
      expect(
        await service.editSpacePostComment(
          spaceId,
          first.postId,
          firstComment.ref,
          'Corrected first comment',
          broadcast: false,
        ),
        isTrue,
      );
      final editedFirst = (await service.spacePostCommentsOf(
        spaceId,
        first.postId,
      )).single;
      expect(editedFirst.ref, firstComment.ref);
      expect(editedFirst.body, 'Corrected first comment');
      expect(editedFirst.edited, isTrue);
      expect(editedFirst.editedAtMs, isNotNull);
      expect(
        await service.commentOnSpacePost(
          spaceId,
          first.postId,
          'Reply',
          replyTo: firstComment.ref,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          first.postId,
          '',
          media: commentMedia,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          second.postId,
          'Second-root comment',
          broadcast: false,
        ),
        isTrue,
      );

      final firstThread = await service.spacePostCommentsOf(
        spaceId,
        first.postId,
      );
      expect(firstThread.map((comment) => comment.body), [
        'Corrected first comment',
        'Reply',
        '',
      ]);
      expect(firstThread[1].replyTo, firstThread.first.ref);
      expect(firstThread.last.attachment?.toReferenceJson(), {
        'cid': 'c' * 64,
        'kind': 'file',
        'name': 'review.pdf',
        'mime': 'application/pdf',
        'size': 128,
      });
      expect(await service.referencedContentIds(spaceId), contains('c' * 64));
      expect(
        (await service.spacePostCommentsOf(spaceId, second.postId)).single.body,
        'Second-root comment',
      );
      final aggregate = await service.spacePostsAndCommentsOf(spaceId);
      expect(aggregate.posts.map((post) => post.postId), [
        first.postId,
        second.postId,
      ]);
      expect(
        aggregate.commentsByPost[first.postId]?.map((comment) => comment.body),
        ['Corrected first comment', 'Reply', ''],
      );
      expect(
        aggregate.commentsByPost[second.postId]?.single.body,
        'Second-root comment',
      );
      expect(await service.messagesOf(spaceId), isEmpty);
      expect(
        await service.messagesOf(
          spaceId,
          channelId: defaultSpaceChannelId(spaceId),
        ),
        isEmpty,
      );
      expect((await service.listGroups()).single.groupId, groupId);
      expect(
        (await service.listSpaces()).map((entry) => entry.groupId),
        containsAll([spaceId, otherSpace]),
      );

      final wire = (await service.load(spaceId))!.messages;
      expect(wire, hasLength(5));
      expect(wire.every((comment) => comment.isEncrypted), isTrue);
      expect(wire.every((comment) => comment.body.isEmpty), isTrue);
      expect(wire.every((comment) => comment.channelId == null), isTrue);
      expect(wire.map((comment) => comment.spacePostId), [
        first.postId,
        first.postId,
        first.postId,
        first.postId,
        second.postId,
      ]);

      expect(
        await service.commentOnSpacePost(
          groupId,
          first.postId,
          'Must not turn a group chat into a Space',
        ),
        isFalse,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          first.postId,
          '',
          media: const MediaObject(contentId: 'not-a-sha256-cid', kind: 'file'),
        ),
        isFalse,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          '${bob.hex}:99',
          'Cross-Space target',
        ),
        isFalse,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          second.postId,
          'Cross-thread reply',
          replyTo: firstComment.ref,
        ),
        isFalse,
      );
      expect(
        await service.commentOnSpacePost(
          spaceId,
          first.postId,
          List.filled(kSpacePostCommentMaxBytes + 1, 'x').join(),
        ),
        isFalse,
      );
      expect(
        await service.editSpacePostComment(
          spaceId,
          first.postId,
          '${bob.hex}:99',
          'Cannot edit a missing or foreign comment',
        ),
        isFalse,
      );

      expect(
        await service.deleteSpacePost(spaceId, first.postId, broadcast: false),
        isTrue,
      );
      expect(await service.spacePostCommentsOf(spaceId, first.postId), isEmpty);
      expect(
        await service.referencedContentIds(spaceId),
        isNot(contains('c' * 64)),
      );
      expect((await service.load(spaceId))!.messages, hasLength(5));
    },
  );

  test(
    'merged Feed suppresses blocked authors and refreshes contact access',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(ownerStorage, _FakeSigner(owner));
      final spaceId = await ownerService.createSpace(
        'Block-aware feed',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobService = GroupService(bobStorage, _FakeSigner(bob));
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final post = await bobService.publishSpacePost(
        spaceId,
        body: 'hidden after a relationship block',
        broadcast: false,
      );
      expect(post, isNotNull);
      expect(
        await ownerService.ingestSnapshot(
          bobService.snapshotJson(
            (await bobService.load(spaceId))!,
            recipient: owner,
          ),
        ),
        isTrue,
      );
      expect(await ownerService.spaceFeed(), hasLength(1));
      expect(await ownerService.unreadSpacePosts(spaceId), 1);

      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.blocked),
      );
      final accessBefore = ownerService.feedAccessChanges.value;
      final changesBefore = ownerService.changes.value;
      ownerService.notifyContactAccessChanged(bob);
      expect(ownerService.feedAccessChanges.value, accessBefore + 1);
      expect(ownerService.changes.value, changesBefore + 1);
      expect(await ownerService.spaceFeed(), isEmpty);
      expect(await ownerService.unreadSpacePosts(spaceId), 0);
      expect(
        await ownerService.postsOf(spaceId),
        hasLength(1),
        reason: 'blocking hides the author from the merged Feed, not history',
      );

      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.accepted),
      );
      ownerService.notifyContactAccessChanged(bob);
      expect((await ownerService.spaceFeed()).single.post.postId, post!.postId);
    },
  );

  test(
    'remote Space ban invalidates feed access before recalculation',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(ownerStorage, _FakeSigner(owner));
      final spaceId = await ownerService.createSpace(
        'Revoked feed',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerService.publishSpacePost(
          spaceId,
          body: 'visible before ban',
          broadcast: false,
        ),
        isNotNull,
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobService = GroupService(bobStorage, _FakeSigner(bob));
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(await bobService.spaceFeed(), hasLength(1));
      final accessBefore = bobService.feedAccessChanges.value;

      expect(
        await ownerService.addControlOp(spaceId, ControlOp.ban, target: bob),
        isTrue,
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(bobService.feedAccessChanges.value, accessBefore + 1);
      expect(await bobService.spaceFeed(), isEmpty);
      expect(await bobService.postsOf(spaceId), isEmpty);
    },
  );

  test(
    'Space post comments converge member-to-member without chat notifications',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final bobService = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await ownerService.createSpace(
        'Distributed discussion',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );

      final chatNotices = <GroupMessage>[];
      final commentNotices = <GroupMessage>[];
      final ownerCommentNotices = <GroupMessage>[];
      final chatSub = bobService.incoming.listen(
        (notice) => chatNotices.add(notice.message),
      );
      final commentSub = bobService.incomingComments.listen(
        (notice) => commentNotices.add(notice.message),
      );
      final ownerCommentSub = ownerService.incomingComments.listen(
        (notice) => ownerCommentNotices.add(notice.message),
      );
      addTearDown(chatSub.cancel);
      addTearDown(commentSub.cancel);
      addTearDown(ownerCommentSub.cancel);

      final root = (await ownerService.publishSpacePost(
        spaceId,
        body: 'Root distributed with its discussion',
        broadcast: false,
      ))!;
      final commentMedia = MediaObject(
        contentId: 'd' * 64,
        kind: 'audio',
        name: 'answer.opus',
        mimeType: 'audio/opus',
        size: 512,
        durationMs: 2400,
      );
      expect(
        await ownerService.commentOnSpacePost(
          spaceId,
          root.postId,
          'Owner comment',
          media: commentMedia,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      await pump();
      expect(chatNotices, isEmpty);
      expect(commentNotices.map((comment) => comment.body), ['Owner comment']);
      expect(
        (await bobService.spacePostCommentsOf(
          spaceId,
          root.postId,
        )).single.body,
        'Owner comment',
      );
      expect(
        (await bobService.spacePostCommentsOf(
          spaceId,
          root.postId,
        )).single.attachment?.toReferenceJson(),
        commentMedia.toReferenceJson(),
      );
      final ownerComment = (await bobService.spacePostCommentsOf(
        spaceId,
        root.postId,
      )).single;
      expect(
        await bobService.editSpacePostComment(
          spaceId,
          root.postId,
          ownerComment.ref,
          'Member cannot impersonate the owner',
          broadcast: false,
        ),
        isFalse,
      );
      expect(
        await bobService.referencedContentIds(spaceId),
        contains('d' * 64),
      );

      expect(
        await bobService.commentOnSpacePost(
          spaceId,
          root.postId,
          'Member redistribution ${encodeMessageMention(owner)}',
          publiclyVisible: true,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await ownerService.ingestSnapshot(
          bobService.snapshotJson(
            (await bobService.load(spaceId))!,
            recipient: owner,
          ),
        ),
        isTrue,
      );
      expect(
        (await ownerService.spacePostCommentsOf(
          spaceId,
          root.postId,
        )).map((comment) => comment.body),
        [
          'Owner comment',
          'Member redistribution ${encodeMessageMention(owner)}',
        ],
      );
      expect((await ownerService.load(spaceId))!.publicComments, hasLength(1));
      final memberComment = (await ownerService.spacePostCommentsOf(
        spaceId,
        root.postId,
      )).last;
      expect(
        await bobService.editSpacePostComment(
          spaceId,
          root.postId,
          memberComment.ref,
          'Member revision ${encodeMessageMention(owner)}',
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await ownerService.ingestSnapshot(
          bobService.snapshotJson(
            (await bobService.load(spaceId))!,
            recipient: owner,
          ),
        ),
        isTrue,
      );
      await pump();
      expect(
        (await ownerService.spacePostCommentsOf(
          spaceId,
          root.postId,
        )).last.body,
        'Member revision ${encodeMessageMention(owner)}',
      );
      expect(
        commentNotices.map((comment) => comment.body),
        ['Owner comment'],
        reason: 'an edit refreshes state but is not a new-comment notice',
      );
      expect(
        ownerCommentNotices.map((comment) => comment.body),
        ['Member redistribution ${encodeMessageMention(owner)}'],
        reason: 'a remote edit is not emitted as another comment',
      );
      expect((await ownerService.load(spaceId))!.publicComments, hasLength(2));
      final publicProjection = await ownerService
          .buildSpacePublicDiscoveryPublication(spaceId);
      expect(publicProjection, isNotNull);
      expect(
        publicProjection!.feed
            .commentsFor(root.postId, _FakeSigner(owner).verifyDetached)
            .single
            .body,
        'Member revision ${encodeMessageMention(owner)}',
      );
      final mentionFeed = await ownerService.spaceFeed(
        filter: SpaceFeedFilter(
          types: SpacePostType.values.toSet(),
          mentionsOnly: true,
        ),
      );
      expect(mentionFeed, hasLength(1));
      expect(mentionFeed.single.post.postId, root.postId);
      expect(
        utf8.decode(
          SpacePublicFeedPackage(
            descriptor: publicProjection.discovery.descriptor,
            projection: publicProjection.feed,
          ).toBytes(),
        ),
        isNot(contains('Owner comment')),
        reason: 'the owner-private row is never inferred into public history',
      );

      final bobBundle = (await bobService.load(spaceId))!;
      final bobState = (await bobService.stateOf(spaceId))!;
      final bobHead = bobBundle.messages
          .where((message) => message.author == bob)
          .reduce((left, right) => left.seq > right.seq ? left : right);
      final clearWithAttachment = const GroupMessageCleartext(
        body: 'attachment smuggling',
        attachment: GroupAttachment(
          kind: 'file',
          dataB64: 'AQID',
          w: 1,
          h: 1,
          cid: 'must-not-be-referenced',
        ),
      ).encode();
      final createdAt = bobHead.createdAtMs + 1;
      final encryptedWithAttachment = await encryptGroupPayload(
        groupId: spaceId,
        membershipEpoch: bobState.epoch,
        author: bob,
        seq: bobHead.seq + 1,
        prevHash: groupMessageHash(bobHead),
        policyVersion: bobState.policyVersion,
        createdAtMs: createdAt,
        clearText: clearWithAttachment,
        epochKey: bobBundle.localEpochKeys[bobState.epoch]!,
      );
      clearWithAttachment.fillRange(0, clearWithAttachment.length, 0);
      final smuggled = _FakeSigner(bob).signMessage(
        GroupMessage(
          groupId: spaceId,
          author: bob,
          seq: bobHead.seq + 1,
          prevHash: groupMessageHash(bobHead),
          body: '',
          spacePostId: root.postId,
          version: 2,
          membershipEpoch: bobState.epoch,
          encryptedPayload: encryptedWithAttachment,
          policyVersion: bobState.policyVersion,
          createdAtMs: createdAt,
          signature: Uint8List(0),
        ),
      );
      expect(
        await ownerService.ingestSnapshot(
          bobService.snapshotJson(
            bobBundle.copyWith(messages: [...bobBundle.messages, smuggled]),
            recipient: owner,
          ),
        ),
        isTrue,
      );
      expect(
        (await ownerService.load(spaceId))!.messages,
        hasLength(3),
        reason: 'legacy inline comment media is rejected after AEAD open',
      );
      expect(
        await ownerService.referencedContentIds(spaceId),
        isNot(contains('must-not-be-referenced')),
      );
    },
  );

  test(
    'comment tombstones and moderation converge and revoke public media',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final ownerService = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final bobService = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      addTearDown(ownerService.dispose);
      addTearDown(bobService.dispose);

      final spaceId = await ownerService.createSpace(
        'Public comment lifecycle',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final post = (await ownerService.publishSpacePost(
        spaceId,
        body: 'Public root',
        broadcast: false,
      ))!;
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );

      final firstCid = 'd' * 64;
      expect(
        await bobService.commentOnSpacePost(
          spaceId,
          post.postId,
          'Public member comment',
          media: MediaObject(
            contentId: firstCid,
            kind: 'image',
            name: 'first.png',
            mimeType: 'image/png',
            size: 42,
          ),
          publiclyVisible: true,
          broadcast: false,
        ),
        isTrue,
      );
      final bobComment = (await bobService.spacePostCommentsOf(
        spaceId,
        post.postId,
      )).single;
      expect(
        await ownerService.ingestSnapshot(
          bobService.snapshotJson(
            (await bobService.load(spaceId))!,
            recipient: owner,
          ),
        ),
        isTrue,
      );
      expect(
        await ownerService.commentOnSpacePost(
          spaceId,
          post.postId,
          'Reply survives its parent tombstone',
          replyTo: bobComment.ref,
          publiclyVisible: true,
          broadcast: false,
        ),
        isTrue,
      );
      final beforeDelete = await ownerService
          .buildSpacePublicDiscoveryPublication(spaceId);
      expect(beforeDelete, isNotNull);
      expect(
        beforeDelete!.feed.verifiedReferencedContentIds(
          _FakeSigner(owner).verifyDetached,
        ),
        contains(firstCid),
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );

      final ownerNotices = <GroupMessage>[];
      final noticeSub = ownerService.incomingComments.listen(
        (notice) => ownerNotices.add(notice.message),
      );
      addTearDown(noticeSub.cancel);
      expect(
        await bobService.deleteSpacePostComment(
          spaceId,
          post.postId,
          bobComment.ref,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await bobService.deleteSpacePostComment(
          spaceId,
          post.postId,
          bobComment.ref,
          broadcast: false,
        ),
        isFalse,
        reason: 'an accepted tombstone cannot be replayed or resurrected',
      );
      expect(
        await bobService.editSpacePostComment(
          spaceId,
          post.postId,
          bobComment.ref,
          'Attempted resurrection',
          broadcast: false,
        ),
        isFalse,
        reason: 'the local writer cannot edit a terminal tombstone',
      );
      final bobAfterDelete = (await bobService.load(spaceId))!;
      expect(bobAfterDelete.messages, hasLength(3));
      expect(bobAfterDelete.publicComments, hasLength(3));
      expect(
        jsonEncode(bobAfterDelete.messages.last.toJson()),
        isNot(contains(bobComment.ref)),
        reason: 'the private delete target stays inside AEAD cleartext',
      );
      expect(
        bobAfterDelete.publicComments.last.operation,
        SpacePublicCommentOperation.delete,
      );
      expect(
        await ownerService.ingestSnapshot(
          bobService.snapshotJson(bobAfterDelete, recipient: owner),
        ),
        isTrue,
      );
      expect(ownerNotices, isEmpty, reason: 'a tombstone is not a new comment');
      final afterDelete = await ownerService.spacePostCommentsOf(
        spaceId,
        post.postId,
      );
      expect(afterDelete.map((comment) => comment.body), [
        'Reply survives its parent tombstone',
      ]);
      expect(afterDelete.single.replyTo, bobComment.ref);
      final publicAfterDelete = await ownerService
          .buildSpacePublicDiscoveryPublication(spaceId);
      expect(
        publicAfterDelete!.feed
            .commentsFor(post.postId, _FakeSigner(owner).verifyDetached)
            .map((comment) => comment.body),
        ['Reply survives its parent tombstone'],
      );
      expect(
        publicAfterDelete.feed.verifiedReferencedContentIds(
          _FakeSigner(owner).verifyDetached,
        ),
        isNot(contains(firstCid)),
      );

      expect(
        await bobService.commentOnSpacePost(
          spaceId,
          post.postId,
          'Abusive public comment',
          media: MediaObject(
            contentId: 'e' * 64,
            kind: 'file',
            name: 'abuse.bin',
            size: 12,
          ),
          publiclyVisible: true,
          broadcast: false,
        ),
        isTrue,
      );
      final abusive = (await bobService.spacePostCommentsOf(
        spaceId,
        post.postId,
      )).singleWhere((comment) => comment.author == bob);
      expect(
        await ownerService.ingestSnapshot(
          bobService.snapshotJson(
            (await bobService.load(spaceId))!,
            recipient: owner,
          ),
        ),
        isTrue,
      );
      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.blocked),
      );
      expect(await ownerService.isSpaceAuthorBlocked(bob), isTrue);
      expect(
        (await ownerService.spacePostCommentsOf(
          spaceId,
          post.postId,
        )).map((comment) => comment.body),
        ['Reply survives its parent tombstone'],
        reason: 'a relationship block is a local comment projection filter',
      );
      await ownerStorage.upsertContact(
        Contact(nodeId: bob, status: ContactStatus.accepted),
      );
      expect(
        await ownerService.spacePostCommentsOf(spaceId, post.postId),
        hasLength(2),
      );
      final actionId = await ownerService.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.deleteMessage,
        target: bob,
        scope: SpaceModerationScope.posts,
        reason: 'documented abuse',
        reference: SpaceModerationReference(
          kind: SpaceModerationReferenceKind.spacePostComment,
          author: bob,
          seq: abusive.root.seq,
        ),
      );
      expect(actionId, isNotNull);
      expect(
        await ownerService.spacePostCommentsOf(spaceId, post.postId),
        hasLength(1),
      );
      expect(
        await ownerService.moderateSpace(
          spaceId,
          kind: SpaceModerationKind.deleteMessage,
          target: bob,
          scope: SpaceModerationScope.posts,
          reason: 'duplicate',
          reference: SpaceModerationReference(
            kind: SpaceModerationReferenceKind.spacePostComment,
            author: bob,
            seq: abusive.root.seq,
          ),
        ),
        isNull,
      );
      final audit = await ownerService.spaceModerationAudit(spaceId);
      final record = audit.singleWhere(
        (candidate) => candidate.actionId == actionId,
      );
      expect(record.action.reason, 'documented abuse');
      expect(
        record.action.reference?.kind,
        SpaceModerationReferenceKind.spacePostComment,
      );
      final afterModeration = await ownerService
          .buildSpacePublicDiscoveryPublication(spaceId);
      expect(
        afterModeration!.feed.verifiedReferencedContentIds(
          _FakeSigner(owner).verifyDetached,
        ),
        isNot(contains('e' * 64)),
      );
      expect(
        await bobService.ingestSnapshot(
          ownerService.snapshotJson(
            (await ownerService.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        (await bobService.spacePostCommentsOf(
          spaceId,
          post.postId,
        )).map((comment) => comment.body),
        ['Reply survives its parent tombstone'],
      );
    },
  );

  test(
    'Space post revisions preserve root cursor and tombstones revoke feed media',
    () async {
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace(
        'Editable updates',
        visibility: SpaceVisibility.public,
      );
      final root = (await svc.publishSpacePost(
        spaceId,
        title: 'Original',
        body: 'first body',
        type: SpacePostType.article,
        media: [MediaObject(contentId: 'a' * 64, kind: 'image')],
        broadcast: false,
      ))!;
      await svc.publishSpacePost(
        spaceId,
        body: 'second root',
        broadcast: false,
      );
      final rootCursor = SpaceFeedCursor.fromPost(root);

      final edited = await svc.editSpacePost(
        spaceId,
        root.postId,
        title: 'Corrected',
        body: 'revised body',
        type: SpacePostType.post,
        media: [MediaObject(contentId: 'b' * 64, kind: 'image')],
        broadcast: false,
      );
      expect(edited, isNotNull);
      expect(edited!.postId, root.postId);
      expect(edited.revisionId, isNot(root.postId));
      expect(edited.edited, isTrue);
      expect(edited.title, 'Corrected');
      expect(edited.body, 'revised body');
      expect(edited.type, SpacePostType.post);
      expect(SpaceFeedCursor.fromView(edited).compareTo(rootCursor), 0);
      expect(await svc.postsOf(spaceId), hasLength(2));
      expect(await svc.referencedContentIds(spaceId), {'b' * 64});
      final afterEdit = (await svc.load(spaceId))!;
      expect(afterEdit.posts, hasLength(3));
      expect(afterEdit.posts.last.version, 7);
      expect(afterEdit.posts.last.operation, SpacePostOperation.edit);
      expect(afterEdit.posts.last.targetSeq, root.seq);

      expect(
        await svc.deleteSpacePost(spaceId, root.postId, broadcast: false),
        isTrue,
      );
      expect(await svc.spacePostReactionsOf(spaceId), isEmpty);
      expect(await svc.reactToSpacePost(spaceId, root.postId, '👍'), isFalse);
      final remaining = await svc.postsOf(spaceId);
      expect(remaining, hasLength(1));
      expect(remaining.single.body, 'second root');
      expect(await svc.referencedContentIds(spaceId), isEmpty);
      final afterDelete = (await svc.load(spaceId))!;
      expect(afterDelete.posts.last.operation, SpacePostOperation.delete);
      expect(afterDelete.posts.last.title, isEmpty);
      expect(afterDelete.posts.last.body, isEmpty);
      expect(
        await svc.deleteSpacePost(spaceId, root.postId, broadcast: false),
        isFalse,
      );
      expect(
        await svc.editSpacePost(
          spaceId,
          root.postId,
          title: 'resurrect',
          body: 'must fail',
          broadcast: false,
        ),
        isNull,
      );
      expect(
        await svc.editSpacePost(
          spaceId,
          '${bob.hex}:0',
          title: 'forged',
          body: 'other author',
          broadcast: false,
        ),
        isNull,
      );
    },
  );

  test(
    'a restricted author can remove an own Space post without publishing again',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(storage, _FakeSigner(owner));
      final bobSvc = GroupService(storage, _FakeSigner(bob));
      addTearDown(ownerSvc.dispose);
      addTearDown(bobSvc.dispose);
      final spaceId = await ownerSvc.createSpace(
        'Restricted authors',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final root = await bobSvc.publishSpacePost(
        spaceId,
        body: 'The author must retain the right to remove this',
        broadcast: false,
      );
      expect(root, isNotNull);

      expect(
        await ownerSvc.moderateSpace(
          spaceId,
          kind: SpaceModerationKind.restrictPublishing,
          target: bob,
          scope: SpaceModerationScope.posts,
          reason: 'temporary publishing restriction',
          expiresAtMs:
              DateTime.now().millisecondsSinceEpoch +
              const Duration(hours: 1).inMilliseconds,
        ),
        isNotNull,
      );
      expect(
        await bobSvc.publishSpacePost(
          spaceId,
          body: 'must remain blocked',
          broadcast: false,
        ),
        isNull,
      );
      expect(
        await bobSvc.editSpacePost(
          spaceId,
          root!.postId,
          title: '',
          body: 'must remain blocked too',
          broadcast: false,
        ),
        isNull,
      );
      final feedItem = (await bobSvc.spaceFeed()).single;
      expect(feedItem.canDeletePost, isTrue);
      expect(feedItem.canManagePosts, isFalse);
      expect(
        await bobSvc.deleteSpacePost(spaceId, root.postId, broadcast: false),
        isTrue,
      );
      expect(await bobSvc.postsOf(spaceId), isEmpty);
      final wire = (await bobSvc.load(spaceId))!.posts.last;
      expect(wire.operation, SpacePostOperation.delete);
      expect(wire.author, bob);
      expect(wire.targetSeq, root.seq);
    },
  );

  test(
    'private Space post revisions stay ciphertext-only and converge by snapshot',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await ownerSvc.createSpace('Private revisions');
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final root = (await ownerSvc.publishSpacePost(
        spaceId,
        body: 'private original',
        broadcast: false,
      ))!;
      final edit = await ownerSvc.editSpacePost(
        spaceId,
        root.postId,
        title: '',
        body: 'private revision',
        broadcast: false,
      );
      expect(edit, isNotNull);
      final ownerBundle = (await ownerSvc.load(spaceId))!;
      final wireEdit = ownerBundle.posts.last;
      expect(wireEdit.version, 8);
      expect(wireEdit.operation, SpacePostOperation.edit);
      expect(wireEdit.isEncrypted, isTrue);
      expect(wireEdit.title, isEmpty);
      expect(wireEdit.body, isEmpty);
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(ownerBundle, recipient: bob),
        ),
        isTrue,
      );
      final bobView = (await bobSvc.postsOf(spaceId)).single;
      expect(bobView.postId, root.postId);
      expect(bobView.body, 'private revision');
      expect(bobView.edited, isTrue);
      expect(
        await bobSvc.reactToSpacePost(
          spaceId,
          root.postId,
          '❤',
          broadcast: false,
        ),
        isTrue,
      );
      final bobReactionBundle = (await bobSvc.load(spaceId))!;
      final wireReaction = bobReactionBundle.reactions.single;
      expect(wireReaction.version, 4);
      expect(wireReaction.isEncrypted, isTrue);
      expect(wireReaction.target, isEmpty);
      expect(wireReaction.emoji, isEmpty);
      expect(jsonEncode(wireReaction.toJson()), isNot(contains(root.postId)));
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson(bobReactionBundle, recipient: owner),
        ),
        isTrue,
      );
      expect(
        (await ownerSvc.spacePostReactionsOf(spaceId))[root.postId]?['❤'],
        [bob],
      );

      expect(
        await ownerSvc.deleteSpacePost(spaceId, root.postId, broadcast: false),
        isTrue,
      );
      final deletedBundle = (await ownerSvc.load(spaceId))!;
      expect(deletedBundle.posts.last.version, 8);
      expect(deletedBundle.posts.last.encryptedPayload, isNotNull);
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(deletedBundle, recipient: bob),
        ),
        isTrue,
      );
      expect(await bobSvc.postsOf(spaceId), isEmpty);
    },
  );

  test(
    'invalid edit-of-edit suffix is retained as evidence but never extended',
    () async {
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace(
        'Revision topology',
        visibility: SpaceVisibility.public,
      );
      final root = (await svc.publishSpacePost(
        spaceId,
        body: 'root',
        broadcast: false,
      ))!;
      expect(
        await svc.editSpacePost(
          spaceId,
          root.postId,
          title: '',
          body: 'valid edit',
          broadcast: false,
        ),
        isNotNull,
      );
      final before = (await svc.load(spaceId))!;
      final previous = before.posts.last;
      final bad = _FakeSigner(owner).signPost(
        SpacePost(
          spaceId: spaceId,
          author: owner,
          seq: previous.seq + 1,
          prevHash: sha256.convert([
            ...previous.canonicalBytes(),
            ...previous.signature,
          ]).toString(),
          type: SpacePostType.post,
          visibility: SpacePostVisibility.public,
          title: '',
          body: 'must not apply',
          policyVersion: previous.policyVersion,
          createdAtMs: previous.createdAtMs + 1,
          publishedAtMs: previous.publishedAtMs + 1,
          version: 7,
          controlCheckpointHash: previous.controlCheckpointHash,
          operation: SpacePostOperation.edit,
          targetSeq: previous.seq,
          signature: Uint8List(0),
        ),
      );
      expect(bad.isStructurallyValid, isTrue);
      expect(
        await svc.ingestSnapshot(
          jsonEncode({
            'm': before.manifest.toJson(),
            'c': const [],
            'g': const [],
            'r': const [],
            'p': [bad.toJson()],
          }),
        ),
        isTrue,
      );
      expect((await svc.load(spaceId))!.posts, hasLength(3));
      expect((await svc.postsOf(spaceId)).single.body, 'valid edit');
      expect(
        await svc.publishSpacePost(
          spaceId,
          body: 'must not extend invalid topology',
          broadcast: false,
        ),
        isNull,
      );
      expect(
        await svc.editSpacePost(
          spaceId,
          root.postId,
          title: '',
          body: 'also blocked',
          broadcast: false,
        ),
        isNull,
      );
    },
  );

  test(
    'Space post edit and tombstone deltas converge through member P2P relay',
    () async {
      final toBob = <String>[];
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (peer, _, json) async {
          if (peer == bob) toBob.add(json);
        },
      );
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob));
      final incomingPosts = <SpacePostView>[];
      final incomingPostSub = bobSvc.incomingPosts.listen(
        (notice) => incomingPosts.add(notice.post),
      );
      addTearDown(incomingPostSub.cancel);
      final spaceId = await ownerSvc.createSpace(
        'Relayed revisions',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      toBob.clear();
      final root = (await ownerSvc.publishSpacePost(
        spaceId,
        body: 'relayed original',
      ))!;
      await pump();
      expect(toBob, isNotEmpty);
      expect(await bobSvc.ingestSnapshot(toBob.last), isTrue);
      expect((await bobSvc.postsOf(spaceId)).single.body, 'relayed original');
      expect(incomingPosts.map((post) => post.body), ['relayed original']);

      toBob.clear();
      expect(
        await ownerSvc.editSpacePost(
          spaceId,
          root.postId,
          title: '',
          body: 'relayed correction',
        ),
        isNotNull,
      );
      await pump();
      final editDelta = jsonDecode(toBob.last) as Map;
      expect(editDelta['p'], hasLength(1));
      expect((editDelta['p'] as List).single['op'], 'edit');
      expect(await bobSvc.ingestSnapshot(toBob.last), isTrue);
      expect((await bobSvc.postsOf(spaceId)).single.body, 'relayed correction');
      expect(incomingPosts, hasLength(1), reason: 'edits do not alert again');

      toBob.clear();
      expect(await ownerSvc.deleteSpacePost(spaceId, root.postId), isTrue);
      await pump();
      final deleteDelta = jsonDecode(toBob.last) as Map;
      expect(deleteDelta['p'], hasLength(1));
      expect((deleteDelta['p'] as List).single['op'], 'delete');
      expect(await bobSvc.ingestSnapshot(toBob.last), isTrue);
      expect(await bobSvc.postsOf(spaceId), isEmpty);
      expect(incomingPosts, hasLength(1), reason: 'deletions never alert');
    },
  );

  test(
    'feed dismissals stay local, survive edits/reopen and serialize across Spaces',
    () async {
      final (service, reopen) = await setup();
      final firstSpace = await service.createSpace(
        'One',
        visibility: SpaceVisibility.public,
      );
      final secondSpace = await service.createSpace(
        'Two',
        visibility: SpaceVisibility.public,
      );
      final first = (await service.publishSpacePost(
        firstSpace,
        body: 'first',
        broadcast: false,
      ))!;
      final second = (await service.publishSpacePost(
        secondSpace,
        body: 'second',
        broadcast: false,
      ))!;

      await Future.wait([
        service.setSpaceFeedPostHidden(firstSpace, first.postId, true),
        service.setSpaceFeedPostHidden(secondSpace, second.postId, true),
      ]);
      expect(await service.spaceFeed(), isEmpty);
      expect(await service.postsOf(firstSpace), hasLength(1));
      expect(await service.postsOf(secondSpace), hasLength(1));

      final edited = await service.editSpacePost(
        firstSpace,
        first.postId,
        title: '',
        body: 'edited while hidden',
        broadcast: false,
      );
      expect(edited?.postId, first.postId);
      expect(await service.spaceFeed(), isEmpty);

      final reopened = reopen(owner) as GroupService;
      expect(
        await reopened.isSpaceFeedPostHidden(firstSpace, first.postId),
        isTrue,
      );
      expect(await reopened.spaceFeed(), isEmpty);
      await Future.wait([
        reopened.setSpaceFeedPostHidden(firstSpace, first.postId, false),
        reopened.setSpaceFeedPostHidden(secondSpace, second.postId, false),
      ]);
      final restored = await reopened.spaceFeed();
      expect(restored, hasLength(2));
      expect(
        restored.singleWhere((item) => item.spaceId == firstSpace).post.body,
        'edited while hidden',
      );
    },
  );

  test(
    'feed type filter is identity-local, survives reopen and keeps Space posts',
    () async {
      final (service, reopen) = await setup();
      final spaceId = await service.createSpace(
        'Mixed media',
        visibility: SpaceVisibility.public,
      );
      await service.publishSpacePost(
        spaceId,
        body: 'plain update',
        broadcast: false,
      );
      await service.publishSpacePost(
        spaceId,
        body: 'long read',
        type: SpacePostType.article,
        broadcast: false,
      );

      expect(await service.spaceFeed(), hasLength(2));
      await service.setSpaceFeedTypeFilter({SpacePostType.article});
      expect(await service.spaceFeedTypeFilter(), {SpacePostType.article});
      expect((await service.spaceFeed()).single.post.body, 'long read');
      expect(await service.postsOf(spaceId), hasLength(2));

      final reopened = reopen(owner) as GroupService;
      expect(await reopened.spaceFeedTypeFilter(), {SpacePostType.article});
      expect(
        (await reopened.spaceFeed()).single.post.type,
        SpacePostType.article,
      );
      expect(
        await reopened.spaceFeed(types: {SpacePostType.post}),
        hasLength(1),
        reason: 'an explicit service-level filter remains an override',
      );

      await reopened.setSpaceFeedTypeFilter({});
      expect(
        await reopened.spaceFeedTypeFilter(),
        SpacePostType.values.toSet(),
      );
      expect(await reopened.spaceFeed(), hasLength(2));
    },
  );

  test(
    'feed filter combines canonical mentions, time and communities',
    () async {
      final (ownerService, member) = await setup();
      final first = await ownerService.createSpace(
        'First community',
        visibility: SpaceVisibility.public,
      );
      final second = await ownerService.createSpace(
        'Second community',
        visibility: SpaceVisibility.public,
      );
      for (final spaceId in [first, second]) {
        expect(
          await ownerService.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: bob,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      await ownerService.publishSpacePost(
        first,
        body: 'ordinary publication',
        broadcast: false,
      );
      await ownerService.publishSpacePost(
        first,
        body: 'hello ${encodeMessageMention(bob, dhtName: 'bob_public')}',
        broadcast: false,
      );
      await ownerService.publishSpacePost(
        second,
        body: 'second ${encodeMessageMention(bob)}',
        broadcast: false,
      );

      final bobService = member(bob) as GroupService;
      await bobService.setSpaceFeedFilter(
        SpaceFeedFilter(
          types: SpacePostType.values.toSet(),
          mentionsOnly: true,
          timePreset: SpaceFeedTimePreset.lastHour,
          spaceIds: {first},
        ),
      );
      final filtered = await bobService.spaceFeed();
      expect(filtered, hasLength(1));
      expect(filtered.single.spaceId, first);
      expect(filtered.single.post.body, contains(bob.hex));

      final reopened = member(bob) as GroupService;
      final restored = await reopened.spaceFeedFilter();
      expect(restored.mentionsOnly, isTrue);
      expect(restored.timePreset, SpaceFeedTimePreset.lastHour);
      expect(restored.spaceIds, {first});
      expect(await reopened.spaceFeed(), hasLength(1));

      await reopened.setSpaceFeedTypeFilter({SpacePostType.article});
      final afterTypeOnlyUpdate = await reopened.spaceFeedFilter();
      expect(afterTypeOnlyUpdate.mentionsOnly, isTrue);
      expect(afterTypeOnlyUpdate.timePreset, SpaceFeedTimePreset.lastHour);
      expect(afterTypeOnlyUpdate.spaceIds, {first});
    },
  );

  test(
    'hidden feed registry crosses the single-setting limit safely',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      final spaceId = await service.createSpace(
        'Busy feed',
        visibility: SpaceVisibility.public,
      );
      final postIds = <String>[];
      for (var index = 0; index < 40; index++) {
        final post = await service.publishSpacePost(
          spaceId,
          body: 'publication $index',
          broadcast: false,
        );
        postIds.add(post!.postId);
      }

      await Future.wait([
        for (final postId in postIds)
          service.setSpaceFeedPostHidden(spaceId, postId, true),
      ]);
      final persisted = await storage.loadFile('space.feed.hidden.v1');
      expect(persisted, isNotNull);
      expect(
        persisted!.length,
        greaterThan(4096),
        reason: 'the registry must use chunked file storage, not putSetting',
      );
      expect(await service.spaceFeed(), isEmpty);
      expect(await service.postsOf(spaceId), hasLength(40));
    },
  );

  test(
    'checkpointed posts scale past 256 state-mutating control authors',
    () async {
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace(
        'Large causal space',
        visibility: SpaceVisibility.public,
      );
      final base = (await svc.load(spaceId))!;
      final control = [...base.control];
      final accepted = foldControlLog(
        owner: base.manifest.owner,
        entries: control,
        verify: (_) => true,
        initialName: base.manifest.name,
      ).accepted;
      var ownerHead = accepted.where((entry) => entry.author == owner).last;
      var timestamp =
          control
              .map((entry) => entry.createdAtMs)
              .fold<int>(0, (left, right) => left > right ? left : right) +
          1;
      final admins = [
        for (var index = 0; index < kSpaceControlFrontierMax + 1; index++)
          _ordinalId(100 + index),
      ];
      for (final admin in admins) {
        final entry = _FakeSigner(owner).signControl(
          ControlEntry(
            version: 2,
            groupId: spaceId,
            author: owner,
            seq: ownerHead.seq + 1,
            prevHash: controlEntryHash(ownerHead),
            op: ControlOp.addMember,
            target: admin,
            role: GroupRole.admin,
            policyVersion: 0,
            createdAtMs: timestamp++,
            signature: Uint8List(0),
          ),
        );
        control.add(entry);
        ownerHead = entry;
      }
      for (var index = 0; index < admins.length; index++) {
        control.add(
          _FakeSigner(admins[index]).signControl(
            ControlEntry(
              version: 2,
              groupId: spaceId,
              author: admins[index],
              seq: 0,
              prevHash: '',
              op: ControlOp.addMember,
              target: _ordinalId(1000 + index),
              role: GroupRole.member,
              policyVersion: 0,
              createdAtMs: timestamp++,
              signature: Uint8List(0),
            ),
          ),
        );
      }
      expect(
        await svc.ingestSnapshot(
          jsonEncode({
            'm': base.manifest.toJson(),
            'c': [for (final entry in control) entry.toJson()],
            'g': const [],
            'r': const [],
          }),
        ),
        isTrue,
      );

      final post = await svc.publishSpacePost(
        spaceId,
        body: 'constant-size publication frontier',
        broadcast: false,
      );
      expect(post, isNotNull);
      expect(post!.version, 5);
      expect(post.controlCheckpointHash, hasLength(64));
      expect(post.canonicalBytes().length, lessThan(2048));
      final stored = (await svc.load(spaceId))!;
      final checkpoint = stored.control.lastWhere(
        (entry) =>
            entry.op == ControlOp.checkpoint &&
            controlEntryHash(entry) == post.controlCheckpointHash,
      );
      expect(
        checkpoint.controlCheckpoint!.heads.length,
        greaterThan(kSpaceControlFrontierMax),
      );
      expect(
        (await svc.postsOf(spaceId)).single.body,
        contains('constant-size'),
      );
    },
  );

  test(
    'checkpoint control fork quarantines dependent posts fail-closed',
    () async {
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace(
        'Checkpoint fork',
        visibility: SpaceVisibility.public,
      );
      final post = await svc.publishSpacePost(
        spaceId,
        body: 'must disappear with forked authority',
        broadcast: false,
      );
      expect(post, isNotNull);
      final before = (await svc.load(spaceId))!;
      final checkpoint = before.control.singleWhere(
        (entry) => controlEntryHash(entry) == post!.controlCheckpointHash,
      );
      final fork = _FakeSigner(owner).signControl(
        ControlEntry(
          version: 4,
          groupId: spaceId,
          author: checkpoint.author,
          seq: checkpoint.seq,
          prevHash: checkpoint.prevHash,
          op: ControlOp.checkpoint,
          target: null,
          role: null,
          controlCheckpoint: SpaceControlCheckpoint(const []),
          policyVersion: checkpoint.policyVersion,
          createdAtMs: checkpoint.createdAtMs + 1,
          signature: Uint8List(0),
        ),
      );
      expect(
        await svc.ingestSnapshot(
          jsonEncode({
            'm': before.manifest.toJson(),
            'c': [fork.toJson()],
            'g': const [],
            'r': const [],
          }),
        ),
        isTrue,
      );
      expect((await svc.load(spaceId))!.posts, hasLength(1));
      expect(await svc.postsOf(spaceId), isEmpty);
      expect(
        await svc.publishSpacePost(
          spaceId,
          body: 'cannot extend forked control history',
          broadcast: false,
        ),
        isNull,
      );
      await svc.compactStateLogs(spaceId);
      final retained = (await svc.load(spaceId))!.control.where(
        (entry) =>
            entry.author == checkpoint.author && entry.seq == checkpoint.seq,
      );
      expect(retained, hasLength(2));
    },
  );

  test(
    'a Space publisher stamping itself into the future owns the Feed, the row '
    'in Chats and an unread badge nobody can clear — the fix must not touch '
    'one signed byte, and paging must still enumerate every post exactly once',
    () async {
      Future<void> drain() async {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      final sent = <String>[];
      final s1 = FakeHvContainer().storage();
      await s1.open(password: 'pw', createIfMissing: true);
      // Held clocks on both sides: this asserts an ORDER and an arrival
      // moment, so it must not race DateTime.now. `_now()` is monotonic per
      // service instance, so each side's stamps only ever move forward here.
      final t0 = DateTime.utc(2026, 8, 3, 12).millisecondsSinceEpoch;
      // The Space exists, and bob joins it, an hour before the window this
      // test reasons about: a member cannot publish dated before its own
      // admission, and that is a separate rule from the one under test.
      var wall = t0 - const Duration(hours: 1).inMilliseconds;
      final ownerSvc = GroupService(
        s1,
        _FakeSigner(owner),
        send: (p, g, j) async => sent.add(j),
      )..debugWallClockMs = () => wall;
      addTearDown(ownerSvc.dispose);
      final spaceId = await ownerSvc.createSpace(
        'Public updates',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      await drain();
      final s2 = FakeHvContainer().storage();
      await s2.open(password: 'pw', createIfMissing: true);
      // Bob back from a nap, a minute BEHIND the receiver.
      var bobWall = t0 - 60000;
      final bobSvc = GroupService(
        s2,
        _FakeSigner(bob),
        send: (p, g, j) async => sent.add(j),
      )..debugWallClockMs = () => bobWall;
      addTearDown(bobSvc.dispose);
      expect(await bobSvc.ingestSnapshot(sent.last), isTrue);
      sent.clear();

      // A stamp in the PAST is never touched: a backdated publication cannot
      // float above anything, and a device coming back must keep its own time.
      expect(
        await bobSvc.publishSpacePost(spaceId, body: 'a minute ago'),
        isNotNull,
      );
      // Bob honestly a few minutes fast — exactly at the tolerated bound.
      bobWall = t0 + kSpacePublicClockSkew.inMilliseconds;
      expect(
        await bobSvc.publishSpacePost(spaceId, body: 'nearly now'),
        isNotNull,
      );
      // Bob claims to publish from 2027. Nothing in the Space can contradict a
      // clock: the signature over `published` proves only who said it, and
      // `isStructurallyValid` bounds it against bob's own `created`, which bob
      // also chose.
      final hostileTs = t0 + const Duration(days: 365).inMilliseconds;
      bobWall = hostileTs;
      expect(
        await bobSvc.publishSpacePost(spaceId, body: 'from the future'),
        isNotNull,
      );
      await drain();

      wall = t0;
      expect(
        await ownerSvc.publishSpacePost(
          spaceId,
          body: 'mine',
          broadcast: false,
        ),
        isNotNull,
      );
      wall = t0 + 1000;
      for (final delta in sent) {
        await ownerSvc.ingestSnapshot(delta);
      }
      await drain();

      Future<List<String>> bodies() async =>
          (await ownerSvc.postsOf(spaceId)).map((p) => p.body).toList();
      Future<SpacePostView> hostileRow() async => (await ownerSvc.postsOf(
        spaceId,
      )).firstWhere((p) => p.body == 'from the future');

      expect(
        await bodies(),
        ['a minute ago', 'mine', 'from the future', 'nearly now'],
        reason:
            'the 2027 publication is ranked where it ARRIVED, and the '
            'honest posts on both sides of the receiver clock keep their own '
            'publication time',
      );

      // The stamp itself is untouched, and so is every byte the author signed:
      // rewriting it (the 1:1 answer) would invalidate the signature over
      // `canonicalBytes`, which includes `published`, and with it this post's
      // place in bob's prev-hash chain and every public-feed page over it.
      final hostile = await hostileRow();
      final landedAt = hostile.orderedAtMs;
      expect(hostile.publishedAtMs, hostileTs);
      expect(hostile.createdAtMs, hostileTs);
      expect(
        landedAt,
        inInclusiveRange(wall, wall + 1000),
        reason: 'ordered by the one time the receiver actually knows',
      );
      final storedRow = (await ownerSvc.load(
        spaceId,
      ))!.posts.firstWhere((p) => p.publishedAtMs == hostileTs);
      expect(
        storedRow.publishedAtMs,
        hostileTs,
        reason: 'what is on disk is what bob signed',
      );
      expect(hostile.root.canonicalBytes(), storedRow.canonicalBytes());
      expect(
        jsonEncode(hostile.root.toJson()),
        jsonEncode(storedRow.toJson()),
        reason: 'dedup and the chain prev-hash still name the same row',
      );
      // Nothing local rides out on the wire either. The arrival moment is a
      // number this receiver chose; shipping it would just be the same
      // unauthenticated stamp under a second name.
      final served =
          jsonDecode(ownerSvc.snapshotJson((await ownerSvc.load(spaceId))!))
              as Map;
      expect(served.containsKey('prx'), isFalse);
      expect(
        (served['p'] as List).firstWhere(
          (row) => (row as Map)['published'] == hostileTs,
        ),
        storedRow.toJson(),
        reason: 'served exactly as bob signed it, extra keys and all: none',
      );

      // The Space's row in Chats reads the LAST post, so with the log now
      // ordered correctly the newest row is the honest one — which is already
      // the whole point. The case where `lastTs` itself has to be derived is
      // asserted at the end, once the 2027 row IS the newest thing received.
      final listed = (await ownerSvc.listSpaces()).single;
      expect(listed.lastTs, t0 + kSpacePublicClockSkew.inMilliseconds);
      expect(listed.lastTs, lessThan(hostileTs));

      // The badge, and this is the OPPOSITE failure from the group one.
      // `markSpaceFeedSeen` takes the MAX cursor over the posts THEMSELVES as
      // the watermark and only ever moves forward, so a 2027 post used to
      // write a 2027 watermark and silently retire this Space's post badge
      // until that future arrived — the 1:1 `markRead` amplification exactly.
      // In groups the watermark is a local clock reading, so there the same
      // stamp pinned the badge permanently ON instead.
      expect(
        await ownerSvc.unreadSpacePosts(spaceId),
        3,
        reason: "own posts are read-neutral, bob's three are not",
      );
      wall = t0 + const Duration(minutes: 10).inMilliseconds;
      await ownerSvc.markSpaceFeedSeen(spaceId);
      expect(await ownerSvc.unreadSpacePosts(spaceId), 0);
      // A FRESH bob instance, because `_now()` is monotonic per service and
      // the 2027 publish left this one's last stamp in 2027 — a genuinely
      // honest follow-up has to come from a service that never claimed it.
      sent.clear();
      final bobHonest =
          GroupService(
              s2,
              _FakeSigner(bob),
              send: (p, g, j) async => sent.add(j),
            )
            ..debugWallClockMs = () =>
                t0 + const Duration(minutes: 20).inMilliseconds;
      addTearDown(bobHonest.dispose);
      expect(
        await bobHonest.publishSpacePost(spaceId, body: 'an honest new post'),
        isNotNull,
      );
      await drain();
      wall = t0 + const Duration(minutes: 21).inMilliseconds;
      for (final delta in sent) {
        await ownerSvc.ingestSnapshot(delta);
      }
      await drain();
      expect(
        await ownerSvc.unreadSpacePosts(spaceId),
        1,
        reason:
            'a publisher cannot retire the badge by claiming to be in '
            '2027: the watermark it wrote is bounded to its arrival',
      );
      expect(
        (await ownerSvc.unreadSpacePostViews(spaceId)).single.body,
        'an honest new post',
      );

      // Paging. The Feed both SORTS and PAGES on this order, so a value that
      // moved between two pages would drop a post or repeat one. Walk the
      // whole Feed one item at a time, straight across the boundary the
      // bounded post sits on.
      Future<List<String>> pageThroughOn(GroupService svc, int limit) async {
        final seen = <String>[];
        SpaceFeedCursor? before;
        while (true) {
          final page = await svc.spaceFeed(before: before, limit: limit);
          if (page.isEmpty) break;
          seen.addAll(page.map((item) => item.post.body));
          before = SpaceFeedCursor.fromView(page.last.post);
        }
        return seen;
      }

      Future<List<String>> pageThrough(int limit) =>
          pageThroughOn(ownerSvc, limit);

      final whole = (await ownerSvc.spaceFeed(
        limit: 200,
      )).map((item) => item.post.body).toList();
      expect(
        whole,
        [
          'an honest new post',
          'nearly now',
          'from the future',
          'mine',
          'a minute ago',
        ],
        reason:
            'newest first, and the 2027 publication sits at its arrival '
            'moment — below every honest post published after it landed, and '
            'above the two that predate it',
      );
      expect(whole.toSet(), hasLength(5), reason: 'no post is listed twice');
      for (final limit in [1, 2, 3, 4, 5, 6]) {
        expect(
          await pageThrough(limit),
          whole,
          reason:
              'paging at $limit must reproduce the single-shot Feed '
              'exactly — no post skipped, none repeated',
        );
      }

      // ONCE, on arrival. Peers re-ship whole snapshots on every reconnect, so
      // this exact row comes back against a clock that has moved on; if the
      // bound were re-derived then, the post would walk down the Feed on every
      // sync — and a reader holding a page cursor across that move would lose
      // or repeat it.
      wall = t0 + const Duration(hours: 5).inMilliseconds;
      final reship = bobSvc.snapshotJson((await bobSvc.load(spaceId))!);
      await ownerSvc.ingestSnapshot(reship);
      await drain();
      expect(
        (await hostileRow()).orderedAtMs,
        landedAt,
        reason: 'stamped once on arrival; a re-ship must not restamp it',
      );
      // ...and re-reading is a pure re-fold, never a re-stamp: the clock has
      // moved another five hours between these two reads.
      wall = t0 + const Duration(hours: 10).inMilliseconds;
      expect((await hostileRow()).orderedAtMs, landedAt);
      expect(await pageThrough(1), whole);

      // It survives a reload from disk, so the arrival moment is persisted and
      // not re-invented per process.
      final reopened = GroupService(s1, _FakeSigner(owner))
        ..debugWallClockMs = () => wall;
      addTearDown(reopened.dispose);
      expect(
        (await reopened.postsOf(
          spaceId,
        )).firstWhere((p) => p.body == 'from the future').orderedAtMs,
        landedAt,
      );
      expect(await reopened.unreadSpacePosts(spaceId), 1);

      // A post already on disk from before this rule existed is bounded the
      // next time a peer offers it, not left with its 2027 forever — which is
      // why the arrival moment is recorded OUTSIDE the dedup below it. Stand
      // in for that log by receiving everything on a device whose own clock
      // already reads 2027, so nothing is recorded, then restarting it sane.
      final wire = ownerSvc.snapshotJson((await ownerSvc.load(spaceId))!);
      final s3 = FakeHvContainer().storage();
      await s3.open(password: 'pw', createIfMissing: true);
      final believed = GroupService(s3, _FakeSigner(owner))
        ..debugWallClockMs = () => hostileTs;
      addTearDown(believed.dispose);
      expect(await believed.ingestSnapshot(wire), isTrue);
      expect(
        (await believed.postsOf(
          spaceId,
        )).firstWhere((p) => p.body == 'from the future').orderedAtMs,
        hostileTs,
        reason: 'a device whose own clock says 2027 has no reason to doubt it',
      );
      var restartedWall = t0;
      final restarted = GroupService(s3, _FakeSigner(owner))
        ..debugWallClockMs = () => restartedWall;
      addTearDown(restarted.dispose);
      await restarted.ingestSnapshot(wire);
      final rescued = (await restarted.postsOf(
        spaceId,
      )).firstWhere((p) => p.body == 'from the future');
      expect(rescued.publishedAtMs, hostileTs);
      expect(
        rescued.orderedAtMs,
        inInclusiveRange(t0, t0 + 1000),
        reason: 'a duplicate the log already held is still bounded',
      );
      restartedWall = t0 + const Duration(hours: 5).inMilliseconds;
      await restarted.ingestSnapshot(wire);
      expect(
        (await restarted.postsOf(
          spaceId,
        )).firstWhere((p) => p.body == 'from the future').orderedAtMs,
        rescued.orderedAtMs,
        reason: 'the first observation is the only one that may set it',
      );

      // The bound at the exact millisecond, against a receiver whose arrival
      // moment is pinned: a FRESH service instance (so its monotonic `_now`
      // starts from the held wall clock) taking ONE snapshot. Everything above
      // sits comfortably inside or outside the tolerance; this is the pair
      // that straddles it, one millisecond apart.
      final bobAgain = GroupService(s2, _FakeSigner(bob));
      addTearDown(bobAgain.dispose);
      final tB = t0 + const Duration(days: 2).inMilliseconds;
      var bobAgainWall = tB + kSpacePublicClockSkew.inMilliseconds;
      bobAgain.debugWallClockMs = () => bobAgainWall;
      expect(
        await bobAgain.publishSpacePost(
          spaceId,
          body: 'at the bound',
          broadcast: false,
        ),
        isNotNull,
      );
      bobAgainWall += 1;
      expect(
        await bobAgain.publishSpacePost(
          spaceId,
          body: 'one past it',
          broadcast: false,
        ),
        isNotNull,
      );
      final straddling = bobAgain.snapshotJson((await bobAgain.load(spaceId))!);

      final s4 = FakeHvContainer().storage();
      await s4.open(password: 'pw', createIfMissing: true);
      final receiver = GroupService(s4, _FakeSigner(owner))
        ..debugWallClockMs = () => tB;
      addTearDown(receiver.dispose);
      expect(await receiver.ingestSnapshot(straddling), isTrue);
      final landed = {
        for (final p in await receiver.postsOf(spaceId)) p.body: p,
      };
      expect(
        landed['from the future']!.orderedAtMs,
        tB,
        reason: 'the arrival moment of this ingest is exactly tB',
      );
      expect(
        landed['at the bound']!.orderedAtMs,
        tB + kSpacePublicClockSkew.inMilliseconds,
        reason: 'a publisher exactly at the tolerated skew is still believed',
      );
      expect(
        landed['one past it']!.orderedAtMs,
        tB,
        reason: 'one millisecond further is not a clock reading any more',
      );
      expect(
        (await receiver.postsOf(spaceId)).map((p) => p.body).toList(),
        [
          'a minute ago',
          'nearly now',
          'an honest new post',
          'from the future',
          'one past it',
          'at the bound',
        ],
        reason:
            'both bounded posts land on the SAME millisecond tB and still '
            'order deterministically below the believed one — two rows that '
            'compared equal would be dropped or repeated by paging',
      );

      // The Chats row, now with the 2027 publication as the NEWEST thing this
      // device has received — which is when `lastPost` is that row and its
      // stamp is what the list would show. This is the line a publisher used
      // to own outright: one post, and the Space sits at the top of Chats
      // claiming activity in 2027 until the year arrives.
      sent.clear();
      final bobLate = GroupService(
        s2,
        _FakeSigner(bob),
        send: (p, g, j) async => sent.add(j),
      )..debugWallClockMs = () => hostileTs + 1000;
      addTearDown(bobLate.dispose);
      expect(
        await bobLate.publishSpacePost(spaceId, body: 'newest and from 2027'),
        isNotNull,
      );
      await drain();
      // Bob's whole log, because the straddling pair above never left his
      // device and this row chains onto it.
      wall = t0 + const Duration(hours: 11).inMilliseconds;
      expect(
        await ownerSvc.ingestSnapshot(
          bobLate.snapshotJson((await bobLate.load(spaceId))!),
        ),
        isTrue,
      );
      await drain();
      final newestIsHostile = (await ownerSvc.postsOf(spaceId)).last;
      expect(newestIsHostile.body, 'newest and from 2027');
      expect(
        newestIsHostile.publishedAtMs,
        hostileTs + 1000,
        reason: 'still exactly what bob signed',
      );
      final chatsRow = (await ownerSvc.listSpaces()).single;
      expect(chatsRow.lastTs, newestIsHostile.orderedAtMs);
      expect(
        chatsRow.lastTs,
        inInclusiveRange(wall, wall + 1000),
        reason: 'Chats shows when the row ARRIVED, not the year it claims',
      );
      expect(chatsRow.lastTs, lessThan(hostileTs));

      // And the OTHER half of that row: which source wins it. A Space carries
      // both a publication log and a channel log, and the list picks whichever
      // is newer. That comparison has to be derived on both sides, or the 2027
      // stamp simply outbids every message the Space will ever carry.
      wall = t0 + const Duration(hours: 12).inMilliseconds;
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'newer than any publication',
          broadcast: false,
        ),
        isTrue,
      );
      final withMessage = (await ownerSvc.listSpaces()).single;
      expect(withMessage.preview, 'newer than any publication');
      expect(
        withMessage.lastTs,
        inInclusiveRange(wall, wall + 1000),
        reason:
            'a message newer than every publication wins the row, and a '
            'publisher must not be able to outbid it with a claimed year',
      );
      // Same thing said as the Feed says it: a strict total order, so one
      // item per page walks all six exactly once.
      expect(await pageThroughOn(receiver, 1), [
        'at the bound',
        'one past it',
        'from the future',
        'an honest new post',
        'nearly now',
        'a minute ago',
      ]);
    },
  );

  test(
    'one member dating a post, a public comment or a public reaction into the '
    'future used to take the whole Space off public discovery — the owner must '
    'still publish, in full, without overstating its own freshness',
    () async {
      final t0 = DateTime.utc(2026, 8, 3, 12).millisecondsSinceEpoch;
      final hostileTs = t0 + const Duration(days: 365).inMilliseconds;

      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final signer = _FakeSigner(owner);
      var wall = t0 - const Duration(hours: 1).inMilliseconds;
      final ownerSvc = GroupService(
        ownerStorage,
        signer,
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      )..debugWallClockMs = () => wall;
      addTearDown(ownerSvc.dispose);
      final spaceId = await ownerSvc.createSpace(
        'Public updates',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      var bobWall = t0 - const Duration(hours: 1).inMilliseconds;
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      )..debugWallClockMs = () => bobWall;
      addTearDown(bobSvc.dispose);
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );

      // Honest and in the past.
      bobWall = t0 - 60000;
      final past = await bobSvc.publishSpacePost(
        spaceId,
        body: 'a minute ago',
        broadcast: false,
      );
      expect(past, isNotNull);
      // Honest and genuinely AHEAD of the owner's clock, but inside the
      // tolerance this surface already grants a stranger. Nothing may drop it,
      // and nothing may round it down to the receiver's clock either: this is
      // what tells "excluded the impossible" apart from "clamped everything".
      bobWall = t0 + const Duration(minutes: 2).inMilliseconds;
      expect(
        await bobSvc.publishSpacePost(
          spaceId,
          body: 'honestly a little fast',
          broadcast: false,
        ),
        isNotNull,
      );
      // 2027 — on a post, on a public comment and on a public reaction. Each
      // one alone used to be enough: all three land in the same `updatedAt`
      // fold, which becomes the descriptor's `issuedAt`, which the wire format
      // refuses more than five minutes ahead.
      bobWall = hostileTs;
      expect(
        await bobSvc.publishSpacePost(
          spaceId,
          body: 'from the future',
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await bobSvc.commentOnSpacePost(
          spaceId,
          past!.postId,
          'commented from the future',
          publiclyVisible: true,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await bobSvc.reactToSpacePost(
          spaceId,
          past.postId,
          '🔥',
          publiclyVisible: true,
          broadcast: false,
        ),
        isTrue,
      );

      wall = t0;
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );
      final stored = (await ownerSvc.load(spaceId))!;
      expect(stored.publicComments, hasLength(1));
      expect(stored.publicReactions, hasLength(1));
      expect(
        stored.publicComments.single.createdAtMs,
        greaterThanOrEqualTo(hostileTs),
      );
      expect(
        stored.publicReactions.single.createdAtMs,
        greaterThanOrEqualTo(hostileTs),
      );

      final publication = await ownerSvc.buildSpacePublicDiscoveryPublication(
        spaceId,
      );
      expect(
        publication,
        isNotNull,
        reason:
            'one member signing itself into 2027 must not be able to take '
            'the whole Space off public discovery — that is a member denying '
            'service to the owner, and to everyone who could have found it',
      );
      final descriptor = publication!.discovery.descriptor;
      expect(descriptor.verifyAt(wall, signer.verifyDetached), isTrue);
      expect(
        publication.feed.verifyAt(
          nowMs: wall,
          expectedManifestHash: descriptor.publicFeedManifestHash,
          expectedSpaceId: spaceId,
          expectedPublisher: owner,
          publisherPublicKey: descriptor.genesisManifest.genesisPubKey,
          expectedControlHeadHash: descriptor.controlHeadHash,
          verifySignature: signer.verifyDetached,
          verifyPost: signer.verifyPost,
        ),
        isTrue,
      );

      // And it does not lie about what it carries. The hostile rows are not
      // what was dropped: only their claim to be the Space's freshest
      // metadata is, so there is nothing here a member could want to opt
      // out of.
      expect(descriptor.publicPostCount, 3);
      expect(
        publication.feed.posts.map((post) => post.body),
        containsAll(<String>[
          'a minute ago',
          'honestly a little fast',
          'from the future',
        ]),
      );
      expect(publication.feed.manifest.discussionItemCount, 2);
      expect(
        publication.feed
            .commentsFor(past.postId, signer.verifyDetached)
            .single
            .createdAtMs,
        stored.publicComments.single.createdAtMs,
        reason: 'the comment is published with the stamp its author signed',
      );
      expect(
        publication.feed.reactionsFor(past.postId, signer.verifyDetached)['🔥'],
        [bob],
      );
      final futureRow = publication.feed.posts.firstWhere(
        (post) => post.body == 'from the future',
      );
      final storedFutureRow = stored.posts.firstWhere(
        (post) => post.publishedAtMs >= hostileTs,
      );
      expect(
        futureRow.root.canonicalBytes(),
        storedFutureRow.canonicalBytes(),
        reason: 'not one signed byte moves; 0a27cb2 stays exactly as it is',
      );
      expect(futureRow.publishedAtMs, greaterThanOrEqualTo(hostileTs));
      expect(
        (await ownerSvc.postsOf(
          spaceId,
        )).firstWhere((post) => post.body == 'from the future').orderedAtMs,
        lessThan(hostileTs),
        reason: 'and 0a27cb2 still holds: it is RANKED where it arrived',
      );

      // The number the owner signs is the newest stamp a clock here could have
      // produced: not 2027, and not the receiver's own clock either.
      final aheadCreated = publication.feed.posts
          .firstWhere((post) => post.body == 'honestly a little fast')
          .createdAtMs;
      expect(
        aheadCreated,
        greaterThan(wall),
        reason: 'this honest post really is ahead of the owner clock',
      );
      expect(
        publication.feed.manifest.updatedAtMs,
        aheadCreated,
        reason:
            'an honest stamp inside the tolerance is kept exactly as its '
            'author wrote it, so this is exclusion of the impossible and not a '
            'clamp of everything ahead',
      );
      expect(descriptor.updatedAtMs, lessThan(hostileTs));
      expect(
        descriptor.issuedAtMs,
        lessThanOrEqualTo(wall + kSpacePublicClockSkew.inMilliseconds),
        reason:
            'exactly what the wire format demands of `issuedAt`, and what '
            'a folded 2027 stamp used to make impossible',
      );

      // Excluded rather than clamped to now, and this is why: the owner
      // descriptor is deliberately stable across periodic refreshes so
      // independent holders attest one hash. A value taken from a live clock
      // would let one hostile row churn that hash forever — the same denial,
      // quieter.
      wall = t0 + const Duration(minutes: 10).inMilliseconds;
      final rebuilt = await ownerSvc.buildSpacePublicDiscoveryPublication(
        spaceId,
      );
      expect(rebuilt, isNotNull);
      expect(
        rebuilt!.discovery.descriptor.descriptorHash,
        descriptor.descriptorHash,
      );
      expect(rebuilt.feed.manifest.updatedAtMs, aheadCreated);
    },
  );

  test(
    'a member leaving on a control entry dated in the future must not take the '
    'Space off public discovery either, and the entry still counts',
    () async {
      Future<void> drain() async {
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      final t0 = DateTime.utc(2026, 8, 3, 12).millisecondsSinceEpoch;
      final hostileTs = t0 + const Duration(days: 365).inMilliseconds;

      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final signer = _FakeSigner(owner);
      var wall = t0 - const Duration(hours: 1).inMilliseconds;
      final ownerSvc = GroupService(ownerStorage, signer)
        ..debugWallClockMs = () => wall;
      addTearDown(ownerSvc.dispose);
      final spaceId = await ownerSvc.createSpace(
        'Public updates',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      var bobWall = t0 - const Duration(hours: 1).inMilliseconds;
      final fromBob = <String>[];
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        send: (peer, group, json) async => fromBob.add(json),
      )..debugWallClockMs = () => bobWall;
      addTearDown(bobSvc.dispose);
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );

      wall = t0;
      final before = await ownerSvc.buildSpacePublicDiscoveryPublication(
        spaceId,
      );
      expect(before, isNotNull);

      // `leave` needs no permission from anybody — a member writes it about
      // itself — and `ControlEntry.isStructurallyValid` bounds `created` only
      // by `>= 0`. So this is a stranger's number in the owner's own control
      // fold, exactly like a post's.
      bobWall = hostileTs;
      expect(await bobSvc.leaveGroup(spaceId), isTrue);
      await drain();
      expect(fromBob, isNotEmpty);
      for (final delta in fromBob) {
        await ownerSvc.ingestSnapshot(delta);
      }
      await drain();
      final leaveEntry = (await ownerSvc.load(
        spaceId,
      ))!.control.singleWhere((entry) => entry.op == ControlOp.leave);
      expect(leaveEntry.author, bob);
      expect(leaveEntry.createdAtMs, greaterThanOrEqualTo(hostileTs));

      final after = await ownerSvc.buildSpacePublicDiscoveryPublication(
        spaceId,
      );
      expect(
        after,
        isNotNull,
        reason:
            'a member walking out with a 2027 stamp must not end the '
            "Space's public presence",
      );
      expect(
        after!.discovery.descriptor.revision,
        before!.discovery.descriptor.revision + 1,
        reason:
            'the leave is accepted, counted and hashed into the control '
            'head — only its claim about the clock is ignored',
      );
      expect(
        after.discovery.descriptor.controlHeadHash,
        isNot(before.discovery.descriptor.controlHeadHash),
      );
      expect(
        after.discovery.descriptor.updatedAtMs,
        before.discovery.descriptor.updatedAtMs,
        reason: 'and it cannot make the Space claim it was updated in 2027',
      );
      expect(after.discovery.descriptor.updatedAtMs, lessThan(hostileTs));
      expect(
        after.discovery.descriptor.verifyAt(wall, signer.verifyDetached),
        isTrue,
      );
    },
  );

  test('private Space posts stay epoch-encrypted on disk and wire', () async {
    final ownerStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'pw', createIfMissing: true);
    final ownerSvc = GroupService(
      ownerStorage,
      _FakeSigner(owner),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
    );
    final spaceId = await ownerSvc.createSpace('Private updates');
    expect(
      await ownerSvc.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      ),
      isTrue,
    );
    expect(
      await ownerSvc.publishSpacePost(
        spaceId,
        title: 'Members',
        body: 'ciphertext on the wire',
        broadcast: false,
      ),
      isNotNull,
    );
    final ownerBundle = (await ownerSvc.load(spaceId))!;
    final stored = ownerBundle.posts.single;
    expect(stored.isEncrypted, isTrue);
    expect(stored.version, 6);
    expect(stored.controlFrontier, isNull);
    expect(stored.controlCheckpointHash, isNotNull);
    expect(stored.title, isEmpty);
    expect(stored.body, isEmpty);
    final wire = ownerSvc.snapshotJson(ownerBundle, recipient: bob);
    expect(wire, isNot(contains('ciphertext on the wire')));
    expect(wire, isNot(contains('Members')));
    expect((jsonDecode(wire) as Map)['p'], hasLength(1));

    final bobStorage = FakeHvContainer().storage();
    await bobStorage.open(password: 'pw', createIfMissing: true);
    final bobSvc = GroupService(
      bobStorage,
      _FakeSigner(bob),
      epochService: GroupEpochService(
        LoopbackMailboxCrypto(senderForOpen: owner),
      ),
    );
    expect(await bobSvc.ingestSnapshot(wire), isTrue);
    expect((await bobSvc.load(spaceId))!.posts, hasLength(1));
    final visible = await bobSvc.postsOf(spaceId);
    expect(visible.single.title, 'Members');
    expect(visible.single.body, 'ciphertext on the wire');
    expect(await bobSvc.unreadSpacePosts(spaceId), 1);
    await bobSvc.setSpaceFeedEnabled(spaceId, false);
    expect(await bobSvc.spaceFeed(), isEmpty);
    expect(
      await bobSvc.unreadSpacePosts(spaceId),
      1,
      reason: 'combined Feed and per-Space unread are independent',
    );
    await bobSvc.setSpaceFeedPostHidden(spaceId, visible.single.postId, true);
    expect(await bobSvc.unreadSpacePosts(spaceId), 0);
    expect(await bobSvc.postsOf(spaceId), hasLength(1));
    await bobSvc.setSpaceFeedPostHidden(spaceId, visible.single.postId, false);
    expect(await bobSvc.unreadSpacePosts(spaceId), 1);
    await bobSvc.markSpaceFeedSeen(spaceId);
    expect(await bobSvc.unreadSpacePosts(spaceId), 0);
  });

  test(
    'Space post gap-fill uses the contiguous chain and heals a lost prefix',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final toBob = <String>[];
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (peer, _, json) async {
          if (peer == bob) toBob.add(json);
        },
      );
      final spaceId = await ownerSvc.createSpace(
        'Public replication',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob));
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      toBob.clear();
      expect(
        await ownerSvc.publishSpacePost(
          spaceId,
          body: 'lost seq zero',
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await ownerSvc.publishSpacePost(spaceId, body: 'received seq one'),
        isNotNull,
      );
      await pump();
      final delta = jsonDecode(toBob.last) as Map;
      expect(delta['p'], hasLength(1));
      expect((delta['p'] as List).single['seq'], 1);
      expect(await bobSvc.ingestSnapshot(toBob.last), isTrue);
      expect((await bobSvc.load(spaceId))!.posts, isEmpty);
      expect(
        await bobSvc.postsOf(spaceId),
        isEmpty,
        reason: 'a post without its signed checkpoint is not admitted',
      );

      final request = (await bobSvc.buildGroupSyncRequest(spaceId))!;
      expect(request['p'], isEmpty);
      toBob.clear();
      expect(await ownerSvc.handleGroupSyncRequest(bob, request), isTrue);
      final repair = jsonDecode(toBob.single) as Map;
      expect(repair['c'], hasLength(1));
      expect(repair['p'], hasLength(2));
      expect(
        await ownerSvc.handleGroupSyncRequest(stranger, request),
        isFalse,
        reason: 'observability must not weaken the silent membership gate',
      );
      final observations = await ownerSvc.spaceObservabilitySnapshot();
      expect(observations.counters['p2pBackfill.succeeded'], 1);
      expect(observations.amounts['p2pBackfill'], 3);
      expect(observations.counters['p2pMissingObjects.succeeded'], 1);
      expect(observations.amounts['p2pMissingObjects'], 3);
      expect(observations.counters['aclDenied.reason.notMember'], 1);
      expect(observations.counters['p2pBackfill.reason.notMember'], 1);
      expect(await bobSvc.ingestSnapshot(toBob.single), isTrue);
      expect((await bobSvc.postsOf(spaceId)).map((post) => post.body), [
        'lost seq zero',
        'received seq one',
      ]);
      toBob.clear();
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.removeMember,
          target: bob,
        ),
        isTrue,
      );
      // A revoked member is absent from the post-fold CONTENT fanout, and the
      // one frame they do get says so and carries nothing else. "No frame at
      // all" used to stand in for this, and that proxy was the defect: the
      // removed member kept a live-looking Space for as long as nobody told
      // them (see test/removed_member_notice_test.dart).
      final revocationNotice = jsonDecode(toBob.single) as Map;
      expect((revocationNotice['c'] as List).single['op'], 'removeMember');
      for (final field in ['p', 'g', 'r', 'pc', 'pr', 'ke', 'cke', 'rcpt']) {
        final value = revocationNotice[field];
        expect(
          value == null || (value as List).isEmpty,
          isTrue,
          reason: 'a revoked member must receive no $field: $value',
        );
      }
      expect(await ownerSvc.handleGroupSyncRequest(bob, request), isFalse);
      final afterRevoke = await ownerSvc.spaceObservabilitySnapshot();
      expect(afterRevoke.counters['revokedDeliveryPrevented.rejected'], 1);
      expect(
        afterRevoke.counters['revokedDeliveryPrevented.reason.notMember'],
        1,
      );
      expect(afterRevoke.durationsMs['p2pBackfill']?['samples'], 3);
    },
  );

  test(
    'same-seq Space post equivocation quarantines both branches independent of arrival order',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
      final spaceId = await ownerSvc.createSpace(
        'Fork convergence',
        visibility: SpaceVisibility.public,
      );
      for (final peer in [bob, carol]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: peer,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      final base = (await ownerSvc.load(spaceId))!;
      final original = (await ownerSvc.publishSpacePost(
        spaceId,
        body: 'branch A',
        broadcast: false,
      ))!;
      final fork = _FakeSigner(owner).signPost(
        SpacePost(
          spaceId: original.spaceId,
          author: original.author,
          seq: original.seq,
          prevHash: original.prevHash,
          type: original.type,
          visibility: original.visibility,
          title: original.title,
          body: 'branch B',
          policyVersion: original.policyVersion,
          createdAtMs: original.createdAtMs,
          publishedAtMs: original.publishedAtMs,
          version: original.version,
          controlFrontier: original.controlFrontier,
          controlCheckpointHash: original.controlCheckpointHash,
          signature: Uint8List(0),
        ),
      );
      final checkpoint = (await ownerSvc.load(spaceId))!.control.lastWhere(
        (entry) =>
            entry.op == ControlOp.checkpoint &&
            controlEntryHash(entry) == original.controlCheckpointHash,
      );
      String delta(SpacePost post) => jsonEncode({
        'm': base.manifest.toJson(),
        'c': [checkpoint.toJson()],
        'g': const [],
        'r': const [],
        'p': [post.toJson()],
      });

      Future<GroupService> replica(NodeId self) async {
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'pw', createIfMissing: true);
        final service = GroupService(storage, _FakeSigner(self));
        expect(
          await service.ingestSnapshot(
            ownerSvc.snapshotJson(base, recipient: self),
          ),
          isTrue,
        );
        return service;
      }

      final bobSvc = await replica(bob);
      final carolSvc = await replica(carol);
      expect(await bobSvc.ingestSnapshot(delta(original)), isTrue);
      expect(await bobSvc.ingestSnapshot(delta(fork)), isTrue);
      expect(await carolSvc.ingestSnapshot(delta(fork)), isTrue);
      expect(await carolSvc.ingestSnapshot(delta(original)), isTrue);
      expect(await bobSvc.postsOf(spaceId), isEmpty);
      expect(await carolSvc.postsOf(spaceId), isEmpty);
      expect((await bobSvc.load(spaceId))!.posts, hasLength(2));
      expect((await carolSvc.load(spaceId))!.posts, hasLength(2));
      await bobSvc.compactStateLogs(spaceId);
      expect((await bobSvc.load(spaceId))!.posts, hasLength(2));
      expect(await bobSvc.postsOf(spaceId), isEmpty);
      expect((await bobSvc.buildGroupSyncRequest(spaceId))!['p'], isEmpty);
      expect((await carolSvc.buildGroupSyncRequest(spaceId))!['p'], isEmpty);
    },
  );

  test(
    'causal Space posts survive mute boundary and resume after a new grant',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
      final spaceId = await ownerSvc.createSpace(
        'Causal publications',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob));
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final before = await bobSvc.publishSpacePost(
        spaceId,
        body: 'published before mute',
        broadcast: false,
      );
      expect(before, isNotNull);
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );

      expect(
        await ownerSvc.addControlOp(spaceId, ControlOp.mute, target: bob),
        isTrue,
      );
      final mutedBundle = (await ownerSvc.load(spaceId))!;
      final mute = mutedBundle.control.lastWhere(
        (entry) => entry.op == ControlOp.mute && entry.target == bob,
      );
      expect(mute.postBoundary?.seq, 0);
      expect(mute.postBoundary?.hash, isNotEmpty);
      expect((await ownerSvc.postsOf(spaceId)).map((post) => post.body), [
        'published before mute',
      ]);

      expect(
        await ownerSvc.addControlOp(spaceId, ControlOp.unmute, target: bob),
        isTrue,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final after = await bobSvc.publishSpacePost(
        spaceId,
        body: 'published after unmute',
        broadcast: false,
      );
      expect(after, isNotNull);
      final afterPost = after!;
      final beforePost = before!;
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );
      expect((await ownerSvc.postsOf(spaceId)).map((post) => post.body), [
        'published before mute',
        'published after unmute',
      ]);

      // This row is chained after the new publication but deliberately carries
      // the pre-mute authorization frontier. It may be retained for evidence,
      // but the signed seq-0 boundary keeps it out of every reader/feed.
      final lateOldGrant = _FakeSigner(bob).signPost(
        SpacePost(
          spaceId: spaceId,
          author: bob,
          seq: 2,
          prevHash: sha256.convert([
            ...afterPost.canonicalBytes(),
            ...afterPost.signature,
          ]).toString(),
          type: SpacePostType.post,
          visibility: SpacePostVisibility.public,
          title: '',
          body: 'stale authority',
          policyVersion: beforePost.policyVersion,
          createdAtMs: afterPost.createdAtMs + 1,
          publishedAtMs: afterPost.publishedAtMs + 1,
          version: beforePost.version,
          controlFrontier: beforePost.controlFrontier,
          controlCheckpointHash: beforePost.controlCheckpointHash,
          signature: Uint8List(0),
        ),
      );
      final current = (await ownerSvc.load(spaceId))!;
      expect(
        await ownerSvc.ingestSnapshot(
          jsonEncode({
            'm': current.manifest.toJson(),
            'c': const [],
            'g': const [],
            'r': const [],
            'p': [lateOldGrant.toJson()],
          }),
        ),
        isTrue,
      );
      expect((await ownerSvc.load(spaceId))!.posts, hasLength(3));
      expect((await ownerSvc.postsOf(spaceId)).map((post) => post.body), [
        'published before mute',
        'published after unmute',
      ]);
    },
  );

  test(
    'legacy revocation without a boundary hides causal history fail-closed',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
      final spaceId = await ownerSvc.createSpace(
        'Legacy revoke migration',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob));
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        await bobSvc.publishSpacePost(
          spaceId,
          body: 'cannot be proven across a legacy revoke',
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );
      final beforeMute = (await ownerSvc.load(spaceId))!;
      expect(
        await ownerSvc.addControlOp(spaceId, ControlOp.mute, target: bob),
        isTrue,
      );
      final v3Mute = (await ownerSvc.load(spaceId))!.control.last;
      final legacyMute = _FakeSigner(owner).signControl(
        ControlEntry(
          version: 2,
          groupId: spaceId,
          author: v3Mute.author,
          seq: v3Mute.seq,
          prevHash: v3Mute.prevHash,
          op: v3Mute.op,
          target: v3Mute.target,
          role: v3Mute.role,
          policyVersion: v3Mute.policyVersion,
          createdAtMs: v3Mute.createdAtMs,
          signature: Uint8List(0),
        ),
      );

      final replicaStorage = FakeHvContainer().storage();
      await replicaStorage.open(password: 'pw', createIfMissing: true);
      final replica = GroupService(replicaStorage, _FakeSigner(owner));
      expect(
        await replica.ingestSnapshot(
          ownerSvc.snapshotJson(beforeMute, recipient: owner),
        ),
        isTrue,
      );
      expect(
        await replica.ingestSnapshot(
          jsonEncode({
            'm': beforeMute.manifest.toJson(),
            'c': [legacyMute.toJson()],
            'g': const [],
            'r': const [],
            'p': const [],
          }),
        ),
        isTrue,
      );
      expect((await replica.stateOf(spaceId))!.memberOf(bob)?.muted, isTrue);
      expect(await replica.postsOf(spaceId), isEmpty);
    },
  );

  test(
    'protected text channel hides metadata, distributes through holders and revokes by epoch',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final contentGrants = <(NodeId, String)>[];
      final sentSync = <(NodeId, String)>[];
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        send: (peer, _, payload) async => sentSync.add((peer, payload)),
        grantContentServe: (peer, cid) => contentGrants.add((peer, cid)),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await ownerSvc.createSpace('Scoped');
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: carol,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerSvc.createChannel(
          spaceId,
          name: 'not-yet-indistinguishable',
          kind: SpaceChannelKind.text,
          access: SpaceChannelAccess.secret,
          members: [bob],
        ),
        isNull,
        reason: 'secret stays fail-closed while opaque update cadence leaks',
      );
      final channelId = await ownerSvc.createChannel(
        spaceId,
        name: 'incident-room-plaintext-must-never-leak',
        description: 'sensitive metadata',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
        members: [bob],
      );
      expect(channelId, isNotNull);
      final ownerBundle = (await ownerSvc.load(spaceId))!;
      final outer = jsonEncode(ownerBundle.control.last.toJson());
      expect(outer, isNot(contains('incident-room-plaintext-must-never-leak')));
      expect(outer, isNot(contains('sensitive metadata')));
      expect(outer, isNot(contains(bob.hex)));
      expect(ownerBundle.control.last.version, 5);
      expect(ownerBundle.control.last.channel, isNull);

      final bobWire = ownerSvc.snapshotJson(ownerBundle, recipient: bob);
      final bobWireJson = jsonDecode(bobWire) as Map;
      expect((bobWireJson['cke'] as List), hasLength(2));
      final outsiderWire =
          jsonDecode(ownerSvc.snapshotJson(ownerBundle, recipient: carol))
              as Map;
      expect(outsiderWire['cke'], isNull);
      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final scopedRequests = <(NodeId, GroupContentRequest)>[];
      final scopedPulls = <(List<NodeId>, String)>[];
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        sendContentRequest: (holder, requestJson) async {
          scopedRequests.add((
            holder,
            GroupContentRequest.fromJson(jsonDecode(requestJson))!,
          ));
        },
        startContentPullFromAny: (holders, cid) async =>
            scopedPulls.add((holders, cid)),
        contentGrantDelay: Duration.zero,
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      expect(await bobSvc.ingestSnapshot(bobWire), isTrue);
      expect(
        (await bobSvc.channelsOf(
          spaceId,
        )).singleWhere((channel) => channel.channelId == channelId).access,
        SpaceChannelAccess.restricted,
      );
      expect(
        (await bobSvc.load(spaceId))!.channelEpochEnvelopes,
        hasLength(2),
        reason: 'an authorized holder retains every sealed recipient record',
      );
      expect(
        await bobSvc.postMessage(
          spaceId,
          'channel-key ciphertext',
          channelId: channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await bobSvc.postMessage(
          spaceId,
          'protected media',
          channelId: channelId,
          attachment: MediaObject(
            kind: 'file',
            contentId: 'a' * 64,
            name: 'incident-report.txt',
            size: 4,
          ),
          broadcast: false,
        ),
        isTrue,
      );
      final bobBundle = (await bobSvc.load(spaceId))!;
      final storedMessage = bobBundle.messages.first;
      expect(storedMessage.version, 3);
      expect(storedMessage.isChannelEncrypted, isTrue);
      expect(
        jsonEncode(storedMessage.toJson()),
        isNot(contains('channel-key ciphertext')),
      );
      final storedMedia = bobBundle.messages.last;
      expect(storedMedia.isChannelEncrypted, isTrue);
      expect(
        jsonEncode(storedMedia.toJson()),
        isNot(contains('incident-report')),
      );
      expect(jsonEncode(storedMedia.toJson()), isNot(contains('a' * 64)));
      final visibleMedia = (await bobSvc.messagesOf(
        spaceId,
        channelId: channelId,
      )).last;
      expect(visibleMedia.body, 'protected media');
      expect(visibleMedia.attachment?.contentId, 'a' * 64);
      expect(visibleMedia.attachment?.inlinePreviewB64, isNull);
      expect(await bobSvc.referencedContentIds(spaceId), contains('a' * 64));
      final protectedTarget = (await bobSvc.messagesOf(
        spaceId,
        channelId: channelId,
      )).first;
      expect(
        await bobSvc.react(
          spaceId,
          protectedTarget.ref,
          '🔐',
          broadcast: false,
        ),
        isTrue,
      );
      final reactedBobBundle = (await bobSvc.load(spaceId))!;
      final protectedReaction = reactedBobBundle.reactions.single;
      expect(protectedReaction.version, 7);
      expect(protectedReaction.isChannelEncrypted, isTrue);
      expect(protectedReaction.channelId, channelId);
      expect(protectedReaction.channelEpoch, 1);
      expect(jsonEncode(protectedReaction.toJson()), isNot(contains('🔐')));
      expect(protectedReaction.toJson(), isNot(containsPair('tgt', anything)));
      expect((await bobSvc.reactionsOf(spaceId))[protectedTarget.ref]?['🔐'], [
        bob,
      ]);
      final outsiderReactionWire =
          jsonDecode(bobSvc.snapshotJson(reactedBobBundle, recipient: carol))
              as Map;
      expect(outsiderReactionWire['r'], isEmpty);
      expect(await bobSvc.fetchGroupContent(spaceId, 'a' * 64, owner), isTrue);
      expect(scopedRequests.map((request) => request.$1), [owner]);
      expect(scopedRequests.single.$2.channelId, channelId);
      expect(scopedRequests.single.$2.channelEpoch, 1);
      expect(scopedPulls.single.$1, [owner]);
      final syncVector = (await bobSvc.buildGroupSyncRequest(spaceId))!;
      expect((syncVector['g'] as Map)[bob.hex], isNull);
      final protectedHead =
          chainOf(
                syncVector['cg'] as Map,
                '${channelId!.hex}|channelEpoch:1',
              )[bob.hex]
              as Map;
      expect(protectedHead['s'], 1);
      expect(protectedHead['h'], groupMessageHash(storedMedia));
      expect((syncVector['r'] as Map)[bob.hex], isNull);
      expect(
        (((syncVector['cr'] as Map)['${channelId.hex}|channelEpoch:1']
            as Map)[bob.hex]),
        0,
      );
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson(reactedBobBundle, recipient: owner),
        ),
        isTrue,
      );
      expect(
        (await ownerSvc.messagesOf(
          spaceId,
          channelId: channelId,
        )).map((message) => message.body),
        ['channel-key ciphertext', 'protected media'],
      );
      expect(
        (await ownerSvc.reactionsOf(spaceId))[protectedTarget.ref]?['🔐'],
        [bob],
      );
      final reactionGapRequest =
          jsonDecode(jsonEncode(syncVector)) as Map<String, dynamic>;
      reactionGapRequest['r'] = {bob.hex: 99};
      (reactionGapRequest['cr'] as Map)['${channelId.hex}|channelEpoch:1'] =
          <String, int>{};
      sentSync.clear();
      expect(
        await ownerSvc.handleGroupSyncRequest(bob, reactionGapRequest),
        isTrue,
      );
      final reactionGapDelta = jsonDecode(sentSync.single.$2) as Map;
      expect((reactionGapDelta['r'] as List), hasLength(1));
      expect(
        GroupReaction.fromJson(
          (reactionGapDelta['r'] as List).single,
        )?.isChannelEncrypted,
        isTrue,
      );
      sentSync.clear();
      expect(
        await ownerSvc.handleGroupSyncRequest(carol, reactionGapRequest),
        isFalse,
        reason: 'a Space member outside the channel gets no reaction delta',
      );
      expect(sentSync, isEmpty);
      GroupContentRequest signedRequest(
        NodeId requester, {
        required String nonce,
        NodeId? scopedChannel,
        int? scopedEpoch,
      }) => _FakeSigner(requester).signContentRequest(
        GroupContentRequest(
          groupId: spaceId,
          contentId: 'a' * 64,
          requester: requester,
          nonce: nonce,
          tsMs: DateTime.now().millisecondsSinceEpoch,
          channelId: scopedChannel,
          channelEpoch: scopedEpoch,
          signature: Uint8List(0),
        ),
      );
      expect(
        await ownerSvc.handleContentRequest(
          jsonEncode(signedRequest(bob, nonce: 'bob-unscoped').toJson()),
        ),
        isFalse,
        reason: 'legacy Space-wide grants cannot unlock protected refs',
      );
      expect(
        await ownerSvc.handleContentRequest(
          jsonEncode(
            signedRequest(
              carol,
              nonce: 'carol-scoped',
              scopedChannel: channelId,
              scopedEpoch: 1,
            ).toJson(),
          ),
        ),
        isFalse,
        reason: 'a current Space member outside channel ACL gets no grant',
      );
      expect(
        await ownerSvc.handleContentRequest(
          jsonEncode(
            signedRequest(
              bob,
              nonce: 'bob-scoped',
              scopedChannel: channelId,
              scopedEpoch: 1,
            ).toJson(),
          ),
        ),
        isTrue,
      );
      expect(contentGrants, [(bob, 'a' * 64)]);

      final deletionId = await ownerSvc.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.deleteMessage,
        target: bob,
        scope: SpaceModerationScope.channel,
        reason: 'sensitive incident cleanup',
        channelId: channelId,
        reference: SpaceModerationReference(
          kind: SpaceModerationReferenceKind.message,
          author: bob,
          seq: storedMedia.seq,
          channelId: channelId,
        ),
      );
      expect(deletionId, isNotNull);
      final moderatedBundle = (await ownerSvc.load(spaceId))!;
      final protectedModeration = moderatedBundle.control.last;
      expect(protectedModeration.version, 14);
      expect(protectedModeration.channelModeration?.channelId, channelId);
      expect(protectedModeration.target, isNull);
      expect(protectedModeration.moderationAction, isNull);
      final moderationWire = jsonEncode(protectedModeration.toJson());
      expect(moderationWire, isNot(contains(bob.hex)));
      expect(moderationWire, isNot(contains(storedMedia.ref)));
      expect(moderationWire, isNot(contains('sensitive incident cleanup')));
      expect(moderationWire, isNot(contains('incident-report')));
      expect(
        (await ownerSvc.messagesOf(
          spaceId,
          channelId: channelId,
        )).map((message) => message.body),
        ['channel-key ciphertext'],
      );
      expect(
        await ownerSvc.referencedContentIds(spaceId),
        isNot(contains('a' * 64)),
      );
      final audit = await ownerSvc.spaceModerationAudit(spaceId);
      expect(audit.map((record) => record.actionId), contains(deletionId));
      expect(
        audit
            .singleWhere((record) => record.actionId == deletionId)
            .action
            .reason,
        'sensitive incident cleanup',
      );
      expect(
        await ownerSvc.handleContentRequest(
          jsonEncode(
            signedRequest(
              bob,
              nonce: 'bob-after-moderation',
              scopedChannel: channelId,
              scopedEpoch: 1,
            ).toJson(),
          ),
        ),
        isFalse,
        reason: 'moderated-away media is no longer grantable',
      );

      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(moderatedBundle, recipient: bob),
        ),
        isTrue,
      );
      expect(
        (await bobSvc.messagesOf(
          spaceId,
          channelId: channelId,
        )).map((message) => message.body),
        ['channel-key ciphertext'],
      );
      expect(
        (await bobSvc.spaceModerationAudit(
          spaceId,
        )).map((record) => record.actionId),
        contains(deletionId),
      );

      final carolStorage = FakeHvContainer().storage();
      await carolStorage.open(password: 'pw', createIfMissing: true);
      final carolSvc = GroupService(
        carolStorage,
        _FakeSigner(carol),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      expect(
        await carolSvc.ingestSnapshot(
          ownerSvc.snapshotJson(moderatedBundle, recipient: carol),
        ),
        isTrue,
      );
      expect(await carolSvc.spaceModerationAudit(spaceId), isEmpty);
      expect(
        (await carolSvc.stateOf(spaceId))!.protectedModeration,
        contains(deletionId),
        reason: 'outsiders retain signed opaque evidence without plaintext',
      );
      expect(
        await ownerSvc.setChannelMembers(spaceId, channelId, const []),
        isTrue,
      );
      expect(
        (await ownerSvc.reactionsOf(spaceId))[protectedTarget.ref],
        isNull,
        reason: 'revoked channel authors no longer contribute reaction state',
      );
      expect(
        (await ownerSvc.stateOf(
          spaceId,
        ))!.protectedChannels[channelId.hex]!.channelEpoch,
        2,
      );
      expect(
        await ownerSvc.handleContentRequest(
          jsonEncode(
            signedRequest(
              bob,
              nonce: 'bob-stale-epoch',
              scopedChannel: channelId,
              scopedEpoch: 1,
            ).toJson(),
          ),
        ),
        isFalse,
        reason: 'ACL rotation immediately invalidates old scoped requests',
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        (await bobSvc.channelsOf(
          spaceId,
        )).where((channel) => channel.channelId == channelId),
        isEmpty,
      );
      expect(
        await bobSvc.postMessage(
          spaceId,
          'stale key write',
          channelId: channelId,
          broadcast: false,
        ),
        isFalse,
      );
    },
  );

  test(
    'protected retention stays ciphertext-only, owner-only and irreversible',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      addTearDown(ownerSvc.dispose);
      final spaceId = await ownerSvc.createSpace('Protected retention');
      for (final peer in [bob, carol]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: peer,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      final channelId = await ownerSvc.createChannel(
        spaceId,
        name: 'retained privately',
        kind: SpaceChannelKind.text,
        history: SpaceChannelHistory.full,
        access: SpaceChannelAccess.restricted,
        members: [bob],
      );
      expect(channelId, isNotNull);

      var bundle = (await ownerSvc.load(spaceId))!;
      final state = (await ownerSvc.stateOf(spaceId))!;
      final opaque = state.protectedChannels[channelId!.hex]!;
      final channelKey = bundle.localChannelEpochKeys['${channelId.hex}:1']!;
      final oldAt =
          DateTime.now().millisecondsSinceEpoch -
          const Duration(days: 10).inMilliseconds;
      final clearMessage = GroupMessageCleartext(
        body: 'old protected evidence',
        attachment: MediaObject(
          kind: 'file',
          contentId: 'd' * 64,
          name: 'old.bin',
          size: 16,
        ),
      ).encode();
      final encryptedMessage = await encryptSpaceChannelMessagePayload(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: opaque.channelEpoch,
        author: owner,
        seq: 0,
        prevHash: '',
        policyVersion: state.policyVersion,
        createdAtMs: oldAt,
        clearText: clearMessage,
        channelKey: channelKey,
      );
      clearMessage.fillRange(0, clearMessage.length, 0);
      final oldMessage = _FakeSigner(owner).signMessage(
        GroupMessage(
          version: 3,
          groupId: spaceId,
          channelId: channelId,
          channelEpoch: opaque.channelEpoch,
          encryptedPayload: encryptedMessage,
          author: owner,
          seq: 0,
          prevHash: '',
          body: '',
          policyVersion: state.policyVersion,
          createdAtMs: oldAt,
          signature: Uint8List(0),
        ),
      );
      expect(
        await ownerSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            bundle.copyWith(messages: [oldMessage]),
            recipient: owner,
          ),
        ),
        isTrue,
      );
      expect(
        (await ownerSvc.messagesOf(spaceId, channelId: channelId)).single.body,
        'old protected evidence',
      );

      expect(
        await ownerSvc.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.keepForever,
            channelId: channelId,
          ),
        ),
        isTrue,
      );
      bundle = (await ownerSvc.load(spaceId))!;
      final protectedRow = bundle.control.last;
      expect(protectedRow.version, 15);
      expect(protectedRow.channelRetention?.channelId, channelId);
      expect(protectedRow.retentionPolicy, isNull);
      final protectedWire = jsonEncode(protectedRow.toJson());
      expect(protectedWire, isNot(contains('keepForever')));
      expect(protectedWire, isNot(contains('retentionMs')));
      expect(
        (await ownerSvc.spaceRetentionPolicyOf(
          spaceId,
          channelId: channelId,
        ))?.mode,
        SpaceRetentionMode.keepForever,
      );
      expect(
        await ownerSvc.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            retentionMs: const Duration(days: 1).inMilliseconds,
          ),
        ),
        isTrue,
      );
      expect(
        await ownerSvc.messagesOf(spaceId, channelId: channelId),
        hasLength(1),
        reason: 'the encrypted channel override wins over the Space policy',
      );

      expect(
        await ownerSvc.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            channelId: channelId,
            retentionMs: const Duration(days: 1).inMilliseconds,
            mediaOnly: true,
          ),
        ),
        isTrue,
      );
      final mediaOnlyRow = (await ownerSvc.load(spaceId))!.control.last;
      expect(mediaOnlyRow.version, 15);
      expect(mediaOnlyRow.retentionPolicy, isNull);
      expect(jsonEncode(mediaOnlyRow.toJson()), isNot(contains('mediaOnly')));
      final retainedText = await ownerSvc.messagesOf(
        spaceId,
        channelId: channelId,
      );
      expect(retainedText, hasLength(1));
      expect(retainedText.single.body, 'old protected evidence');
      expect(retainedText.single.attachment, isNull);
      expect(retainedText.single.mediaHiddenByRetention, isTrue);
      expect(
        await ownerSvc.referencedContentIds(spaceId),
        isNot(contains('d' * 64)),
      );
      expect(
        await ownerSvc.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.keepForever,
            channelId: channelId,
          ),
        ),
        isTrue,
      );
      final stillRedacted = await ownerSvc.messagesOf(
        spaceId,
        channelId: channelId,
      );
      expect(stillRedacted, hasLength(1));
      expect(stillRedacted.single.attachment, isNull);
      expect(
        stillRedacted.single.mediaHiddenByRetention,
        isTrue,
        reason: 'relaxing policy must not resurrect retired protected media',
      );

      expect(
        await ownerSvc.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            channelId: channelId,
            retentionMs: const Duration(days: 1).inMilliseconds,
          ),
        ),
        isTrue,
      );
      expect(await ownerSvc.messagesOf(spaceId, channelId: channelId), isEmpty);
      expect(
        await ownerSvc.referencedContentIds(spaceId),
        isNot(contains('d' * 64)),
      );
      expect(
        await ownerSvc.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.keepForever,
            channelId: channelId,
          ),
        ),
        isTrue,
      );
      expect(
        await ownerSvc.messagesOf(spaceId, channelId: channelId),
        isEmpty,
        reason: 'a relaxed encrypted revision cannot resurrect retired data',
      );

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      addTearDown(bobSvc.dispose);
      bundle = (await ownerSvc.load(spaceId))!;
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(bundle, recipient: bob),
        ),
        isTrue,
      );
      expect(await bobSvc.messagesOf(spaceId, channelId: channelId), isEmpty);
      expect(
        (await bobSvc.spaceRetentionHistoryOf(
          spaceId,
        )).where((revision) => revision.policy.channelId == channelId),
        hasLength(5),
      );

      final bobBundle = (await bobSvc.load(spaceId))!;
      final bobState = (await bobSvc.stateOf(spaceId))!;
      final forgedAt = DateTime.now().millisecondsSinceEpoch + 1;
      final forgedPolicy = SpaceRetentionPolicy(
        mode: SpaceRetentionMode.keepForever,
        channelId: channelId,
      );
      final forgedClear = Uint8List.fromList(
        utf8.encode(jsonEncode(forgedPolicy.toJson())),
      );
      final forgedEncrypted = await encryptSpaceChannelRetentionPayload(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: opaque.channelEpoch,
        author: bob,
        seq: 0,
        prevHash: '',
        policyVersion: bobState.policyVersion,
        createdAtMs: forgedAt,
        clearText: forgedClear,
        channelKey: bobBundle.localChannelEpochKeys['${channelId.hex}:1']!,
      );
      forgedClear.fillRange(0, forgedClear.length, 0);
      final forged = _FakeSigner(bob).signControl(
        ControlEntry(
          version: 15,
          groupId: spaceId,
          author: bob,
          seq: 0,
          prevHash: '',
          op: ControlOp.setRetention,
          target: null,
          role: null,
          channelRetention: SpaceChannelRetentionEnvelope(
            spaceId: spaceId,
            channelId: channelId,
            channelEpoch: opaque.channelEpoch,
            encryptedPolicy: forgedEncrypted,
          ),
          policyVersion: bobState.policyVersion,
          createdAtMs: forgedAt,
          signature: Uint8List(0),
        ),
      );
      expect(
        await ownerSvc.ingestSnapshot(
          jsonEncode({
            'm': bundle.manifest.toJson(),
            'c': [forged.toJson()],
            'g': const [],
            'r': const [],
            'p': const [],
          }),
        ),
        isTrue,
      );
      expect(
        (await ownerSvc.stateOf(spaceId))!.protectedRetention,
        isNot(contains('${bob.hex}:0')),
        reason: 'manageStorage remains owner-only in the pure fold',
      );

      final carolStorage = FakeHvContainer().storage();
      await carolStorage.open(password: 'pw', createIfMissing: true);
      final carolSvc = GroupService(
        carolStorage,
        _FakeSigner(carol),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      addTearDown(carolSvc.dispose);
      expect(
        await carolSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: carol,
          ),
        ),
        isTrue,
      );
      expect(
        await carolSvc.spaceRetentionPolicyOf(spaceId, channelId: channelId),
        isNull,
      );
      expect(
        (await carolSvc.spaceRetentionHistoryOf(
          spaceId,
        )).where((revision) => revision.policy.channelId == channelId),
        isEmpty,
      );

      expect(
        await ownerSvc.setChannelMembers(spaceId, channelId, [bob, carol]),
        isTrue,
        reason: 'the owner rewraps the effective override for the new epoch',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'post-rekey history',
          channelId: channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await carolSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: carol,
          ),
        ),
        isTrue,
      );
      expect(
        (await carolSvc.spaceRetentionPolicyOf(
          spaceId,
          channelId: channelId,
        ))?.mode,
        SpaceRetentionMode.keepForever,
      );
      expect(
        (await carolSvc.messagesOf(
          spaceId,
          channelId: channelId,
        )).map((message) => message.body),
        ['post-rekey history'],
        reason:
            'new recipients see post-rekey history without receiving old keys',
      );
    },
  );

  test(
    'a retention revision signed with the wrong year used to freeze the whole '
    'timeline: no later revision, from any device, could change the policy '
    'again until that year arrived',
    () async {
      const day = 24 * 60 * 60 * 1000;
      // The read path evaluates retention against the real clock, so the
      // signed history has to sit genuinely in the past; only the WRITE stamps
      // are driven.
      final realNow = DateTime.now().millisecondsSinceEpoch;
      final t0 = realNow - 100 * day;
      final hostileTs = realNow + 365 * day;

      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      var wall = t0;
      final svc = GroupService(
        storage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      )..debugWallClockMs = () => wall;
      addTearDown(svc.dispose);
      final spaceId = await svc.createSpace(
        'Shredder',
        visibility: SpaceVisibility.public,
        discoverable: true,
      );
      Future<List<String>> bodies() async =>
          (await svc.messagesOf(spaceId)).map((m) => m.body).toList();
      // Publications go through the OTHER builder — the synchronous clear-only
      // subset that snapshot assembly and the Feed read — so both are pinned.
      Future<List<String>> postBodies() async =>
          (await svc.postsOf(spaceId)).map((post) => post.body).toList();

      // A destructive policy, honestly dated, doing exactly what was asked.
      expect(await svc.postMessage(spaceId, 'first'), isTrue);
      expect(
        await svc.publishSpacePost(spaceId, body: 'post one', broadcast: false),
        isNotNull,
      );
      wall = t0 + day;
      expect(
        await svc.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            retentionMs: day,
          ),
        ),
        isTrue,
      );
      // Read a moment past the boundary rather than exactly on it. The rows
      // were stamped by the service's monotonic counter, so 'first' is a
      // millisecond or two YOUNGER than `t0` and is not a full day old when
      // the wall reads `t0 + day`. This used to pass on the boundary only
      // because the two readers took the REAL clock (a hundred days ahead of
      // this fixture) while every write took the driven one; now both follow
      // the clock the test is driving.
      wall = t0 + day + 1000;
      expect(await bodies(), isNot(contains('first')));
      expect(await postBodies(), isNot(contains('post one')));

      // The owner tries to STOP the shredding from a device whose clock reads
      // 2027, and the revision is signed with that year inside it.
      final wrongClock = GroupService(storage, _FakeSigner(owner))
        ..debugWallClockMs = () => hostileTs;
      expect(
        await wrongClock.setSpaceRetentionPolicy(
          spaceId,
          const SpaceRetentionPolicy(mode: SpaceRetentionMode.keepForever),
        ),
        isTrue,
      );
      wrongClock.dispose();
      expect(
        await svc.spaceRetentionHistoryOf(spaceId),
        hasLength(1),
        reason:
            'the 2027 revision is signed and accepted and simply has not '
            'happened yet as far as this clock is concerned — deferring it is '
            'right, and the destructive policy is still the one in force',
      );

      wall = t0 + 2 * day;
      expect(await svc.postMessage(spaceId, 'second'), isTrue);
      // Observed a day later rather than at the instant it was written: the
      // policy in force deletes after a day, and a reader that honours the
      // driven clock cannot see a zero-second-old row as expired.
      wall = t0 + 3 * day;
      expect(await bodies(), isNot(contains('second')));

      // The correction, from a device whose clock is right. Under the old rule
      // the monotone activation clamp lifted THIS revision to 2027 as well —
      // and would lift every revision after it, forever — so the owner could
      // not stop their own Space from deleting its history by any signed
      // operation at all. Not by re-issuing the policy, not from another
      // device, not by removing whoever wrote the bad row.
      wall = t0 + 3 * day;
      expect(
        await svc.setSpaceRetentionPolicy(
          spaceId,
          const SpaceRetentionPolicy(mode: SpaceRetentionMode.keepForever),
        ),
        isTrue,
      );
      wall = t0 + 4 * day;
      expect(await svc.postMessage(spaceId, 'third'), isTrue);
      expect(
        await svc.publishSpacePost(
          spaceId,
          body: 'post three',
          broadcast: false,
        ),
        isNotNull,
      );

      final history = await svc.spaceRetentionHistoryOf(spaceId);
      expect(history, hasLength(2));
      expect(history.last.policy.mode, SpaceRetentionMode.keepForever);
      expect(
        history.last.activatedAtMs,
        lessThan(hostileTs),
        reason:
            'the correction keeps its own stamp instead of being dragged '
            'up to the floor an unbelievable row would have set',
      );
      expect(
        await bodies(),
        contains('third'),
        reason:
            'and it takes effect NOW: an unbelievable stamp is left out of '
            'the timeline instead of raising the floor under every honest '
            'revision behind it',
      );
      expect(
        await postBodies(),
        contains('post three'),
        reason:
            'and the same on the publication side, which reads the OTHER '
            'builder — a fix in one of the two is half a fix',
      );
      expect(
        await bodies(),
        isNot(contains('first')),
        reason: 'relaxing later still does not resurrect what was retired',
      );
      expect(await bodies(), isNot(contains('second')));
      expect(await postBodies(), isNot(contains('post one')));

      await storage.close();
    },
  );

  test(
    'a retention revision dated ahead is DEFERRED, not discarded: it joins the '
    'timeline when the clock reaches it',
    () async {
      const day = 24 * 60 * 60 * 1000;
      final realNow = DateTime.now().millisecondsSinceEpoch;
      final t0 = realNow - 100 * day;
      final hostileTs = realNow + 365 * day;

      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      var wall = t0;
      final svc = GroupService(storage, _FakeSigner(owner))
        ..debugWallClockMs = () => wall;
      addTearDown(svc.dispose);
      final spaceId = await svc.createSpace('Deferred');
      expect(await svc.postMessage(spaceId, 'old row'), isTrue);

      final wrongClock = GroupService(storage, _FakeSigner(owner))
        ..debugWallClockMs = () => hostileTs;
      expect(
        await wrongClock.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            retentionMs: day,
          ),
        ),
        isTrue,
      );
      wrongClock.dispose();

      wall = t0 + 3 * day;
      expect(
        await svc.spaceRetentionHistoryOf(spaceId),
        isEmpty,
        reason:
            'a stamp no clock here could have produced is not in the '
            'timeline at all, so it cannot carry anything with it',
      );
      expect(
        (await svc.messagesOf(spaceId)).map((m) => m.body),
        contains('old row'),
        reason: 'and a policy that has not activated retires nothing',
      );

      wall = hostileTs + 3 * day;
      final later = await svc.spaceRetentionHistoryOf(spaceId);
      expect(later, hasLength(1));
      expect(later.single.policy.mode, SpaceRetentionMode.deleteAfter);
      expect(
        later.single.activatedAtMs,
        greaterThanOrEqualTo(hostileTs),
        reason:
            'when its own time arrives it applies exactly as its author '
            'wrote it — excluded means postponed, never dropped',
      );

      await storage.close();
    },
  );

  test(
    'media-only retention keeps signed text and irreversibly retires grants',
    () async {
      final signer = _FakeSigner(owner);
      final sourceStorage = FakeHvContainer().storage();
      await sourceStorage.open(password: 'pw', createIfMissing: true);
      final source = GroupService(sourceStorage, signer);
      addTearDown(source.dispose);
      final spaceId = await source.createSpace(
        'Media-only retention',
        visibility: SpaceVisibility.public,
      );
      final post = await source.publishSpacePost(
        spaceId,
        title: 'Retained publication',
        body: 'signed post text remains',
        media: [
          MediaObject(
            kind: 'image',
            contentId: 'a' * 64,
            name: 'old.png',
            size: 32,
          ),
        ],
        broadcast: false,
      );
      expect(post, isNotNull);
      expect(
        await source.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            retentionMs: const Duration(days: 1).inMilliseconds,
            mediaOnly: true,
          ),
        ),
        isTrue,
      );
      var bundle = (await source.load(spaceId))!;
      expect(bundle.control.last.version, 16);
      expect(bundle.control.last.retentionPolicy?.mediaOnly, isTrue);
      final oldAt =
          DateTime.now().millisecondsSinceEpoch -
          const Duration(days: 10).inMilliseconds;
      final oldPost = signer.signPost(
        SpacePost(
          spaceId: post!.spaceId,
          author: post.author,
          seq: post.seq,
          prevHash: post.prevHash,
          type: post.type,
          visibility: post.visibility,
          title: post.title,
          body: post.body,
          media: post.media,
          policyVersion: post.policyVersion,
          createdAtMs: oldAt,
          publishedAtMs: oldAt,
          version: post.version,
          membershipEpoch: post.membershipEpoch,
          encryptedPayload: post.encryptedPayload,
          controlFrontier: post.controlFrontier,
          controlCheckpointHash: post.controlCheckpointHash,
          operation: post.operation,
          targetSeq: post.targetSeq,
          lifecycleGeneration: post.lifecycleGeneration,
          signature: Uint8List(0),
        ),
      );
      final oldMessage = signer.signMessage(
        GroupMessage(
          groupId: spaceId,
          author: owner,
          seq: 0,
          prevHash: '',
          body: 'signed message text remains',
          policyVersion: 0,
          createdAtMs: oldAt,
          signature: Uint8List(0),
          attachment: MediaObject(
            kind: 'image',
            contentId: 'b' * 64,
            inlinePreviewB64: 'QQ==',
            width: 1,
            height: 1,
            name: 'old-message.png',
          ),
        ),
      );
      bundle = bundle.copyWith(posts: [oldPost], messages: [oldMessage]);

      final readerStorage = FakeHvContainer().storage();
      await readerStorage.open(password: 'pw', createIfMissing: true);
      for (final contentId in ['a' * 64, 'b' * 64]) {
        await readerStorage.storeFile(
          contentId,
          Uint8List.fromList([1, 2, 3]),
          name: 'expired-media',
        );
        await readerStorage.storeFile(
          'mf:$contentId',
          Uint8List.fromList(utf8.encode('{"cid":"$contentId"}')),
          name: 'manifest',
        );
      }
      final reader = GroupService(readerStorage, signer);
      addTearDown(reader.dispose);
      expect(await reader.ingestSnapshot(source.snapshotJson(bundle)), isTrue);

      final visiblePosts = await reader.postsOf(spaceId);
      expect(visiblePosts, hasLength(1));
      expect(visiblePosts.single.body, 'signed post text remains');
      expect(visiblePosts.single.media, isEmpty);
      expect(visiblePosts.single.mediaHiddenByRetention, isTrue);
      final visibleMessages = await reader.messagesOf(spaceId);
      expect(visibleMessages, hasLength(1));
      expect(visibleMessages.single.body, 'signed message text remains');
      expect(visibleMessages.single.attachment, isNull);
      expect(visibleMessages.single.mediaHiddenByRetention, isTrue);
      expect(oldPost.media, hasLength(1), reason: 'signed row stays immutable');
      expect(oldMessage.toJson(), contains('att'));
      expect(await reader.referencedContentIds(spaceId), isEmpty);
      final gcStartedAt = DateTime.now().millisecondsSinceEpoch;
      final quarantined = await reader.sweepSharedContentGarbage(
        nowMs: gcStartedAt,
      );
      expect(quarantined.marked, 2);
      expect(quarantined.purged, 0);
      final reclaimed = await reader.sweepSharedContentGarbage(
        nowMs: gcStartedAt + kSharedContentGcGracePeriod.inMilliseconds,
      );
      expect(reclaimed.purged, 2);
      for (final contentId in ['a' * 64, 'b' * 64]) {
        expect(await readerStorage.hasFile(contentId), isFalse);
        expect(await readerStorage.hasFile('mf:$contentId'), isFalse);
      }

      expect(
        await reader.setSpaceRetentionPolicy(
          spaceId,
          const SpaceRetentionPolicy(mode: SpaceRetentionMode.keepForever),
        ),
        isTrue,
      );
      expect((await reader.postsOf(spaceId)).single.media, isEmpty);
      expect((await reader.messagesOf(spaceId)).single.attachment, isNull);
    },
  );

  test(
    'reaction lifecycle heads keep public state reconstructible outside a protected channel',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await ownerSvc.createSpace('Scoped reaction lifecycle');
      for (final peer in [bob, carol]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: peer,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      final publicChannel = (await ownerSvc.channelsOf(
        spaceId,
      )).singleWhere((channel) => channel.isDefault);
      final protectedChannel = await ownerSvc.createChannel(
        spaceId,
        name: 'private reactions',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
        members: [bob],
      );
      expect(protectedChannel, isNotNull);
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'public target',
          channelId: publicChannel.channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'protected target',
          channelId: protectedChannel,
          broadcast: false,
        ),
        isTrue,
      );
      final publicTarget = (await ownerSvc.messagesOf(
        spaceId,
        channelId: publicChannel.channelId,
      )).single;
      final protectedTarget = (await ownerSvc.messagesOf(
        spaceId,
        channelId: protectedChannel,
      )).single;
      expect(
        await ownerSvc.react(spaceId, publicTarget.ref, '🌍', broadcast: false),
        isTrue,
      );
      expect(
        await ownerSvc.react(
          spaceId,
          protectedTarget.ref,
          '🔐',
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        (await ownerSvc.load(spaceId))!.reactions.map((row) => row.version),
        [4, 7],
      );
      expect(await ownerSvc.setSpaceArchived(spaceId, true), isTrue);
      final archived = (await ownerSvc.load(spaceId))!;
      final transition = (await ownerSvc.stateOf(
        spaceId,
      ))!.lifecycleTransition!;
      expect(transition.reactionHeads, hasLength(2));
      expect(
        transition.reactionHeads.map((head) => head.scopeHash).toSet().length,
        2,
      );

      Future<GroupService> replica(NodeId peer) async {
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'pw', createIfMissing: true);
        return GroupService(
          storage,
          _FakeSigner(peer),
          epochService: GroupEpochService(
            LoopbackMailboxCrypto(senderForOpen: owner),
          ),
        );
      }

      final carolSvc = await replica(carol);
      final carolWire = ownerSvc.snapshotJson(archived, recipient: carol);
      expect((jsonDecode(carolWire) as Map)['r'], hasLength(1));
      expect(await carolSvc.ingestSnapshot(carolWire), isTrue);
      expect(
        (await carolSvc.reactionsOf(spaceId))[publicTarget.ref]?['🌍'],
        [owner],
        reason: 'a missing protected scope head cannot hide the public prefix',
      );
      expect(
        (await carolSvc.reactionsOf(spaceId))[protectedTarget.ref],
        isNull,
      );

      final bobSvc = await replica(bob);
      final bobWire = ownerSvc.snapshotJson(archived, recipient: bob);
      expect((jsonDecode(bobWire) as Map)['r'], hasLength(2));
      expect(await bobSvc.ingestSnapshot(bobWire), isTrue);
      final bobReactions = await bobSvc.reactionsOf(spaceId);
      expect(bobReactions[publicTarget.ref]?['🌍'], [owner]);
      expect(bobReactions[protectedTarget.ref]?['🔐'], [owner]);

      expect(await ownerSvc.setSpaceArchived(spaceId, false), isTrue);
      expect(
        await ownerSvc.react(
          spaceId,
          protectedTarget.ref,
          '✅',
          broadcast: false,
        ),
        isTrue,
      );
      final restoredReaction = (await ownerSvc.load(spaceId))!.reactions.last;
      expect(restoredReaction.version, 8);
      expect(
        restoredReaction.lifecycleGeneration,
        (await ownerSvc.stateOf(spaceId))!.lifecycleTransitionHash,
      );
      expect(jsonEncode(restoredReaction.toJson()), isNot(contains('✅')));
    },
  );

  test(
    'protected moderation rechecks the encrypted target rank fail-closed',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      final spaceId = await ownerSvc.createSpace('Protected moderation ACL');
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.admin,
        ),
        isTrue,
      );
      final channelId = await ownerSvc.createChannel(
        spaceId,
        name: 'admin-visible',
        kind: SpaceChannelKind.text,
        access: SpaceChannelAccess.restricted,
        members: [bob],
      );
      expect(channelId, isNotNull);
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'owner evidence',
          channelId: channelId,
          broadcast: false,
        ),
        isTrue,
      );
      final target = (await ownerSvc.messagesOf(
        spaceId,
        channelId: channelId,
      )).single;

      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        epochService: GroupEpochService(
          LoopbackMailboxCrypto(senderForOpen: owner),
        ),
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      expect(
        await bobSvc.moderateSpace(
          spaceId,
          kind: SpaceModerationKind.deleteMessage,
          target: owner,
          scope: SpaceModerationScope.channel,
          reason: 'admin cannot moderate owner',
          channelId: channelId,
          reference: SpaceModerationReference(
            kind: SpaceModerationReferenceKind.message,
            author: owner,
            seq: target.seq,
            channelId: channelId,
          ),
        ),
        isNull,
      );

      final bobBundle = (await bobSvc.load(spaceId))!;
      final bobState = (await bobSvc.stateOf(spaceId))!;
      final opaque = bobState.protectedChannels[channelId!.hex]!;
      final key = bobBundle.localChannelEpochKeys['${channelId.hex}:1']!;
      final createdAt = target.createdAtMs + 100;
      final hiddenAction = SpaceModerationAction(
        kind: SpaceModerationKind.deleteMessage,
        target: owner,
        scope: SpaceModerationScope.channel,
        reason: 'forged privileged deletion',
        createdAtMs: createdAt,
        channelId: channelId,
        reference: SpaceModerationReference(
          kind: SpaceModerationReferenceKind.message,
          author: owner,
          seq: target.seq,
          channelId: channelId,
        ),
      );
      final clear = Uint8List.fromList(
        utf8.encode(jsonEncode(hiddenAction.toJson())),
      );
      final encrypted = await encryptSpaceChannelModerationPayload(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: opaque.channelEpoch,
        author: bob,
        seq: 0,
        prevHash: '',
        policyVersion: bobState.policyVersion,
        createdAtMs: createdAt,
        clearText: clear,
        channelKey: key,
      );
      clear.fillRange(0, clear.length, 0);
      final malicious = _FakeSigner(bob).signControl(
        ControlEntry(
          version: 14,
          groupId: spaceId,
          author: bob,
          seq: 0,
          prevHash: '',
          op: ControlOp.moderate,
          target: null,
          role: null,
          channelModeration: SpaceChannelModerationEnvelope(
            spaceId: spaceId,
            channelId: channelId,
            channelEpoch: opaque.channelEpoch,
            encryptedAction: encrypted,
          ),
          policyVersion: bobState.policyVersion,
          createdAtMs: createdAt,
          signature: Uint8List(0),
        ),
      );
      final ownerBundle = (await ownerSvc.load(spaceId))!;
      expect(
        await ownerSvc.ingestSnapshot(
          jsonEncode({
            'm': ownerBundle.manifest.toJson(),
            'c': [malicious.toJson()],
            'g': const [],
            'r': const [],
            'p': const [],
          }),
        ),
        isTrue,
      );
      expect(
        (await ownerSvc.stateOf(spaceId))!.protectedModeration,
        contains('${bob.hex}:0'),
        reason: 'the signed opaque row remains convergent audit evidence',
      );
      expect(await ownerSvc.spaceModerationAudit(spaceId), isEmpty);
      expect(
        (await ownerSvc.messagesOf(
          spaceId,
          channelId: channelId,
        )).map((message) => message.body),
        ['owner evidence'],
        reason: 'hidden target authority is rechecked before enforcement',
      );
    },
  );

  test(
    'Space moderation is signed and reversible without changing group chats',
    () async {
      final (ownerSvc, member) = await setup();
      final bobSvc = member(bob);
      final groupId = await ownerSvc.createGroup('Friends chat');

      expect(
        await ownerSvc.moderateSpace(
          groupId,
          kind: SpaceModerationKind.warning,
          target: owner,
          scope: SpaceModerationScope.space,
          reason: 'must remain a group chat',
        ),
        isNull,
      );
      expect((await ownerSvc.load(groupId))!.manifest.isSpace, isFalse);
      expect(
        (await ownerSvc.listGroups()).map((entry) => entry.groupId),
        contains(groupId),
      );
      expect(
        (await ownerSvc.listSpaces()).map((entry) => entry.groupId),
        isNot(contains(groupId)),
      );

      final spaceId = await ownerSvc.createSpace(
        'Builders',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(await bobSvc.postMessage(spaceId, 'before restriction'), isTrue);

      final actionId = await ownerSvc.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.restrictMessages,
        target: bob,
        scope: SpaceModerationScope.space,
        reason: 'cool-down',
        expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
      );
      expect(actionId, isNotNull);
      expect(await bobSvc.postMessage(spaceId, 'blocked'), isFalse);
      final audit = await ownerSvc.spaceModerationAudit(spaceId);
      expect(audit, hasLength(1));
      expect(audit.single.actionId, actionId);
      expect(audit.single.action.reason, 'cool-down');

      expect(
        await ownerSvc.revokeSpaceModeration(
          spaceId,
          actionId!,
          reason: 'review complete',
        ),
        isTrue,
      );
      expect(await bobSvc.postMessage(spaceId, 'after review'), isTrue);
      final revoked = (await ownerSvc.spaceModerationAudit(spaceId)).single;
      expect(revoked.revokedBy, owner);
      expect(revoked.revocationReason, 'review complete');
      expect(
        (await ownerSvc.listSpaces()).map((entry) => entry.groupId),
        contains(spaceId),
      );
      expect(
        (await ownerSvc.listGroups()).map((entry) => entry.groupId),
        isNot(contains(spaceId)),
      );
    },
  );

  test(
    'two moderation appeals arriving at once do not lose one another',
    () async {
      // Last of the inbound gates with this shape. Two appeals landing
      // together is ordinary once a Space has several restricted members; here
      // one member appeals two separate actions, which is the same collision
      // with half the scene.
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final captured = <String>[];
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
      final bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        // Capture instead of delivering, so both arrivals start together.
        sendSpaceModerationAppeal: (peer, appealId, appealJson) async =>
            captured.add(appealJson),
      );
      addTearDown(ownerSvc.dispose);
      addTearDown(bobSvc.dispose);

      final spaceId = await ownerSvc.createSpace('Concurrent appeals');
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      Future<void> mirror() async {
        expect(
          await bobSvc.ingestSnapshot(
            ownerSvc.snapshotJson(
              (await ownerSvc.load(spaceId))!,
              recipient: bob,
            ),
          ),
          isTrue,
        );
      }

      await mirror();
      final first = await ownerSvc.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.restrictMessages,
        target: bob,
        scope: SpaceModerationScope.space,
        reason: 'first action',
      );
      final second = await ownerSvc.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.mute,
        target: bob,
        scope: SpaceModerationScope.space,
        reason: 'second action',
      );
      expect(first, isNotNull);
      expect(second, isNotNull);
      await mirror();

      expect(
        await bobSvc.appealSpaceModeration(spaceId, first!, text: 'First'),
        isTrue,
      );
      expect(
        await bobSvc.appealSpaceModeration(spaceId, second!, text: 'Second'),
        isTrue,
      );
      expect(captured.length, 2);

      final results = await Future.wait([
        ownerSvc.receiveSpaceModerationAppeal(bob, captured[0]),
        ownerSvc.receiveSpaceModerationAppeal(bob, captured[1]),
      ]);
      expect(results, [isTrue, isTrue]);

      final inbox = await ownerSvc.incomingSpaceModerationAppeals();
      expect(
        inbox.map((entry) => entry.appeal.actionId).toSet(),
        {first, second},
        reason: 'a concurrent appeal must not erase the one before it',
      );
    },
  );

  test(
    'moderation appeal crosses the membership boundary once and revokes through signed audit',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await bobStorage.open(password: 'pw', createIfMissing: true);
      late final GroupService ownerSvc;
      late final GroupService bobSvc;
      ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        sendSpaceModerationAppealDecision:
            (peer, appealId, decisionJson) async {
              expect(peer, bob);
              expect(appealId, isNotEmpty);
              if (!await bobSvc.receiveSpaceModerationAppealDecision(
                owner,
                decisionJson,
              )) {
                throw StateError('decision rejected');
              }
            },
      );
      bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        sendSpaceModerationAppeal: (peer, appealId, appealJson) async {
          expect(peer, owner);
          expect(appealId, isNotEmpty);
          if (!await ownerSvc.receiveSpaceModerationAppeal(bob, appealJson)) {
            throw StateError('appeal rejected');
          }
        },
      );
      addTearDown(ownerSvc.dispose);
      addTearDown(bobSvc.dispose);

      final spaceId = await ownerSvc.createSpace('Appeal lab');
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final actionId = await ownerSvc.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.restrictMessages,
        target: bob,
        scope: SpaceModerationScope.space,
        reason: 'automated false positive',
      );
      expect(actionId, isNotNull);
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final candidate =
          (await bobSvc.appealableSpaceModerationActions()).single;
      expect(candidate.record.actionId, actionId);
      expect(candidate.spaceName, 'Appeal lab');

      expect(
        await bobSvc.appealSpaceModeration(
          spaceId,
          actionId!,
          text: 'Please review the source event.',
        ),
        isTrue,
      );
      final incoming = await ownerSvc.incomingSpaceModerationAppeals(
        spaceId: spaceId,
        pendingOnly: true,
      );
      expect(incoming, hasLength(1));
      expect(incoming.single.appeal.appellant, bob);
      expect(incoming.single.appeal.actionId, actionId);

      // Retrying sends the exact durable proposal and creates no new review.
      expect(
        await bobSvc.appealSpaceModeration(
          spaceId,
          actionId,
          text: 'A changed body must not create a second appeal.',
        ),
        isTrue,
      );
      expect(
        await ownerSvc.incomingSpaceModerationAppeals(spaceId: spaceId),
        hasLength(1),
      );

      expect(
        await ownerSvc.decideSpaceModerationAppeal(
          incoming.single.appeal.appealId,
          outcome: SpaceModerationAppealOutcome.actionRevoked,
          reason: 'review confirmed the false positive',
        ),
        isTrue,
      );
      final ownerRecord = (await ownerSvc.spaceModerationAudit(spaceId)).single;
      expect(ownerRecord.revokedBy, owner);
      expect(
        ownerRecord.revocationReason,
        'review confirmed the false positive',
      );
      final outgoing = (await bobSvc.outgoingSpaceModerationAppeals()).single;
      expect(
        outgoing.decision?.outcome,
        SpaceModerationAppealOutcome.actionRevoked,
      );
      expect(await bobSvc.appealableSpaceModerationActions(), isEmpty);
    },
  );

  test('a moderator dating its action into the future used to retire its '
      "target's right of appeal at every reviewer at once", () async {
    final t0 = DateTime.utc(2026, 8, 3, 12).millisecondsSinceEpoch;
    final hostileTs = t0 + const Duration(days: 365).inMilliseconds;

    final ownerStorage = FakeHvContainer().storage();
    final modStorage = FakeHvContainer().storage();
    final bobStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'pw', createIfMissing: true);
    await modStorage.open(password: 'pw', createIfMissing: true);
    await bobStorage.open(password: 'pw', createIfMissing: true);

    // The reviewer is the Space owner and its clock is honest; the harm is
    // not something the moderator does to its own copy.
    var ownerWall = t0;
    final decisions = <String>[];
    final ownerSvc = GroupService(
      ownerStorage,
      _FakeSigner(owner),
      sendSpaceModerationAppealDecision: (peer, appealId, decisionJson) async =>
          decisions.add(decisionJson),
    )..debugWallClockMs = () => ownerWall;
    // The moderator reads 2027.
    final modSvc = GroupService(modStorage, _FakeSigner(carol))
      ..debugWallClockMs = () => hostileTs;
    final captured = <String>[];
    var bobWall = t0;
    final bobSvc = GroupService(
      bobStorage,
      _FakeSigner(bob),
      sendSpaceModerationAppeal: (peer, appealId, appealJson) async =>
          captured.add(appealJson),
    )..debugWallClockMs = () => bobWall;
    addTearDown(ownerSvc.dispose);
    addTearDown(modSvc.dispose);
    addTearDown(bobSvc.dispose);

    final spaceId = await ownerSvc.createSpace('Appeal denial');
    for (final member in [bob, carol]) {
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: member,
          role: GroupRole.member,
        ),
        isTrue,
      );
    }
    expect(
      await ownerSvc.addControlOp(
        spaceId,
        ControlOp.setRole,
        target: carol,
        role: GroupRole.admin,
      ),
      isTrue,
    );
    Future<void> handTo(GroupService target, NodeId recipient) async {
      expect(
        await target.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: recipient,
          ),
        ),
        isTrue,
      );
    }

    await handTo(modSvc, carol);
    final actionId = await modSvc.moderateSpace(
      spaceId,
      kind: SpaceModerationKind.restrictMessages,
      target: bob,
      scope: SpaceModerationScope.space,
      reason: 'dated a year out',
    );
    expect(actionId, isNotNull);
    expect(
      await ownerSvc.ingestSnapshot(
        modSvc.snapshotJson((await modSvc.load(spaceId))!, recipient: owner),
      ),
      isTrue,
    );
    await handTo(bobSvc, bob);

    final candidate = (await bobSvc.appealableSpaceModerationActions()).single;
    expect(candidate.record.actionId, actionId);
    expect(
      candidate.record.action.createdAtMs,
      greaterThanOrEqualTo(hostileTs),
      reason:
          'the action really does claim to have been taken in 2027, and '
          "nothing about the moderator's signature says otherwise",
    );

    expect(
      await bobSvc.appealSpaceModeration(
        spaceId,
        actionId!,
        text: 'This was a mistake.',
      ),
      isTrue,
    );
    expect(captured, hasLength(1));
    final sent = SpaceModerationAppeal.fromJson(jsonDecode(captured.single))!;
    expect(
      sent.createdAtMs,
      lessThanOrEqualTo(bobWall + kSpacePublicClockSkew.inMilliseconds),
      reason:
          "the appellant signs its OWN clock; the moderator's number is "
          'not folded into it',
    );
    expect(sent.createdAtMs, lessThan(hostileTs));

    // Delivery takes a moment, and the reviewer's clock has moved on by the
    // time it lands. This is what tells "the action's stamp is excluded from
    // the comparison" apart from "the action's stamp is clamped to now",
    // which reads as equivalent and rejects every appeal that took any time
    // at all to arrive.
    ownerWall = t0 + const Duration(seconds: 30).inMilliseconds;
    expect(
      await ownerSvc.receiveSpaceModerationAppeal(bob, captured.single),
      isTrue,
      reason:
          'one number, chosen by the person being appealed against, must '
          'not be able to make the appeal unacceptable to its reviewer',
    );
    final incoming = await ownerSvc.incomingSpaceModerationAppeals(
      spaceId: spaceId,
      pendingOnly: true,
    );
    expect(incoming, hasLength(1));
    expect(incoming.single.appeal.appellant, bob);
    expect(
      incoming.single.receivedAtMs,
      lessThan(hostileTs),
      reason: "and the reviewer's inbox is not sorted by 2027 either",
    );

    // The decision has to be able to come back, which is the second place an
    // appeal's own stamp is weighed against a number from somewhere else:
    // the appellant refuses a decision dated before its appeal.
    expect(
      await ownerSvc.decideSpaceModerationAppeal(
        incoming.single.appeal.appealId,
        outcome: SpaceModerationAppealOutcome.rejected,
        reason: 'reviewed and upheld',
      ),
      isTrue,
    );
    expect(decisions, hasLength(1));
    bobWall = ownerWall + 5000;
    expect(
      await bobSvc.receiveSpaceModerationAppealDecision(
        owner,
        decisions.single,
      ),
      isTrue,
    );
    expect(
      (await bobSvc.outgoingSpaceModerationAppeals()).single.decision?.outcome,
      SpaceModerationAppealOutcome.rejected,
    );

    // One-sided, like the rest of this series: an honest moderator a few
    // minutes fast is believed, and appealing its action still works.
    final honestModSvc = GroupService(modStorage, _FakeSigner(carol))
      ..debugWallClockMs = () => t0 + const Duration(minutes: 3).inMilliseconds;
    addTearDown(honestModSvc.dispose);
    expect(
      await honestModSvc.ingestSnapshot(
        ownerSvc.snapshotJson(
          (await ownerSvc.load(spaceId))!,
          recipient: carol,
        ),
      ),
      isTrue,
    );
    final honestAction = await honestModSvc.moderateSpace(
      spaceId,
      kind: SpaceModerationKind.mute,
      target: bob,
      scope: SpaceModerationScope.space,
      reason: 'honestly a little fast',
    );
    expect(honestAction, isNotNull);
    expect(
      await ownerSvc.ingestSnapshot(
        honestModSvc.snapshotJson(
          (await honestModSvc.load(spaceId))!,
          recipient: owner,
        ),
      ),
      isTrue,
    );
    await handTo(bobSvc, bob);
    captured.clear();
    expect(
      await bobSvc.appealSpaceModeration(
        spaceId,
        honestAction!,
        text: 'And this one too.',
      ),
      isTrue,
    );
    ownerWall += 1000;
    expect(
      await ownerSvc.receiveSpaceModerationAppeal(bob, captured.single),
      isTrue,
    );

    await bobStorage.close();
    await modStorage.close();
    await ownerStorage.close();
  });

  test(
    'moderation appeal routes to the current owner after transfer',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(storage, _FakeSigner(owner));
      final carolSvc = GroupService(storage, _FakeSigner(carol));
      NodeId? recipient;
      final bobSvc = GroupService(
        storage,
        _FakeSigner(bob),
        sendSpaceModerationAppeal: (peer, appealId, appealJson) async {
          recipient = peer;
        },
      );
      addTearDown(ownerSvc.dispose);
      addTearDown(carolSvc.dispose);
      addTearDown(bobSvc.dispose);
      final spaceId = await ownerSvc.createSpace('Transferred review');
      for (final member in [bob, carol]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: member,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      expect(await ownerSvc.transferSpaceOwnership(spaceId, carol), isTrue);
      final actionId = await carolSvc.moderateSpace(
        spaceId,
        kind: SpaceModerationKind.warning,
        target: bob,
        scope: SpaceModerationScope.space,
        reason: 'current owner review',
      );
      expect(actionId, isNotNull);
      expect(
        await bobSvc.appealSpaceModeration(
          spaceId,
          actionId!,
          text: 'Route to the effective owner.',
        ),
        isTrue,
      );
      expect(recipient, carol);
      expect(recipient, isNot(owner));
    },
  );

  test('two abuse reports arriving at once do not lose one another', () async {
    // Last gate of this class. The inbox dedupes by (reporter, contentKey),
    // so ONE reporter filing on TWO posts is the same collision as two
    // reporters — and the per-reporter caps (16 pending, 32/day) leave room.
    final ownerStorage = FakeHvContainer().storage();
    final bobStorage = FakeHvContainer().storage();
    final carolStorage = FakeHvContainer().storage();
    await ownerStorage.open(password: 'pw', createIfMissing: true);
    await bobStorage.open(password: 'pw', createIfMissing: true);
    await carolStorage.open(password: 'pw', createIfMissing: true);

    final captured = <String>[];
    final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
    final bobSvc = GroupService(
      bobStorage,
      _FakeSigner(bob),
      // Capture instead of delivering, so both arrivals start together.
      sendSpaceAbuseReport: (peer, reportId, reportJson) async =>
          captured.add(reportJson),
    );
    final carolSvc = GroupService(carolStorage, _FakeSigner(carol));
    addTearDown(ownerSvc.dispose);
    addTearDown(bobSvc.dispose);
    addTearDown(carolSvc.dispose);

    final spaceId = await ownerSvc.createSpace(
      'Concurrent reports',
      visibility: SpaceVisibility.public,
    );
    for (final member in [bob, carol]) {
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: member,
          role: GroupRole.member,
        ),
        isTrue,
      );
    }
    final ownerBundle = (await ownerSvc.load(spaceId))!;
    for (final pair in [(bobSvc, bob), (carolSvc, carol)]) {
      expect(
        await pair.$1.ingestSnapshot(
          ownerSvc.snapshotJson(ownerBundle, recipient: pair.$2),
        ),
        isTrue,
      );
    }

    final firstPost = await carolSvc.publishSpacePost(
      spaceId,
      body: 'first publication under review',
      broadcast: false,
    );
    final secondPost = await carolSvc.publishSpacePost(
      spaceId,
      body: 'second publication under review',
      broadcast: false,
    );
    expect(firstPost, isNotNull);
    expect(secondPost, isNotNull);
    final carolBundle = (await carolSvc.load(spaceId))!;
    for (final pair in [(ownerSvc, owner), (bobSvc, bob)]) {
      expect(
        await pair.$1.ingestSnapshot(
          carolSvc.snapshotJson(carolBundle, recipient: pair.$2),
        ),
        isTrue,
      );
    }

    for (final post in [firstPost!, secondPost!]) {
      expect(
        await bobSvc.reportSpaceContent(
          spaceId,
          post.postId,
          category: SpaceAbuseCategory.harassment,
          details: 'Please review this publication.',
        ),
        isTrue,
      );
    }
    expect(captured.length, 2);

    final results = await Future.wait([
      ownerSvc.receiveSpaceAbuseReport(bob, captured[0]),
      ownerSvc.receiveSpaceAbuseReport(bob, captured[1]),
    ]);
    expect(results, [isTrue, isTrue]);

    final inbox = await ownerSvc.incomingSpaceAbuseReports(
      spaceId: spaceId,
      pendingOnly: true,
    );
    expect(
      inbox.map((entry) => entry.report.postId).toSet(),
      {firstPost.postId, secondPost.postId},
      reason: 'a concurrent report must not erase the one before it',
    );
  });

  test(
    'signed abuse report is deduplicated, reviewed and removes exact content through audit',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      final carolStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      await bobStorage.open(password: 'pw', createIfMissing: true);
      await carolStorage.open(password: 'pw', createIfMissing: true);

      late final GroupService ownerSvc;
      late final GroupService bobSvc;
      ownerSvc = GroupService(
        ownerStorage,
        _FakeSigner(owner),
        sendSpaceAbuseReportDecision: (peer, reportId, decisionJson) async {
          expect(peer, bob);
          expect(reportId, isNotEmpty);
          if (!await bobSvc.receiveSpaceAbuseReportDecision(
            owner,
            decisionJson,
          )) {
            throw StateError('abuse-report decision rejected');
          }
        },
      );
      bobSvc = GroupService(
        bobStorage,
        _FakeSigner(bob),
        sendSpaceAbuseReport: (peer, reportId, reportJson) async {
          expect(peer, owner);
          expect(reportId, isNotEmpty);
          if (!await ownerSvc.receiveSpaceAbuseReport(bob, reportJson)) {
            throw StateError('abuse report rejected');
          }
        },
      );
      final carolSvc = GroupService(carolStorage, _FakeSigner(carol));
      addTearDown(ownerSvc.dispose);
      addTearDown(bobSvc.dispose);
      addTearDown(carolSvc.dispose);

      final spaceId = await ownerSvc.createSpace(
        'Report lab',
        visibility: SpaceVisibility.public,
      );
      for (final member in [bob, carol]) {
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: member,
            role: GroupRole.member,
          ),
          isTrue,
        );
      }
      final ownerBundle = (await ownerSvc.load(spaceId))!;
      for (final pair in [(bobSvc, bob), (carolSvc, carol)]) {
        expect(
          await pair.$1.ingestSnapshot(
            ownerSvc.snapshotJson(ownerBundle, recipient: pair.$2),
          ),
          isTrue,
        );
      }
      final post = await carolSvc.publishSpacePost(
        spaceId,
        body: 'content requiring moderator review',
        broadcast: false,
      );
      expect(post, isNotNull);
      final carolBundle = (await carolSvc.load(spaceId))!;
      for (final pair in [(ownerSvc, owner), (bobSvc, bob)]) {
        expect(
          await pair.$1.ingestSnapshot(
            carolSvc.snapshotJson(carolBundle, recipient: pair.$2),
          ),
          isTrue,
        );
      }

      expect(
        await bobSvc.reportSpaceContent(
          spaceId,
          post!.postId,
          category: SpaceAbuseCategory.harassment,
          details: 'Please review this exact publication.',
        ),
        isTrue,
      );
      final incoming = await ownerSvc.incomingSpaceAbuseReports(
        spaceId: spaceId,
        pendingOnly: true,
      );
      expect(incoming, hasLength(1));
      expect(incoming.single.report.reporter, bob);
      expect(incoming.single.report.target.author, carol);
      expect(incoming.single.report.postId, post.postId);

      // A retry reuses the exact signed proposal and never creates another row.
      expect(
        await bobSvc.reportSpaceContent(
          spaceId,
          post.postId,
          category: SpaceAbuseCategory.spam,
          details: 'Changed text must not create a duplicate.',
        ),
        isTrue,
      );
      expect(
        await ownerSvc.incomingSpaceAbuseReports(spaceId: spaceId),
        hasLength(1),
      );

      expect(
        await ownerSvc.decideSpaceAbuseReport(
          incoming.single.report.reportId,
          outcome: SpaceAbuseReportOutcome.contentRemoved,
          reason: 'The report is confirmed.',
        ),
        isTrue,
      );
      expect(await ownerSvc.postsOf(spaceId), isEmpty);
      final audit = await ownerSvc.spaceModerationAudit(spaceId);
      expect(audit, hasLength(1));
      expect(
        audit.single.action.reference?.contentId,
        incoming.single.report.target.contentId,
      );
      final reviewed = (await ownerSvc.incomingSpaceAbuseReports(
        spaceId: spaceId,
      )).single;
      expect(reviewed.decision?.moderationActionId, audit.single.actionId);
      final outgoing = (await bobSvc.outgoingSpaceAbuseReports()).single;
      expect(
        outgoing.decision?.outcome,
        SpaceAbuseReportOutcome.contentRemoved,
      );
      expect(outgoing.decision?.moderationActionId, audit.single.actionId);
    },
  );

  test(
    'abuse inbox binds source, rejects poisoned rows and caps pending reports per reporter',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
      addTearDown(ownerSvc.dispose);

      final spaceId = await ownerSvc.createSpace(
        'Bounded reports',
        visibility: SpaceVisibility.public,
      );
      final posts = <SpacePost>[];
      for (var index = 0; index < 17; index++) {
        final post = await ownerSvc.publishSpacePost(
          spaceId,
          body: 'report target $index',
          broadcast: false,
        );
        expect(post, isNotNull);
        posts.add(post!);
      }

      SpaceAbuseReport signedReport(int index) {
        final post = posts[index];
        final reference = SpaceModerationReference(
          kind: SpaceModerationReferenceKind.spacePost,
          author: post.author,
          seq: post.seq,
        );
        final unsigned = SpaceAbuseReport(
          reportId: (index + 1).toRadixString(16).padLeft(64, '0'),
          spaceId: spaceId,
          post: reference,
          target: reference,
          reporter: bob,
          reviewer: owner,
          category: SpaceAbuseCategory.spam,
          details: '',
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          signature: Uint8List(0),
          authorPubKey: Uint8List(0),
        );
        return unsigned.withSignature(
          _fakeSovereignSignature(bob.bytes, unsigned.canonicalBytes()),
          bob.bytes,
        );
      }

      final reports = [
        for (var index = 0; index < posts.length; index++) signedReport(index),
      ];

      // Before anything fills the queue, so the ONLY reason to refuse is the
      // signature. `SpaceAbuseReport.fromJson` merely parses; the inbound
      // verify is the only thing binding a report to its reporter, and it was
      // uncovered — deleting it left the whole suite green. Overwrite the
      // signature rather than adding a field: an unknown key is refused by the
      // fail-closed rule below and would prove nothing.
      final forged = Map<String, dynamic>.from(reports.first.toJson())
        ..['signature'] = base64Encode(Uint8List(64));
      expect(
        await ownerSvc.receiveSpaceAbuseReport(bob, jsonEncode(forged)),
        isFalse,
        reason: 'a report whose signature does not verify must be refused',
      );
      expect(
        await ownerSvc.incomingSpaceAbuseReports(
          spaceId: spaceId,
          pendingOnly: true,
        ),
        isEmpty,
        reason: 'and it must not reach the moderator queue',
      );

      for (final report in reports.take(16)) {
        expect(
          await ownerSvc.receiveSpaceAbuseReport(
            bob,
            jsonEncode(report.toJson()),
          ),
          isTrue,
        );
      }
      expect(
        await ownerSvc.receiveSpaceAbuseReport(
          bob,
          jsonEncode(reports.first.toJson()),
        ),
        isTrue,
        reason:
            'an exact replay is idempotently admitted for lost ACK recovery',
      );
      expect(
        await ownerSvc.receiveSpaceAbuseReport(
          carol,
          jsonEncode(reports.last.toJson()),
        ),
        isFalse,
        reason: 'the authenticated transport source is the reporter authority',
      );
      final poisoned = Map<String, dynamic>.from(reports.last.toJson())
        ..['unexpected'] = true;
      expect(
        await ownerSvc.receiveSpaceAbuseReport(bob, jsonEncode(poisoned)),
        isFalse,
        reason: 'unknown signed-envelope fields are rejected fail-closed',
      );
      expect(
        await ownerSvc.receiveSpaceAbuseReport(
          bob,
          jsonEncode(reports.last.toJson()),
        ),
        isFalse,
        reason: 'one reporter may keep at most 16 unresolved reports',
      );
      expect(
        await ownerSvc.incomingSpaceAbuseReports(
          spaceId: spaceId,
          pendingOnly: true,
        ),
        hasLength(16),
      );
    },
  );

  test(
    'owner-signed Space lifecycle preserves history and starts a fresh content generation',
    () async {
      final (ownerSvc, member) = await setup();
      final bobSvc = member(bob);
      final groupId = await ownerSvc.createGroup('Friends remain a group chat');
      expect(await ownerSvc.setSpaceArchived(groupId, true), isFalse);
      expect(await ownerSvc.deleteSpace(groupId), isFalse);

      final spaceId = await ownerSvc.createSpace(
        'Archive lab',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final defaultChannel = (await ownerSvc.channelsOf(spaceId)).single;
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'before archive',
          channelId: defaultChannel.channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await ownerSvc.publishSpacePost(
          spaceId,
          body: 'publication before archive',
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await ownerSvc.react(spaceId, '${owner.hex}:0', '👍', broadcast: false),
        isTrue,
      );

      expect(await bobSvc.setSpaceArchived(spaceId, true), isFalse);
      expect(await ownerSvc.setSpaceArchived(spaceId, true), isTrue);
      var state = (await ownerSvc.stateOf(spaceId))!;
      expect(state.lifecycleState, SpaceLifecycleState.archived);
      expect(state.lifecycleTransitionHash, hasLength(64));
      expect(state.lifecycleTransition!.messageHeads, hasLength(1));
      expect(state.lifecycleTransition!.postHeads, hasLength(1));
      expect(state.lifecycleTransition!.reactionHeads, hasLength(1));
      expect(
        jsonEncode(state.lifecycleTransition!.toJson()),
        isNot(contains(defaultChannel.channelId.hex)),
        reason: 'the global lifecycle record exposes only hashed scopes',
      );
      expect(
        (await ownerSvc.messagesOf(spaceId)).map((message) => message.body),
        ['before archive'],
      );
      expect((await ownerSvc.postsOf(spaceId)).single.body, contains('before'));
      expect((await ownerSvc.reactionsOf(spaceId))['${owner.hex}:0']?['👍'], [
        owner,
      ]);

      expect(
        await ownerSvc.postMessage(
          spaceId,
          'blocked',
          channelId: defaultChannel.channelId,
          broadcast: false,
        ),
        isFalse,
      );
      expect(
        await ownerSvc.publishSpacePost(
          spaceId,
          body: 'blocked',
          broadcast: false,
        ),
        isNull,
      );
      expect(
        await ownerSvc.react(spaceId, '${owner.hex}:0', '👍', broadcast: false),
        isFalse,
      );
      expect(
        await ownerSvc.createChannel(
          spaceId,
          name: 'blocked',
          kind: SpaceChannelKind.text,
        ),
        isNull,
      );
      expect(await ownerSvc.setSpaceDescription(spaceId, 'blocked'), isFalse);

      expect(await bobSvc.setSpaceArchived(spaceId, false), isFalse);
      expect(await ownerSvc.setSpaceArchived(spaceId, false), isTrue);
      state = (await ownerSvc.stateOf(spaceId))!;
      expect(state.lifecycleState, SpaceLifecycleState.active);
      final generation = state.lifecycleTransitionHash;
      expect(generation, hasLength(64));
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'after restore',
          channelId: defaultChannel.channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await ownerSvc.publishSpacePost(
          spaceId,
          body: 'publication after restore',
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await ownerSvc.react(spaceId, '${owner.hex}:0', '❤️', broadcast: false),
        isTrue,
      );
      final bundle = (await ownerSvc.load(spaceId))!;
      expect(bundle.messages.last.lifecycleGeneration, generation);
      expect(bundle.posts.last.lifecycleGeneration, generation);
      expect(bundle.reactions.last.lifecycleGeneration, generation);
      expect((await ownerSvc.messagesOf(spaceId)).map((m) => m.body), [
        'before archive',
        'after restore',
      ]);
      expect((await ownerSvc.postsOf(spaceId)).map((post) => post.body), [
        'publication before archive',
        'publication after restore',
      ]);
    },
  );

  test(
    'recoverable Space deletion hides content, purges idempotently, and resists stale snapshots',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final recoveryStorage = FakeHvContainer().storage();
      await recoveryStorage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      final recoveryService = GroupService(recoveryStorage, _FakeSigner(owner));
      addTearDown(service.dispose);
      addTearDown(recoveryService.dispose);

      final spaceId = await service.createSpace(
        'Recoverable deletion',
        visibility: SpaceVisibility.public,
      );
      final channel = (await service.channelsOf(spaceId)).single;
      expect(
        await service.postMessage(
          spaceId,
          'retained until purge',
          channelId: channel.channelId,
          attachment: MediaObject(
            kind: 'file',
            contentId: 'd' * 64,
            name: 'retained.bin',
            size: 4,
          ),
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await service.publishSpacePost(
          spaceId,
          body: 'recoverable publication',
          media: [
            MediaObject(
              kind: 'file',
              contentId: 'd' * 64,
              name: 'retained.bin',
              size: 4,
            ),
          ],
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await recoveryService.ingestSnapshot(
          service.snapshotJson(
            (await service.load(spaceId))!,
            recipient: owner,
          ),
        ),
        isTrue,
      );
      String contentRequest(String nonce) => jsonEncode(
        _FakeSigner(owner)
            .signContentRequest(
              GroupContentRequest(
                groupId: spaceId,
                contentId: 'd' * 64,
                requester: owner,
                nonce: nonce,
                tsMs: DateTime.now().millisecondsSinceEpoch,
                signature: Uint8List(0),
              ),
            )
            .toJson(),
      );
      expect(
        await service.handleContentRequest(contentRequest('before-delete')),
        isTrue,
      );

      expect(
        await service.deleteSpace(
          spaceId,
          recoveryPeriod: const Duration(minutes: 1),
        ),
        isTrue,
      );
      final deletedBundle = (await service.load(spaceId))!;
      final deletedState = (await service.stateOf(spaceId))!;
      final deadline = deletedState.lifecycleTransition!.recoveryDeadlineMs!;
      expect(deletedState.lifecycleState, SpaceLifecycleState.deleted);
      expect(deletedBundle.control.last.version, 11);
      expect(deletedBundle.control.last.op, ControlOp.deleteSpace);
      expect(await service.channelsOf(spaceId), isEmpty);
      expect(await service.messagesOf(spaceId), isEmpty);
      expect(await service.postsOf(spaceId), isEmpty);
      expect(await service.reactionsOf(spaceId), isEmpty);
      expect(
        (await service.listSpaces()).single.lifecycleState,
        SpaceLifecycleState.deleted,
      );
      expect(
        await service.postMessage(
          spaceId,
          'blocked while deleted',
          channelId: channel.channelId,
          broadcast: false,
        ),
        isFalse,
      );
      expect(
        await service.handleContentRequest(contentRequest('after-delete')),
        isFalse,
        reason: 'the holder consumes the shared deleted-state denial',
      );

      final deletedSnapshot = service.snapshotJson(
        deletedBundle,
        recipient: owner,
      );
      final deletedWire = jsonDecode(deletedSnapshot) as Map<String, dynamic>;
      expect(deletedWire['g'], isEmpty);
      expect(deletedWire['p'], isEmpty);
      expect(deletedWire['r'], isEmpty);
      expect(deletedWire, isNot(contains('ke')));
      expect(await recoveryService.ingestSnapshot(deletedSnapshot), isTrue);
      expect(await recoveryService.restoreSpace(spaceId), isTrue);
      final restoredSnapshot = recoveryService.snapshotJson(
        (await recoveryService.load(spaceId))!,
        recipient: owner,
      );
      expect(
        (await recoveryService.stateOf(
          spaceId,
        ))!.lifecycleTransition!.changedAtMs,
        lessThanOrEqualTo(deadline),
      );

      final sweep = await service.purgeDeletedSpaces(nowMs: deadline);
      expect(sweep.scanned, 1);
      expect(sweep.purged, 1);
      expect(sweep.failed, 0);
      expect(await service.load(spaceId), isNull);
      expect(await service.listSpaces(), isEmpty);
      expect(await storage.loadFile('group:${spaceId.hex}'), isNull);
      final tombstone = await service.deletedSpaceTombstone(spaceId);
      expect(
        tombstone?.deleteTransitionHash,
        deletedState.lifecycleTransitionHash,
      );
      expect((await service.purgeDeletedSpaces(nowMs: deadline)).purged, 0);

      // The expired delete snapshot is acknowledged but cannot recreate its
      // heavy bundle or index entry.
      expect(await service.ingestSnapshot(deletedSnapshot), isTrue);
      expect(await service.load(spaceId), isNull);
      expect(await service.deletedSpaceTombstone(spaceId), isNotNull);

      // A complete restore signed before the deadline may arrive late. It
      // includes the exact purged delete row and therefore clears the compact
      // anti-resurrection marker without losing history.
      expect(await service.ingestSnapshot(restoredSnapshot), isTrue);
      expect(await service.deletedSpaceTombstone(spaceId), isNull);
      expect((await service.stateOf(spaceId))!.isActive, isTrue);
      expect(
        (await service.messagesOf(spaceId)).single.body,
        'retained until purge',
      );
      expect(
        (await service.postsOf(spaceId)).single.body,
        'recoverable publication',
      );
    },
  );

  test(
    'offline pre-archive suffix cannot rejoin after archive and restore arrive',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      await ownerStorage.open(password: 'pw', createIfMissing: true);
      final bobStorage = FakeHvContainer().storage();
      await bobStorage.open(password: 'pw', createIfMissing: true);
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob));

      final spaceId = await ownerSvc.createSpace(
        'Offline boundary',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final ownerChannel = (await ownerSvc.channelsOf(spaceId)).single;
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'archive boundary message',
          channelId: ownerChannel.channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final channel = (await bobSvc.channelsOf(spaceId)).single;
      expect(
        await bobSvc.postMessage(
          spaceId,
          'offline stale message',
          channelId: channel.channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        await bobSvc.publishSpacePost(
          spaceId,
          body: 'offline stale publication',
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await bobSvc.react(spaceId, '${owner.hex}:0', '⚠️', broadcast: false),
        isTrue,
      );

      expect(await ownerSvc.setSpaceArchived(spaceId, true), isTrue);
      expect(await ownerSvc.setSpaceArchived(spaceId, false), isTrue);
      expect(
        await ownerSvc.ingestSnapshot(
          bobSvc.snapshotJson((await bobSvc.load(spaceId))!, recipient: owner),
        ),
        isTrue,
      );
      final mergedLifecycle = (await ownerSvc.stateOf(spaceId))!;
      expect(mergedLifecycle.lifecycleTransitionHash, isNotNull);
      expect(mergedLifecycle.lifecycleTransitionHash, isNotEmpty);
      expect(mergedLifecycle.lifecycleTransition!.messageHeads, hasLength(1));
      expect(mergedLifecycle.lifecycleTransition!.reactionHeads, isEmpty);
      final mergedRows = (await ownerSvc.load(spaceId))!.messages;
      expect(mergedRows.map((message) => message.body), [
        'archive boundary message',
      ]);
      expect(
        (await ownerSvc.messagesOf(spaceId)).map((message) => message.body),
        ['archive boundary message'],
      );
      expect(await ownerSvc.postsOf(spaceId), isEmpty);
      expect(await ownerSvc.reactionsOf(spaceId), isEmpty);
      final retained = (await ownerSvc.load(spaceId))!;
      expect(retained.messages, hasLength(1));
      expect(retained.posts, isEmpty);
      expect(retained.reactions, isEmpty);

      final restored = (await ownerSvc.stateOf(spaceId))!;
      expect(
        await ownerSvc.postMessage(
          spaceId,
          'fresh message',
          channelId: channel.channelId,
          broadcast: false,
        ),
        isTrue,
      );
      expect(
        (await ownerSvc.load(spaceId))!.messages.last.lifecycleGeneration,
        restored.lifecycleTransitionHash,
      );
    },
  );

  test(
    'global content GC preserves cross-domain refs, waits 24h, then purges payload+manifest',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      addTearDown(service.dispose);
      addTearDown(storage.close);
      final contentId = 'c' * 64;
      await storage.storeFile(
        contentId,
        Uint8List.fromList([1, 2, 3, 4]),
        name: 'shared.bin',
      );
      await storage.storeFile(
        'mf:$contentId',
        Uint8List.fromList(utf8.encode('{"cid":"$contentId"}')),
        name: 'manifest',
      );

      const conversationId = 'personal-chat';
      await storage.appendMessage(
        Message(
          id: 'shared-message',
          conversationId: conversationId,
          direction: MessageDirection.outgoing,
          body: 'shared attachment',
          timestamp: DateTime.fromMillisecondsSinceEpoch(10),
          fileId: contentId,
          fileName: 'shared.bin',
        ),
      );
      final spaceId = await service.createSpace(
        'Shared reachability',
        visibility: SpaceVisibility.public,
      );
      final post = await service.publishSpacePost(
        spaceId,
        body: 'same immutable bytes in a Space',
        media: [
          MediaObject(
            contentId: contentId,
            kind: 'file',
            name: 'shared.bin',
            size: 4,
          ),
        ],
        broadcast: false,
      );
      expect(post, isNotNull);

      await storage.deleteMessage(conversationId, 'shared-message');
      expect(
        await storage.hasFile(contentId),
        isTrue,
        reason: 'one domain cannot erase a globally shared hash-CID',
      );
      final whileSpaceOwns = await service.sweepSharedContentGarbage(
        nowMs: 1000,
        gracePeriod: Duration.zero,
      );
      expect(whileSpaceOwns.complete, isTrue);
      expect(whileSpaceOwns.referenced, greaterThanOrEqualTo(1));
      expect(whileSpaceOwns.purged, 0);

      expect(
        await service.deleteSpacePost(spaceId, post!.postId, broadcast: false),
        isTrue,
      );
      final first = await service.sweepSharedContentGarbage(nowMs: 2000);
      expect(first.marked, 1);
      expect(first.purged, 0);
      expect(await storage.hasFile(contentId), isTrue);

      final almostDue = await service.sweepSharedContentGarbage(
        nowMs: 2000 + kSharedContentGcGracePeriod.inMilliseconds - 1,
      );
      expect(almostDue.purged, 0);
      expect(await storage.hasFile(contentId), isTrue);

      final due = await service.sweepSharedContentGarbage(
        nowMs: 2000 + kSharedContentGcGracePeriod.inMilliseconds,
      );
      expect(due.complete, isTrue);
      expect(due.purged, 1);
      expect(await storage.hasFile(contentId), isFalse);
      expect(await storage.hasFile('mf:$contentId'), isFalse);
    },
  );

  test(
    'global content GC aborts on an unreadable durable cloud root',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      addTearDown(service.dispose);
      addTearDown(storage.close);
      final contentId = 'e' * 64;
      await storage.storeFile(
        contentId,
        Uint8List.fromList([9, 8, 7]),
        name: 'must-survive.bin',
      );
      await storage.putSetting('cloud.index.v1.active', 'a');
      await storage.storeFile(
        'cloud.index.v1.a',
        Uint8List.fromList(utf8.encode('{not-json')),
        name: 'corrupt-cloud-index',
      );

      final sweep = await service.sweepSharedContentGarbage(
        nowMs: 1000,
        gracePeriod: Duration.zero,
      );
      expect(sweep.complete, isFalse);
      expect(sweep.failed, 1);
      expect(sweep.purged, 0);
      expect(await storage.hasFile(contentId), isTrue);
    },
  );

  test(
    'global content GC aborts when the durable group index is malformed',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      addTearDown(service.dispose);
      addTearDown(storage.close);
      final contentId = '9' * 64;
      await storage.storeFile(
        contentId,
        Uint8List.fromList([1, 9, 1]),
        name: 'must-survive-group-index-corruption.bin',
      );
      await storage.putSetting('groups.index', '{not-json');

      final sweep = await service.sweepSharedContentGarbage(
        nowMs: 1000,
        gracePeriod: Duration.zero,
      );
      expect(sweep.complete, isFalse);
      expect(sweep.failed, 1);
      expect(sweep.purged, 0);
      expect(await storage.hasFile(contentId), isTrue);
    },
  );

  test(
    'corrupt active GC marks restart grace instead of reviving stale fallback',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      addTearDown(service.dispose);
      addTearDown(storage.close);
      final contentId = 'd' * 64;
      await storage.storeFile(
        contentId,
        Uint8List.fromList([3, 2, 1]),
        name: 'quarantined.bin',
      );

      expect((await service.sweepSharedContentGarbage(nowMs: 1000)).marked, 1);
      expect(await storage.getSetting('content.gc.marks.v1.active'), 'a');
      // An unchanged sweep must not rotate/write the quarantine generation.
      expect((await service.sweepSharedContentGarbage(nowMs: 1500)).purged, 0);
      expect(await storage.getSetting('content.gc.marks.v1.active'), 'a');
      await storage.appendMessage(
        Message(
          id: 'temporary-reference',
          conversationId: 'personal-chat',
          direction: MessageDirection.outgoing,
          body: 'temporarily reachable',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1600),
          fileId: contentId,
        ),
      );
      // The active generation now records that the stale mark was cleared.
      expect(
        (await service.sweepSharedContentGarbage(nowMs: 2000)).unreachable,
        0,
      );
      await storage.deleteMessage('personal-chat', 'temporary-reference');
      expect(await storage.getSetting('content.gc.marks.v1.active'), 'b');
      await storage.storeFile(
        'content.gc.marks.v1.b',
        Uint8List.fromList(utf8.encode('{corrupt')),
        name: 'corrupt-active-gc-marks',
      );

      final oldMarkWouldBeDue =
          1000 + kSharedContentGcGracePeriod.inMilliseconds;
      final restarted = await service.sweepSharedContentGarbage(
        nowMs: oldMarkWouldBeDue,
      );
      expect(restarted.complete, isTrue);
      expect(restarted.marked, 1);
      expect(restarted.purged, 0);
      expect(await storage.hasFile(contentId), isTrue);

      final dueAfterRestart = await service.sweepSharedContentGarbage(
        nowMs: oldMarkWouldBeDue + kSharedContentGcGracePeriod.inMilliseconds,
      );
      expect(dueAfterRestart.purged, 1);
      expect(await storage.hasFile(contentId), isFalse);
    },
  );

  test(
    'recoverable Space deletion retains media until the bundle purge commits',
    () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      addTearDown(service.dispose);
      addTearDown(storage.close);
      final contentId = 'f' * 64;
      await storage.storeFile(
        contentId,
        Uint8List.fromList([4, 5, 6]),
        name: 'recoverable.bin',
      );
      await storage.storeFile(
        'mf:$contentId',
        Uint8List.fromList(utf8.encode('{"cid":"$contentId"}')),
        name: 'manifest',
      );
      final spaceId = await service.createSpace(
        'Recoverable media',
        visibility: SpaceVisibility.public,
      );
      expect(
        await service.publishSpacePost(
          spaceId,
          body: 'must survive recovery',
          media: [
            MediaObject(
              contentId: contentId,
              kind: 'file',
              name: 'recoverable.bin',
              size: 3,
            ),
          ],
          broadcast: false,
        ),
        isNotNull,
      );
      expect(
        await service.deleteSpace(
          spaceId,
          recoveryPeriod: const Duration(milliseconds: 1),
        ),
        isTrue,
      );
      final deadline = (await service.stateOf(
        spaceId,
      ))!.lifecycleTransition!.recoveryDeadlineMs!;

      final beforeBundlePurge = await service.sweepSharedContentGarbage(
        nowMs: deadline,
        gracePeriod: Duration.zero,
      );
      expect(beforeBundlePurge.purged, 0);
      expect(await storage.hasFile(contentId), isTrue);

      expect((await service.purgeDeletedSpaces(nowMs: deadline)).purged, 1);
      final afterBundlePurge = await service.sweepSharedContentGarbage(
        nowMs: deadline + 1,
        gracePeriod: Duration.zero,
      );
      expect(afterBundlePurge.purged, 1);
      expect(await storage.hasFile(contentId), isFalse);
      expect(await storage.hasFile('mf:$contentId'), isFalse);
    },
  );

  test(
    'initial access snapshots are Space-only, optimistic and owner-authored',
    () async {
      final (ownerService, memberService) = await setup();
      final spaceId = await ownerService.createSpace('Access lab');
      final groupId = await ownerService.createGroup('Not a Space');
      final roleId = ownerService.newSpaceAccessObjectId();
      final role = SpaceRoleDefinition(
        roleId: roleId,
        name: 'Publisher',
        permissions: const {
          SpacePermission.publishPosts,
          SpacePermission.managePosts,
        },
      );

      final first = await ownerService.replaceSpaceAccessPolicy(
        spaceId,
        expectedRevision: 0,
        roles: [role],
        groups: const <SpaceMemberGroup>[],
        directAssignments: const <SpaceMemberRoleAssignment>[],
      );
      expect(first?.revision, 1);
      expect(
        await ownerService.replaceSpaceAccessPolicy(
          spaceId,
          expectedRevision: 0,
          roles: [role],
          groups: const <SpaceMemberGroup>[],
          directAssignments: const <SpaceMemberRoleAssignment>[],
        ),
        isNull,
        reason: 'a stale editor must not overwrite a newer signed snapshot',
      );
      expect(
        await ownerService.replaceSpaceAccessPolicy(
          groupId,
          expectedRevision: 0,
          roles: [role],
          groups: const <SpaceMemberGroup>[],
          directAssignments: const <SpaceMemberRoleAssignment>[],
        ),
        isNull,
      );

      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.admin,
        ),
        isTrue,
      );
      final adminService = memberService(bob);
      expect(
        await adminService.replaceSpaceAccessPolicy(
          spaceId,
          expectedRevision: 1,
          roles: [role],
          groups: const <SpaceMemberGroup>[],
          directAssignments: [
            SpaceMemberRoleAssignment(member: bob, roleIds: [roleId]),
          ],
        ),
        isNull,
      );

      final state = (await ownerService.stateOf(spaceId))!;
      final bundle = (await ownerService.load(spaceId))!;
      final accessEntry = bundle.control.lastWhere(
        (entry) => entry.version == 17,
      );
      expect(state.accessPolicyHistory, hasLength(1));
      expect(state.accessPolicy?.policyHash, first?.policyHash);
      expect(accessEntry.author, owner);
      expect(accessEntry.accessPolicy?.policyHash, first?.policyHash);
      expect(
        ControlEntry.fromJson(accessEntry.toJson())?.accessPolicy?.policyHash,
        first?.policyHash,
      );
    },
  );

  test(
    'manageRoles delegate signs V20 below their ceiling without self escalation',
    () async {
      final (ownerService, memberService) = await setup();
      final spaceId = await ownerService.createSpace('Delegated access lab');
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: carol,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final managerRoleId = ownerService.newSpaceAccessObjectId();
      final publisherRoleId = ownerService.newSpaceAccessObjectId();
      final storageRoleId = ownerService.newSpaceAccessObjectId();
      final managerRole = SpaceRoleDefinition(
        roleId: managerRoleId,
        name: 'Role manager',
        permissions: const {
          SpacePermission.manageRoles,
          SpacePermission.managePosts,
        },
      );
      final publisherRole = SpaceRoleDefinition(
        roleId: publisherRoleId,
        name: 'Publisher',
        permissions: const {SpacePermission.publishPosts},
      );
      expect(
        await ownerService.replaceSpaceAccessPolicy(
          spaceId,
          expectedRevision: 0,
          roles: [managerRole, publisherRole],
          groups: const <SpaceMemberGroup>[],
          directAssignments: [
            SpaceMemberRoleAssignment(member: bob, roleIds: [managerRoleId]),
          ],
        ),
        isNotNull,
      );

      final bobService = memberService(bob);
      final lower = await bobService.replaceSpaceAccessPolicy(
        spaceId,
        expectedRevision: 1,
        roles: [managerRole, publisherRole],
        groups: const <SpaceMemberGroup>[],
        directAssignments: [
          SpaceMemberRoleAssignment(member: bob, roleIds: [managerRoleId]),
          SpaceMemberRoleAssignment(member: carol, roleIds: [publisherRoleId]),
        ],
      );
      expect(lower?.revision, 2);
      final delegatedEntry = (await ownerService.load(
        spaceId,
      ))!.control.lastWhere((entry) => entry.op == ControlOp.setPolicy);
      expect(delegatedEntry.version, 20);
      expect(delegatedEntry.author, bob);

      expect(
        await bobService.replaceSpaceAccessPolicy(
          spaceId,
          expectedRevision: 2,
          roles: [managerRole, publisherRole],
          groups: const <SpaceMemberGroup>[],
          directAssignments: [
            SpaceMemberRoleAssignment(
              member: bob,
              roleIds: [managerRoleId, publisherRoleId],
            ),
            SpaceMemberRoleAssignment(
              member: carol,
              roleIds: [publisherRoleId],
            ),
          ],
        ),
        isNull,
        reason: 'the current policy may never bootstrap the author',
      );
      expect(
        await bobService.replaceSpaceAccessPolicy(
          spaceId,
          expectedRevision: 2,
          roles: [managerRole, publisherRole],
          groups: const <SpaceMemberGroup>[],
          directAssignments: [
            SpaceMemberRoleAssignment(member: bob, roleIds: [managerRoleId]),
            SpaceMemberRoleAssignment(member: carol, roleIds: [managerRoleId]),
          ],
        ),
        isNull,
        reason: 'manageRoles is the equal-level non-delegable boundary',
      );
      final storageRole = SpaceRoleDefinition(
        roleId: storageRoleId,
        name: 'Storage manager',
        permissions: const {SpacePermission.manageStorage},
      );
      expect(
        await bobService.replaceSpaceAccessPolicy(
          spaceId,
          expectedRevision: 2,
          roles: [managerRole, publisherRole, storageRole],
          groups: const <SpaceMemberGroup>[],
          directAssignments: [
            SpaceMemberRoleAssignment(member: bob, roleIds: [managerRoleId]),
            SpaceMemberRoleAssignment(
              member: carol,
              roleIds: [publisherRoleId],
            ),
          ],
        ),
        isNull,
        reason: 'a delegate cannot mint a capability they do not hold',
      );
      expect((await ownerService.stateOf(spaceId))!.accessPolicy?.revision, 2);
    },
  );

  test('manageRoles delegate cannot widen a category-scoped ceiling', () async {
    final (ownerService, memberService) = await setup();
    final spaceId = await ownerService.createSpace('Scoped role ceiling');
    final insideCategory = await ownerService.createChannel(
      spaceId,
      name: 'Inside',
      kind: SpaceChannelKind.category,
    );
    final outsideCategory = await ownerService.createChannel(
      spaceId,
      name: 'Outside',
      kind: SpaceChannelKind.category,
    );
    expect(insideCategory, isNotNull);
    expect(outsideCategory, isNotNull);
    expect(
      await ownerService.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: bob,
        role: GroupRole.member,
      ),
      isTrue,
    );
    expect(
      await ownerService.addControlOp(
        spaceId,
        ControlOp.addMember,
        target: carol,
        role: GroupRole.member,
      ),
      isTrue,
    );
    final managerRoleId = ownerService.newSpaceAccessObjectId();
    final insideRoleId = ownerService.newSpaceAccessObjectId();
    final outsideRoleId = ownerService.newSpaceAccessObjectId();
    final managerRole = SpaceRoleDefinition(
      roleId: managerRoleId,
      name: 'Inside role manager',
      grants: [
        const SpacePermissionGrant(
          permission: SpacePermission.manageRoles,
          scope: SpacePermissionScope(kind: SpacePermissionScopeKind.roles),
        ),
        SpacePermissionGrant(
          permission: SpacePermission.manageChannels,
          scope: SpacePermissionScope(
            kind: SpacePermissionScopeKind.category,
            targetId: insideCategory,
          ),
        ),
      ],
    );
    expect(
      await ownerService.replaceSpaceAccessPolicy(
        spaceId,
        expectedRevision: 0,
        roles: [managerRole],
        groups: const <SpaceMemberGroup>[],
        directAssignments: [
          SpaceMemberRoleAssignment(member: bob, roleIds: [managerRoleId]),
        ],
      ),
      isNotNull,
    );
    final insideRole = SpaceRoleDefinition(
      roleId: insideRoleId,
      name: 'Inside channel manager',
      grants: [
        SpacePermissionGrant(
          permission: SpacePermission.manageChannels,
          scope: SpacePermissionScope(
            kind: SpacePermissionScopeKind.category,
            targetId: insideCategory,
          ),
        ),
      ],
    );
    final bobService = memberService(bob);
    expect(
      await bobService.replaceSpaceAccessPolicy(
        spaceId,
        expectedRevision: 1,
        roles: [managerRole, insideRole],
        groups: const <SpaceMemberGroup>[],
        directAssignments: [
          SpaceMemberRoleAssignment(member: bob, roleIds: [managerRoleId]),
          SpaceMemberRoleAssignment(member: carol, roleIds: [insideRoleId]),
        ],
      ),
      isNotNull,
    );

    final outsideRole = SpaceRoleDefinition(
      roleId: outsideRoleId,
      name: 'Outside channel manager',
      grants: [
        SpacePermissionGrant(
          permission: SpacePermission.manageChannels,
          scope: SpacePermissionScope(
            kind: SpacePermissionScopeKind.category,
            targetId: outsideCategory,
          ),
        ),
      ],
    );
    expect(
      await bobService.replaceSpaceAccessPolicy(
        spaceId,
        expectedRevision: 2,
        roles: [managerRole, insideRole, outsideRole],
        groups: const <SpaceMemberGroup>[],
        directAssignments: [
          SpaceMemberRoleAssignment(member: bob, roleIds: [managerRoleId]),
          SpaceMemberRoleAssignment(member: carol, roleIds: [insideRoleId]),
        ],
      ),
      isNull,
    );
    expect((await ownerService.stateOf(spaceId))!.accessPolicy?.revision, 2);
  });

  test(
    'scoped V18 role manages one category and rejects its sibling',
    () async {
      final (ownerService, memberService) = await setup();
      final spaceId = await ownerService.createSpace('Scoped access lab');
      final categoryId = await ownerService.createChannel(
        spaceId,
        name: 'Operations',
        kind: SpaceChannelKind.category,
        history: SpaceChannelHistory.full,
      );
      expect(categoryId, isNotNull);
      final insideId = await ownerService.createChannel(
        spaceId,
        name: 'Inside',
        kind: SpaceChannelKind.text,
        categoryId: categoryId,
        history: SpaceChannelHistory.full,
      );
      expect(insideId, isNotNull);
      final outside = (await ownerService.channelsOf(spaceId)).firstWhere(
        (channel) =>
            channel.categoryId == null && channel.kind == SpaceChannelKind.text,
      );
      expect(
        await ownerService.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      final roleId = ownerService.newSpaceAccessObjectId();
      final scopedRole = SpaceRoleDefinition(
        roleId: roleId,
        name: 'Operations steward',
        grants: [
          SpacePermissionGrant(
            permission: SpacePermission.manageChannels,
            scope: SpacePermissionScope(
              kind: SpacePermissionScopeKind.category,
              targetId: categoryId,
            ),
          ),
        ],
      );
      final policy = await ownerService.replaceSpaceAccessPolicy(
        spaceId,
        expectedRevision: 0,
        roles: [scopedRole],
        groups: const <SpaceMemberGroup>[],
        directAssignments: [
          SpaceMemberRoleAssignment(member: bob, roleIds: [roleId]),
        ],
      );
      expect(policy?.schemaVersion, 2);

      final bobService = memberService(bob);
      final inside = (await bobService.channelsOf(
        spaceId,
      )).singleWhere((channel) => channel.channelId == insideId);
      expect(
        await bobService.updateChannel(
          spaceId,
          inside.copyWith(name: 'Inside updated'),
        ),
        isTrue,
      );
      expect(
        await bobService.updateChannel(
          spaceId,
          outside.copyWith(name: 'Outside forged'),
        ),
        isFalse,
      );
      expect(
        await bobService.updateChannel(
          spaceId,
          outside.copyWith(categoryId: categoryId),
        ),
        isFalse,
        reason: 'an out-of-scope root channel cannot be pulled into the grant',
      );
      expect(
        await bobService.updateChannel(
          spaceId,
          inside.copyWith(clearCategory: true),
        ),
        isFalse,
        reason: 'an in-scope channel cannot be moved outside the grant',
      );

      final state = (await ownerService.stateOf(spaceId))!;
      expect(state.channels[insideId!.hex]?.name, 'Inside updated');
      expect(state.channels[outside.channelId.hex]?.name, outside.name);
      final accessEntry = (await ownerService.load(
        spaceId,
      ))!.control.lastWhere((entry) => entry.op == ControlOp.setPolicy);
      expect(accessEntry.version, 18);
      expect(accessEntry.accessPolicy?.schemaVersion, 2);
      expect(
        ControlEntry.fromJson(accessEntry.toJson())?.canonicalBytes(),
        accessEntry.canonicalBytes(),
      );

      final deniedRole = SpaceRoleDefinition(
        roleId: roleId,
        name: 'All except Operations',
        grants: const [
          SpacePermissionGrant(
            permission: SpacePermission.manageChannels,
            scope: SpacePermissionScope.space(),
          ),
        ],
        denials: [
          SpacePermissionDenial(
            permission: SpacePermission.manageChannels,
            scope: SpacePermissionScope(
              kind: SpacePermissionScopeKind.category,
              targetId: categoryId,
            ),
          ),
        ],
      );
      final deniedPolicy = await ownerService.replaceSpaceAccessPolicy(
        spaceId,
        expectedRevision: 1,
        roles: [deniedRole],
        groups: const <SpaceMemberGroup>[],
        directAssignments: [
          SpaceMemberRoleAssignment(member: bob, roleIds: [roleId]),
          SpaceMemberRoleAssignment(member: owner, roleIds: [roleId]),
        ],
      );
      expect(deniedPolicy?.schemaVersion, 3);
      expect(
        (await ownerService.load(spaceId))!.control
            .lastWhere((entry) => entry.op == ControlOp.setPolicy)
            .version,
        19,
      );
      expect(
        await bobService.updateChannel(
          spaceId,
          outside.copyWith(name: 'Outside allowed'),
        ),
        isTrue,
      );
      expect(
        await bobService.updateChannel(
          spaceId,
          inside.copyWith(name: 'Inside denied'),
        ),
        isFalse,
      );
      expect(
        await ownerService.updateChannel(
          spaceId,
          inside.copyWith(name: 'Owner protected'),
        ),
        isTrue,
      );

      final monotonic = await ownerService.replaceSpaceAccessPolicy(
        spaceId,
        expectedRevision: 2,
        roles: [scopedRole],
        groups: const <SpaceMemberGroup>[],
        directAssignments: [
          SpaceMemberRoleAssignment(member: bob, roleIds: [roleId]),
        ],
      );
      expect(
        monotonic?.schemaVersion,
        3,
        reason: 'signed policy schemas never downgrade after V19 is observed',
      );
    },
  );

  test(
    'Space avatar/cover edits are signed, replicated and permission-gated',
    () async {
      final ownerStorage = FakeHvContainer().storage();
      final bobStorage = FakeHvContainer().storage();
      for (final storage in [ownerStorage, bobStorage]) {
        await storage.open(password: 'pw', createIfMissing: true);
      }
      final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
      final bobSvc = GroupService(bobStorage, _FakeSigner(bob));
      addTearDown(ownerSvc.dispose);
      addTearDown(bobSvc.dispose);

      final avatar = 'a' * 64;
      final cover = 'b' * 64;
      final spaceId = await ownerSvc.createSpace(
        'Avatar space',
        visibility: SpaceVisibility.public,
      );
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: bob,
          role: GroupRole.member,
        ),
        isTrue,
      );
      expect(
        await ownerSvc.setSpaceProfileMedia(
          spaceId,
          avatarContentId: avatar,
          coverContentId: cover,
        ),
        isTrue,
      );
      final ownerState = (await ownerSvc.stateOf(spaceId))!;
      expect(ownerState.avatarContentId, avatar);
      expect(ownerState.coverContentId, cover);

      expect(
        await bobSvc.ingestSnapshot(
          ownerSvc.snapshotJson(
            (await ownerSvc.load(spaceId))!,
            recipient: bob,
          ),
        ),
        isTrue,
      );
      final bobState = (await bobSvc.stateOf(spaceId))!;
      expect(
        bobState.avatarContentId,
        avatar,
        reason: 'the signed profile row replicates like any control state',
      );
      expect(bobState.coverContentId, cover);

      expect(
        await bobSvc.setSpaceProfileMedia(spaceId, avatarContentId: 'c' * 64),
        isFalse,
        reason: 'a plain member cannot re-point the community profile',
      );
      expect(
        await ownerSvc.setSpaceProfileMedia(
          spaceId,
          avatarContentId: 'not-a-content-id',
        ),
        isFalse,
      );
      expect(await ownerSvc.setSpaceProfileMedia(spaceId), isTrue);
      expect((await ownerSvc.stateOf(spaceId))!.avatarContentId, isNull);

      final seeded = await ownerSvc.createSpace(
        'Genesis avatar',
        avatarContentId: avatar,
      );
      expect(
        (await ownerSvc.stateOf(seeded))!.avatarContentId,
        avatar,
        reason: 'stateOf seeds the fold from the genesis manifest',
      );
    },
  );

  test('permanentBan cuts the banned device off from every holder and from '
      'rotated epoch material', () async {
    final ownerStorage = FakeHvContainer().storage();
    final bobStorage = FakeHvContainer().storage();
    final carolStorage = FakeHvContainer().storage();
    for (final storage in [ownerStorage, bobStorage, carolStorage]) {
      await storage.open(password: 'pw', createIfMissing: true);
    }
    final bobGrants = <(NodeId, String)>[];
    final ownerGrants = <(NodeId, String)>[];
    final ownerSvc = GroupService(
      ownerStorage,
      _FakeSigner(owner),
      grantContentServe: (peer, contentId) =>
          ownerGrants.add((peer, contentId)),
      contentGrantDelay: Duration.zero,
    );
    final bobSvc = GroupService(
      bobStorage,
      _FakeSigner(bob),
      grantContentServe: (peer, contentId) => bobGrants.add((peer, contentId)),
      contentGrantDelay: Duration.zero,
    );
    final carolSvc = GroupService(carolStorage, _FakeSigner(carol));
    addTearDown(ownerSvc.dispose);
    addTearDown(bobSvc.dispose);
    addTearDown(carolSvc.dispose);

    final cid = sha256.convert(const [4, 2, 4]).toString();
    final bytes = Uint8List.fromList(const [4, 2, 4]);
    final spaceId = await ownerSvc.createSpace(
      'Ban cut-off',
      visibility: SpaceVisibility.public,
    );
    for (final member in [bob, carol]) {
      expect(
        await ownerSvc.addControlOp(
          spaceId,
          ControlOp.addMember,
          target: member,
          role: GroupRole.member,
        ),
        isTrue,
      );
    }
    expect(
      await ownerSvc.publishSpacePost(
        spaceId,
        body: 'replicated media',
        media: [MediaObject(contentId: cid, kind: 'file', size: bytes.length)],
        broadcast: false,
      ),
      isNotNull,
    );
    await ownerStorage.storeFile(cid, bytes, name: 'owner');
    await bobStorage.storeFile(cid, bytes, name: 'replica');
    final beforeBan = (await ownerSvc.load(spaceId))!;
    expect(
      await bobSvc.ingestSnapshot(
        ownerSvc.snapshotJson(beforeBan, recipient: bob),
      ),
      isTrue,
    );
    expect(
      await carolSvc.ingestSnapshot(
        ownerSvc.snapshotJson(beforeBan, recipient: carol),
      ),
      isTrue,
    );
    final epochBeforeBan = (await ownerSvc.stateOf(spaceId))!.epoch;

    // The signed moderation row removes membership and rotates the epoch
    // in one fold step.
    final banId = await ownerSvc.moderateSpace(
      spaceId,
      kind: SpaceModerationKind.permanentBan,
      target: carol,
      scope: SpaceModerationScope.space,
      reason: 'adversarial holder cut-off test',
    );
    expect(banId, isNotNull);
    final stateAfterBan = (await ownerSvc.stateOf(spaceId))!;
    expect(stateAfterBan.isMember(carol), isFalse);
    expect(stateAfterBan.epoch, greaterThan(epochBeforeBan));

    // Every holder that has folded the ban refuses the banned device with
    // its OWN fold — the owner being offline is irrelevant.
    expect(
      await bobSvc.ingestSnapshot(
        ownerSvc.snapshotJson((await ownerSvc.load(spaceId))!, recipient: bob),
      ),
      isTrue,
    );
    final staleCarolRequest = _FakeSigner(carol).signContentRequest(
      GroupContentRequest(
        groupId: spaceId,
        contentId: cid,
        requester: carol,
        nonce: 'banned-carol-stale-request',
        tsMs: DateTime.now().millisecondsSinceEpoch,
        signature: Uint8List(0),
      ),
    );
    expect(
      await bobSvc.handleContentRequest(jsonEncode(staleCarolRequest.toJson())),
      isFalse,
      reason: 'a banned member must not be served by a secondary holder',
    );
    expect(bobGrants, isEmpty);
    expect(
      (await bobSvc.spaceObservabilitySnapshot())
          .counters['revokedDeliveryPrevented.reason.notMember'],
      1,
    );
    expect(
      await ownerSvc.handleContentRequest(
        jsonEncode(
          _FakeSigner(carol)
              .signContentRequest(
                GroupContentRequest(
                  groupId: spaceId,
                  contentId: cid,
                  requester: carol,
                  nonce: 'banned-carol-to-owner',
                  tsMs: DateTime.now().millisecondsSinceEpoch,
                  signature: Uint8List(0),
                ),
              )
              .toJson(),
        ),
      ),
      isFalse,
    );
    expect(ownerGrants, isEmpty);

    // Post-ban rotated epoch material never reaches the banned device: the
    // recipient-scoped snapshot carries no envelope for any epoch minted at
    // or after the ban, so already-leaked ciphertext stays undecryptable.
    final ownerAfterBan = (await ownerSvc.load(spaceId))!;
    final carolEnvelopeEpochs = ownerAfterBan.epochEnvelopes
        .where((envelope) => envelope.recipient == carol)
        .map((envelope) => envelope.epoch)
        .toSet();
    expect(
      carolEnvelopeEpochs.where((epoch) => epoch >= stateAfterBan.epoch),
      isEmpty,
      reason: 'no post-ban epoch envelope may be minted for the banned id',
    );
    final servedToCarol =
        jsonDecode(ownerSvc.snapshotJson(ownerAfterBan, recipient: carol))
            as Map<String, dynamic>;
    expect(
      (servedToCarol['ke'] as List? ?? const []),
      isEmpty,
      reason: 'a non-member snapshot must not carry epoch envelopes',
    );

    // Even force-feeding the full post-ban log to the banned device gives
    // it nothing readable: its own fold removes its membership.
    expect(
      await carolSvc.ingestSnapshot(
        ownerSvc.snapshotJson(ownerAfterBan, recipient: carol),
      ),
      isTrue,
    );
    expect(await carolSvc.messagesOf(spaceId), isEmpty);
    expect(
      (await carolSvc.stateOf(spaceId))!.isMember(carol),
      isFalse,
      reason: 'the banned device fold must converge to non-membership',
    );
  });

  group('group-kind maintenance hint', () {
    const dayMs = 24 * 60 * 60 * 1000;
    const graceMs = 7 * dayMs;
    final baseMs = DateTime.now().millisecondsSinceEpoch;

    String hintKey(NodeId id) => 'group.kind.v1.${id.hex}';

    test('save keeps the kind hint fresh across the lifecycle', () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      var wall = baseMs;
      service.debugWallClockMs = () => wall;

      final groupId = await service.createGroup('Plain group');
      expect(await storage.getSetting(hintKey(groupId)), 'g');

      final spaceId = await service.createSpace('Hinted');
      expect(await storage.getSetting(hintKey(spaceId)), 's');

      expect(
        await service.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            retentionMs: dayMs,
          ),
        ),
        isTrue,
      );
      expect(
        await storage.getSetting(hintKey(spaceId)),
        'sb',
        reason: 'a setRetention control row upgrades the hint',
      );

      expect(await service.convertGroupToSpace(groupId), isTrue);
      expect(
        await storage.getSetting(hintKey(groupId)),
        's',
        reason: 'conversion re-derives the hint from the saved bundle',
      );
    });

    test(
      'a pre-hint store still enforces retention and backfills the hint',
      () async {
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'pw', createIfMissing: true);
        final service = GroupService(storage, _FakeSigner(owner));
        var wall = baseMs;
        service.debugWallClockMs = () => wall;
        final spaceId = await service.createSpace('Legacy store');
        expect(await service.postMessage(spaceId, 'expired row'), isTrue);
        expect(
          await service.setSpaceRetentionPolicy(
            spaceId,
            SpaceRetentionPolicy(
              mode: SpaceRetentionMode.deleteAfter,
              retentionMs: dayMs,
            ),
          ),
          isTrue,
        );
        // Simulate a store written before the hint existed.
        await storage.putSetting(hintKey(spaceId), '');

        // A fresh service (empty hint cache) must fail OPEN: load the
        // bundle, enforce, and backfill the hint for the next pass.
        final restarted = GroupService(storage, _FakeSigner(owner));
        restarted.debugWallClockMs = () => wall;
        final sweepAt = baseMs + dayMs + graceMs + 60 * 60 * 1000;
        wall = sweepAt;
        final sweep = await restarted.sweepSpaceRetention(nowMs: sweepAt);
        expect(sweep.complete, isTrue);
        expect(sweep.messagesDeleted, 1);
        expect(await storage.getSetting(hintKey(spaceId)), 'sb');
      },
    );

    test(
      'the sweep trusts the hint and skips non-candidates without loading',
      () async {
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'pw', createIfMissing: true);
        final service = GroupService(storage, _FakeSigner(owner));
        var wall = baseMs;
        service.debugWallClockMs = () => wall;
        final spaceId = await service.createSpace('Skipped');
        expect(await service.postMessage(spaceId, 'expired row'), isTrue);
        expect(
          await service.setSpaceRetentionPolicy(
            spaceId,
            SpaceRetentionPolicy(
              mode: SpaceRetentionMode.deleteAfter,
              retentionMs: dayMs,
            ),
          ),
          isTrue,
        );
        final sweepAt = baseMs + dayMs + graceMs + 60 * 60 * 1000;

        // A (deliberately wrong) legacy-group hint makes a fresh service
        // skip the Space entirely — proving the skip path never loads.
        await storage.putSetting(hintKey(spaceId), 'g');
        final hinted = GroupService(storage, _FakeSigner(owner));
        hinted.debugWallClockMs = () => wall;
        wall = sweepAt;
        final skipped = await hinted.sweepSpaceRetention(nowMs: sweepAt);
        expect(skipped.scanned, 0);
        expect(skipped.messagesDeleted, 0);

        // Clearing the hint restores enforcement (fail-open on missing).
        await storage.putSetting(hintKey(spaceId), '');
        final repaired = GroupService(storage, _FakeSigner(owner));
        repaired.debugWallClockMs = () => wall;
        final enforced = await repaired.sweepSpaceRetention(nowMs: sweepAt);
        expect(enforced.messagesDeleted, 1);
      },
    );

    test(
      'group index migrates from the legacy setting to the file store',
      () async {
        // One settings record caps out near 30+ groups; the index must live
        // in the chunked file store while legacy stores stay readable.
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'pw', createIfMissing: true);
        final legacyId = List.filled(64, 'a').join();
        await storage.putSetting('groups.index', jsonEncode([legacyId]));
        final service = GroupService(storage, _FakeSigner(owner));
        final groupId = await service.createGroup('Post-cap group');

        final blob = await storage.loadFile('groups.index');
        expect(blob, isNotNull, reason: 'index must move to the file store');
        final ids = (jsonDecode(utf8.decode(blob!)) as List).cast<String>();
        expect(
          ids,
          containsAll([legacyId, groupId.hex]),
          reason: 'legacy ids merge with the new one',
        );
        final legacy = await storage.getSetting('groups.index');
        expect(
          legacy == null || legacy.isEmpty,
          isTrue,
          reason: 'no oversized settings record remains',
        );
        expect(await service.listGroups(), isNotEmpty);
        await storage.close();
      },
    );

    test('purging a deleted Space clears its hint', () async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      var wall = baseMs;
      service.debugWallClockMs = () => wall;
      final spaceId = await service.createSpace('Purged');
      expect(await storage.getSetting(hintKey(spaceId)), 's');
      expect(
        await service.deleteSpace(
          spaceId,
          recoveryPeriod: const Duration(milliseconds: 1),
        ),
        isTrue,
      );
      final deadline = (await service.stateOf(
        spaceId,
      ))!.lifecycleTransition!.recoveryDeadlineMs!;
      expect((await service.purgeDeletedSpaces(nowMs: deadline)).purged, 1);
      expect(
        await storage.getSetting(hintKey(spaceId)),
        anyOf(isNull, isEmpty),
        reason: 'a purged Space leaves no stale hint behind',
      );
    });
  });

  group('retention execution', () {
    const dayMs = 24 * 60 * 60 * 1000;
    const graceMs = 7 * dayMs;
    // Anchored to the real clock: read-path retention filters use the actual
    // wall clock, so backdated fixtures would read as long-expired.
    final baseMs = DateTime.now().millisecondsSinceEpoch;

    Future<(GroupService, NodeId, int Function(), void Function(int))>
    retentionSpace() async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(owner));
      var wall = baseMs;
      service.debugWallClockMs = () => wall;
      final spaceId = await service.createSpace('Retained');
      return (service, spaceId, () => wall, (int value) => wall = value);
    }

    test('sweep keeps the retained suffix visible when the chain scope has seq '
        'gaps (author interleaves channels)', () async {
      final (service, spaceId, _, setWall) = await retentionSpace();
      final defaultChannel = (await service.channelsOf(
        spaceId,
      )).single.channelId;
      final second = await service.createChannel(
        spaceId,
        name: 'second',
        kind: SpaceChannelKind.text,
      );
      expect(second, isNotNull);
      // Interleave posts across two channels so each channel's per-author
      // seq is NON-contiguous (author seq is global across channels). The
      // default channel gets author seqs 0 and 2 (gap at 1).
      expect(
        await service.postMessage(spaceId, 'a-old', channelId: defaultChannel),
        isTrue,
      );
      expect(
        await service.postMessage(spaceId, 'b-0', channelId: second),
        isTrue,
      );
      // Activate the policy at T0 so the expired prefix qualifies at the
      // grace-adjusted sweep instant below (a late activation would predate
      // the grace window and delete nothing).
      expect(
        await service.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            retentionMs: dayMs,
          ),
        ),
        isTrue,
      );
      // A fresh row in the default channel, authored much later so it stays
      // live at the sweep instant. Its author seq is 2 (1 was the b-channel).
      setWall(baseMs + 7 * dayMs + 12 * 60 * 60 * 1000);
      expect(
        await service.postMessage(
          spaceId,
          'a-fresh',
          channelId: defaultChannel,
        ),
        isTrue,
      );

      final sweepAt = baseMs + dayMs + graceMs + 60 * 60 * 1000;
      setWall(sweepAt);
      final sweep = await service.sweepSpaceRetention(nowMs: sweepAt);
      expect(sweep.complete, isTrue);
      expect(
        sweep.messagesDeleted,
        greaterThanOrEqualTo(1),
        reason: 'the expired a-old row is deleted',
      );

      // The regression: before the hash re-anchor fix, the cut re-anchored
      // on seq==throughSeq+1, but a-fresh sits at seq 2 while the deleted
      // a-old was seq 0 — so the retained suffix was hidden. It must stay
      // visible now (the cut re-anchors on the deleted row's hash).
      final defaultMsgs = await service.messagesOf(
        spaceId,
        channelId: defaultChannel,
      );
      expect(
        defaultMsgs.map((m) => m.body),
        contains('a-fresh'),
        reason: 'retained suffix must survive a sweep across a seq gap',
      );
      expect(
        defaultMsgs.map((m) => m.body),
        isNot(contains('a-old')),
        reason: 'the expired prefix row is gone',
      );
    });

    test('sweep deletes the expired chain prefix, records a cut and keeps the '
        'retained suffix readable and appendable', () async {
      final (service, spaceId, _, setWall) = await retentionSpace();
      // Three rows at T0; two rows late enough that they are still live
      // (not merely inside grace) at the sweep instant below.
      for (var i = 0; i < 3; i++) {
        expect(await service.postMessage(spaceId, 'old-$i'), isTrue);
      }
      expect(
        await service.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            retentionMs: dayMs,
          ),
        ),
        isTrue,
      );
      setWall(baseMs + 7 * dayMs + 12 * 60 * 60 * 1000);
      for (var i = 0; i < 2; i++) {
        expect(await service.postMessage(spaceId, 'fresh-$i'), isTrue);
      }
      final beforeRows = (await service.load(spaceId))!.messages.length;

      // T0 rows expired at T0+1d and left grace at T0+8d; the T0+7.5d rows
      // expire only at T0+8.5d, so they are fully live at this instant.
      final sweepAt = baseMs + dayMs + graceMs + 60 * 60 * 1000;
      setWall(sweepAt);
      final sweep = await service.sweepSpaceRetention(nowMs: sweepAt);
      expect(sweep.complete, isTrue);
      expect(sweep.messagesDeleted, 3);
      expect(sweep.cutsRecorded, 1);

      final bundle = (await service.load(spaceId))!;
      expect(bundle.messages.length, beforeRows - 3);
      final cut = bundle.retentionCuts.values.single;
      expect(cut.author, owner);
      expect(cut.throughSeq, 2, reason: 'seqs 0..2 are the expired prefix');

      // The retained suffix must stay part of the accepted chain (the cut
      // re-anchors the fold) even though its predecessor rows are gone.
      final visible = await service.messagesOf(spaceId);
      expect(
        visible.where((m) => m.author == owner).length,
        2,
        reason: 'suffix must not be hidden as a broken chain',
      );

      // Idempotent: nothing else to delete at the same instant.
      final again = await service.sweepSpaceRetention(nowMs: sweepAt);
      expect(again.messagesDeleted, 0);
      expect(again.complete, isTrue);

      // The author keeps appending on top of the retained head and never
      // reuses a physically deleted sequence number.
      expect(await service.postMessage(spaceId, 'after-sweep'), isTrue);
      final afterRows = (await service.load(spaceId))!.messages;
      final ownSeqs =
          afterRows.where((m) => m.author == owner).map((m) => m.seq).toList()
            ..sort();
      expect(ownSeqs.first, greaterThan(cut.throughSeq));
      expect(
        (await service.messagesOf(spaceId)).length,
        greaterThanOrEqualTo(3),
      );
    });

    test(
      'holder stops serving retention-expired rows before deletion',
      () async {
        final (service, spaceId, _, setWall) = await retentionSpace();
        for (var i = 0; i < 3; i++) {
          expect(await service.postMessage(spaceId, 'row-$i'), isTrue);
        }
        expect(
          await service.setSpaceRetentionPolicy(
            spaceId,
            SpaceRetentionPolicy(
              mode: SpaceRetentionMode.deleteAfter,
              retentionMs: dayMs,
            ),
          ),
          isTrue,
        );
        final bundle = (await service.load(spaceId))!;
        final servedFresh = jsonDecode(
          service.snapshotJson(bundle, recipient: owner),
        );
        expect((servedFresh['g'] as List).length, 3);

        // Expired but still physically present (grace not over): the serve
        // boundary must already exclude the rows.
        setWall(baseMs + dayMs + 60 * 60 * 1000);
        final served = jsonDecode(
          service.snapshotJson(bundle, recipient: owner),
        );
        expect(
          (served['g'] as List? ?? const []).length,
          0,
          reason: 'expired rows must not be redistributed even before deletion',
        );
      },
    );

    test(
      'a fresh peer sees the retained suffix when the server has NOT swept yet '
      '(expired-in-grace prefix)',
      () async {
        // The read-time serve filter excludes the expired prefix, but the
        // server has not run its sweep (grace not over) so no physical cut
        // exists. The served snapshot must still carry a cut so the retained
        // suffix re-anchors on the receiver instead of being orphaned.
        final ownerStorage = FakeHvContainer().storage();
        final memberStorage = FakeHvContainer().storage();
        for (final storage in [ownerStorage, memberStorage]) {
          await storage.open(password: 'pw', createIfMissing: true);
        }
        final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
        final memberSvc = GroupService(memberStorage, _FakeSigner(bob));
        addTearDown(ownerSvc.dispose);
        addTearDown(memberSvc.dispose);
        var wall = baseMs;
        ownerSvc.debugWallClockMs = () => wall;
        memberSvc.debugWallClockMs = () => wall;

        final spaceId = await ownerSvc.createSpace(
          'Grace-window serve',
          visibility: SpaceVisibility.public,
        );
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: bob,
            role: GroupRole.member,
          ),
          isTrue,
        );
        for (var i = 0; i < 2; i++) {
          expect(
            await ownerSvc.postMessage(spaceId, 'old-$i', broadcast: false),
            isTrue,
          );
        }
        expect(
          await ownerSvc.setSpaceRetentionPolicy(
            spaceId,
            SpaceRetentionPolicy(
              mode: SpaceRetentionMode.deleteAfter,
              retentionMs: dayMs,
            ),
          ),
          isTrue,
        );
        wall = baseMs + 7 * dayMs + 12 * 60 * 60 * 1000;
        expect(
          await ownerSvc.postMessage(spaceId, 'kept-fresh', broadcast: false),
          isTrue,
        );

        // Read-time-expired (old-* are past retentionMs) but still WITHIN grace,
        // so the sweep would not delete them yet. Deliberately do NOT sweep.
        wall = baseMs + dayMs + 2 * 60 * 60 * 1000;
        final snapshot = ownerSvc.snapshotJson(
          (await ownerSvc.load(spaceId))!,
          recipient: bob,
        );
        expect(await memberSvc.ingestSnapshot(snapshot), isTrue);

        expect(
          (await memberSvc.messagesOf(spaceId)).map((m) => m.body),
          contains('kept-fresh'),
          reason:
              'serve-time retention exclusion must not orphan the live suffix '
              'on a receiver, even before the server sweeps',
        );
      },
    );

    test(
      'a fresh peer receiving a post-sweep snapshot sees the retained suffix',
      () async {
        // Two independent devices. The owner sweeps, then serves ONLY the
        // retained suffix + the cut to a member that never synced the deleted
        // prefix. The member must display the suffix: the cut re-anchors on the
        // deleted-row hash, and its anchor is delivered in this same snapshot.
        final ownerStorage = FakeHvContainer().storage();
        final memberStorage = FakeHvContainer().storage();
        for (final storage in [ownerStorage, memberStorage]) {
          await storage.open(password: 'pw', createIfMissing: true);
        }
        final ownerSvc = GroupService(ownerStorage, _FakeSigner(owner));
        final memberSvc = GroupService(memberStorage, _FakeSigner(bob));
        addTearDown(ownerSvc.dispose);
        addTearDown(memberSvc.dispose);
        var wall = baseMs;
        ownerSvc.debugWallClockMs = () => wall;
        // The member evaluates the cut's boundary-expiry at its own clock; in
        // reality both peers are at a similar wall time when the sweep runs.
        memberSvc.debugWallClockMs = () => wall;

        final spaceId = await ownerSvc.createSpace(
          'Cross-peer retention',
          visibility: SpaceVisibility.public,
        );
        expect(
          await ownerSvc.addControlOp(
            spaceId,
            ControlOp.addMember,
            target: bob,
            role: GroupRole.member,
          ),
          isTrue,
        );
        for (var i = 0; i < 3; i++) {
          expect(
            await ownerSvc.postMessage(spaceId, 'old-$i', broadcast: false),
            isTrue,
          );
        }
        expect(
          await ownerSvc.setSpaceRetentionPolicy(
            spaceId,
            SpaceRetentionPolicy(
              mode: SpaceRetentionMode.deleteAfter,
              retentionMs: dayMs,
            ),
          ),
          isTrue,
        );
        wall = baseMs + 7 * dayMs + 12 * 60 * 60 * 1000;
        expect(
          await ownerSvc.postMessage(spaceId, 'kept-fresh', broadcast: false),
          isTrue,
        );

        final sweepAt = baseMs + dayMs + graceMs + 60 * 60 * 1000;
        wall = sweepAt;
        final sweep = await ownerSvc.sweepSpaceRetention(nowMs: sweepAt);
        expect(sweep.messagesDeleted, 3);
        expect(sweep.cutsRecorded, 1);

        // The owner now holds only the retained suffix + the cut; serve it to
        // the fresh member.
        final postSweep = ownerSvc.snapshotJson(
          (await ownerSvc.load(spaceId))!,
          recipient: bob,
        );
        expect(await memberSvc.ingestSnapshot(postSweep), isTrue);

        expect(
          (await memberSvc.messagesOf(spaceId)).map((m) => m.body),
          contains('kept-fresh'),
          reason:
              'the retained suffix must be visible on a fresh peer even though '
              'its predecessor was physically deleted before the snapshot',
        );
        expect(
          (await memberSvc.load(spaceId))!.retentionCuts,
          isNotEmpty,
          reason: 'the legitimate cut (anchor present) must be accepted',
        );
      },
    );

    test('a stale holder snapshot cannot resurrect swept rows', () async {
      final (service, spaceId, _, setWall) = await retentionSpace();
      for (var i = 0; i < 3; i++) {
        expect(await service.postMessage(spaceId, 'row-$i'), isTrue);
      }
      expect(
        await service.setSpaceRetentionPolicy(
          spaceId,
          SpaceRetentionPolicy(
            mode: SpaceRetentionMode.deleteAfter,
            retentionMs: dayMs,
          ),
        ),
        isTrue,
      );
      // A snapshot captured while everything was still live = the stale
      // holder's replay payload.
      final staleSnapshot = service.snapshotJson(
        (await service.load(spaceId))!,
        recipient: owner,
      );
      expect((jsonDecode(staleSnapshot)['g'] as List).length, 3);

      final sweepAt = baseMs + dayMs + graceMs + 60 * 60 * 1000;
      setWall(sweepAt);
      final sweep = await service.sweepSpaceRetention(nowMs: sweepAt);
      expect(sweep.messagesDeleted, 3);
      final afterSweep = (await service.load(spaceId))!.messages.length;

      expect(await service.ingestSnapshot(staleSnapshot), isTrue);
      expect(
        (await service.load(spaceId))!.messages.length,
        afterSweep,
        reason: 'retired rows must be dropped at the ingest boundary',
      );
    });

    test(
      'remote retention-cut hints are validated against the signed policy',
      () async {
        final (service, spaceId, _, setWall) = await retentionSpace();
        expect(await service.postMessage(spaceId, 'live'), isTrue);
        expect(
          await service.setSpaceRetentionPolicy(
            spaceId,
            SpaceRetentionPolicy(
              mode: SpaceRetentionMode.deleteAfter,
              retentionMs: dayMs,
            ),
          ),
          isTrue,
        );
        setWall(baseMs + 2 * dayMs);
        final bundle = (await service.load(spaceId))!;
        final snapshot =
            jsonDecode(service.snapshotJson(bundle, recipient: owner))
                as Map<String, dynamic>;
        final liveRow = bundle.messages.firstWhere((m) => m.author == owner);
        final scope =
            '${defaultSpaceChannelId(spaceId).hex}'
            '|membershipEpoch:${liveRow.membershipEpoch}';
        // Every forged remote cut here must be REJECTED. An unsigned remote cut
        // is only trusted when it carries the deleted-boundary hash AND the
        // receiver holds the retained anchor (prevHash == throughHash); these
        // fabricated cuts have neither, so none may be merged.
        snapshot['rcut'] = [
          // (1) a live (non-expired) boundary — even with a hash it must fail
          // the expiry check.
          {
            'v': 1,
            'scope': scope,
            'a': liveRow.author.hex,
            's': liveRow.seq + 5,
            'h': 'a' * 64,
            't': baseMs + 2 * dayMs - 1000,
          },
          // (2) an expired boundary but NO throughHash — a hash-less remote cut
          // is never accepted.
          {
            'v': 1,
            'scope': scope,
            'a': _id(42).hex,
            's': 0,
            't': baseMs - 10 * dayMs,
          },
          // (3) an expired boundary WITH a hash but for an author whose chain the
          // receiver never synced (no local anchor with that prevHash) — the
          // censorship defence: a peer must not pre-emptively hide rows we have
          // not seen.
          {
            'v': 1,
            'scope': scope,
            'a': _id(43).hex,
            's': 0,
            'h': 'b' * 64,
            't': baseMs - 10 * dayMs,
          },
        ];
        expect(await service.ingestSnapshot(jsonEncode(snapshot)), isTrue);
        final cuts = (await service.load(spaceId))!.retentionCuts;
        expect(
          cuts,
          isEmpty,
          reason:
              'no forged remote cut (live boundary / hash-less / no local '
              'anchor) may be merged',
        );
      },
    );

    test(
      'sweep removes expired unpinned posts and preserves pinned ones',
      () async {
        final storage = FakeHvContainer().storage();
        await storage.open(password: 'pw', createIfMissing: true);
        final service = GroupService(storage, _FakeSigner(owner));
        var wall = baseMs;
        service.debugWallClockMs = () => wall;
        void setWall(int value) => wall = value;
        final spaceId = await service.createSpace(
          'Retained posts',
          visibility: SpaceVisibility.public,
        );
        final pinned = await service.publishSpacePost(
          spaceId,
          body: 'keep me',
          title: 'pinned',
          broadcast: false,
        );
        final expired = await service.publishSpacePost(
          spaceId,
          body: 'drop me',
          title: 'expired',
          broadcast: false,
        );
        expect(pinned, isNotNull);
        expect(expired, isNotNull);
        expect(
          await service.setSpacePostPinned(spaceId, pinned!.postId, true),
          isTrue,
        );
        expect(
          await service.setSpaceRetentionPolicy(
            spaceId,
            SpaceRetentionPolicy(
              mode: SpaceRetentionMode.deleteAfter,
              retentionMs: dayMs,
            ),
          ),
          isTrue,
        );
        final sweepAt = baseMs + dayMs + graceMs + 60 * 60 * 1000;
        setWall(sweepAt);
        final sweep = await service.sweepSpaceRetention(nowMs: sweepAt);
        expect(sweep.postsDeleted, greaterThanOrEqualTo(1));
        final posts = (await service.load(spaceId))!.posts;
        expect(posts.map((post) => post.postId), contains(pinned.postId));
        expect(
          posts.map((post) => post.postId),
          isNot(contains(expired!.postId)),
        );
      },
    );
  });

  group('where a new channel goes when nobody said where', () {
    // `createChannel` defaulted `position` to 0, and exactly one caller in the
    // tree — the Space management screen — ever passed anything else. So a
    // channel made through the API, the headless daemon or the debug hook
    // landed on the same position as the auto-created default channel, and
    // both this service's sort and `orderSpaceChannelsForDisplay` fell through
    // to their tiebreak on channel-id hex. The id is random, so the order is
    // random — and it is shown to the person as an arrangement they can drag.
    //
    // Observed on a live stand as "two channels named general, both at
    // position 0", which reads as a name-uniqueness problem and is not one.
    // Naming two channels the same thing is a choice a person may make; having
    // them silently share a slot is not.
    //
    // `nextSpaceChannelPosition` was written for exactly this and had one
    // caller. A helper that is correct in isolation and bypassed at the call
    // site is a shape this project has been caught by before, so these are
    // about the CALL SITE rather than about the helper.

    test('it goes after its siblings, not on top of the default', () async {
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace('Ordering');

      final before = await svc.channelsOf(spaceId);
      expect(
        before,
        isNotEmpty,
        reason: 'the Space auto-creates a default channel; without one there '
            'is nothing here to collide with and this proves nothing',
      );
      final defaultPosition = before.first.position;

      final second = await svc.createChannel(
        spaceId,
        name: 'second',
        kind: SpaceChannelKind.text,
      );
      expect(second, isNotNull);

      final made = (await svc.channelsOf(
        spaceId,
      )).firstWhere((c) => c.channelId == second);
      expect(
        made.position,
        isNot(defaultPosition),
        reason: 'it shares a slot with the default channel, so which comes '
            'first is decided by a hash of their ids',
      );
      expect(
        made.position,
        greaterThan(defaultPosition),
        reason: 'a channel added later belongs after the ones already there',
      );
    });

    test('each further one lands after the last', () async {
      // Two would be enough to catch a constant; three catches a fix that
      // returns any single value other than the default's — which would pass
      // the test above and still pile everything onto one slot.
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace('Ordering');

      const names = ['alpha', 'beta', 'gamma'];
      for (final name in names) {
        expect(
          await svc.createChannel(
            spaceId,
            name: name,
            kind: SpaceChannelKind.text,
          ),
          isNotNull,
        );
      }

      final channels = await svc.channelsOf(spaceId);
      final positions = [for (final c in channels) c.position];
      expect(
        positions.toSet().length,
        positions.length,
        reason: 'two channels share a position: '
            '${channels.map((c) => '${c.name}@${c.position}').join(', ')}',
      );

      // And the order shown is the order they were made in.
      expect(
        orderSpaceChannelsForDisplay(
          channels,
        ).map((c) => c.name).where(names.contains).toList(),
        names,
      );
    });

    test('an explicit position is still obeyed', () async {
      // The positive control. Without it a "fix" that ignored the caller and
      // always appended would pass everything above — and would break the
      // drag-to-reorder in the management screen, which is the one caller that
      // was getting this right all along.
      final (svc, _) = await setup();
      final spaceId = await svc.createSpace('Ordering');

      final pinned = await svc.createChannel(
        spaceId,
        name: 'pinned',
        kind: SpaceChannelKind.text,
        position: -500,
      );
      expect(pinned, isNotNull);

      final channels = await svc.channelsOf(spaceId);
      expect(channels.firstWhere((c) => c.channelId == pinned).position, -500);
      expect(
        orderSpaceChannelsForDisplay(channels).first.channelId,
        pinned,
        reason: 'a negative position must sort ahead of the default channel',
      );
    });
  });

  // A DEVICE GROUP TOO BIG FOR ONE FRAME COULD NEVER BE ADOPTED.
  //
  // The snapshot that carries a device group travels whole when it fits a
  // frame and in `groupEntryChunk`s when it does not. Both paths must admit a
  // sender who is not yet a contact, and they ask different questions:
  //
  //   whole   the pending adoption is consulted FIRST, and only then the
  //           general "may this stranger sync this group to me"
  //   chunked that general question ALONE — it has to decide whether to spend
  //           reassembly memory before there is a bundle to look at
  //
  // And that question opens with "is this group already in my index", which
  // for a device being linked is false by construction: the group is the thing
  // being handed over. So every chunk was dropped in silence, reassembly never
  // began, and a snapshot that had already arrived was never ingested.
  //
  // Measured on two devices on the production network before the fix: six
  // chunks of a ~17 KB snapshot arrived and left no trace, the sender reported
  // "sent", and four runs of the ceremony over about forty minutes never
  // produced the group. After it: ten seconds.
  //
  // The tests below pin the exception and its width. It is asserted through
  // `allowStrangerGroupSync` rather than by driving a chunked transfer,
  // because that is the decision the chunk path actually makes — a test that
  // reassembled chunks could pass while this answer stayed wrong.
  group('a pending device adoption admits the group it is waiting for', () {
    Future<GroupService> joining(NodeId self) async {
      final storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      final service = GroupService(storage, _FakeSigner(self));
      addTearDown(service.dispose);
      return service;
    }

    // The source is taken FROM the invite, not chosen beside it: a node id is
    // BLAKE3 of the public key, so a token whose `src` and whose invite
    // disagree is one the reader throws away — as this test found out.
    final sourceInvite = BootstrapInvite(
      publicKey: Uint8List.fromList(List.filled(32, 12)),
      nonce: Uint8List(8),
    );
    final otherInvite = BootstrapInvite(
      publicKey: Uint8List.fromList(List.filled(32, 14)),
      nonce: Uint8List(8),
    );

    DeviceLinkToken ticket(NodeId gid) => DeviceLinkToken(
      groupId: gid,
      source: sourceInvite.nodeId,
      manifestHash: Uint8List.fromList(List.filled(32, 7)),
      sourceInvite: sourceInvite,
      // 2100-01-01: far enough that a slow machine cannot expire it mid-test.
      expiresAtMs: 4102444800000,
    );

    final self = _id(11);
    final source = sourceInvite.nodeId;
    final gid = _id(13);

    test('without a ceremony an unknown group is refused, as before', () async {
      final svc = await joining(self);
      expect(await svc.allowStrangerGroupSync(source, gid.hex), isFalse);
    });

    test('with the ceremony pending it is admitted', () async {
      final svc = await joining(self);
      expect(await svc.prepareDeviceAdoption(ticket(gid)), isTrue);
      expect(
        await svc.allowStrangerGroupSync(source, gid.hex),
        isTrue,
        reason: 'the chunked snapshot of the group being linked must be let '
            'through, or reassembly never starts and linking cannot finish',
      );
    });

    // The width of the exception is the whole of its safety: it is one group,
    // from one device, for as long as this device is expecting it.
    test('only from the device the token names', () async {
      final svc = await joining(self);
      await svc.prepareDeviceAdoption(ticket(gid));
      expect(await svc.allowStrangerGroupSync(otherInvite.nodeId, gid.hex), isFalse);
    });

    test('only for the group the token names', () async {
      final svc = await joining(self);
      await svc.prepareDeviceAdoption(ticket(gid));
      expect(await svc.allowStrangerGroupSync(source, _id(15).hex), isFalse);
    });

    test('and it ends when the ceremony does', () async {
      final svc = await joining(self);
      await svc.prepareDeviceAdoption(ticket(gid));
      expect(await svc.allowStrangerGroupSync(source, gid.hex), isTrue);
      await svc.cancelPendingDeviceAdoption();
      expect(
        await svc.allowStrangerGroupSync(source, gid.hex),
        isFalse,
        reason: 'a cancelled adoption must not leave a standing permission',
      );
    });
  });

}
