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

class _CountingGroupReadStorage extends HiddenVolumeStorage {
  _CountingGroupReadStorage()
    : super(
        ({required Uint8List password, required bool create}) =>
            FakeKvLogStore(),
      );

  int groupBundleReads = 0;

  @override
  Future<Uint8List?> loadFile(String fileId) async {
    if (fileId.startsWith('group:')) groupBundleReads++;
    return super.loadFile(fileId);
  }
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
      storage.groupBundleReads = 0;

      expect(
        (await service.spaceObservabilitySnapshot()).replication.spaces,
        1,
      );
      expect(
        storage.groupBundleReads,
        1,
        reason:
            'frontier and message materialization must reuse the validated '
            'bundle loaded by the snapshot',
      );

      storage.groupBundleReads = 0;
      expect(
        (await service.spaceObservabilitySnapshot()).replication.spaces,
        1,
      );
      expect(
        storage.groupBundleReads,
        1,
        reason: 'a later snapshot must still perform one fresh durable read',
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
          media: [MediaObjectRef(contentId: cids[i], kind: 'image', size: 1)],
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
    final peers = [_id(7), _id(2), self, _id(5), _id(3), _id(0), _id(3)];

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
            MediaObjectRef(contentId: cid, kind: 'file', size: bytes.length),
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
      expect(manifest['v'], GroupManifest.sovereignDeviceVersion);
      expect(manifest['kind'], GroupManifest.sovereignDeviceKind);
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
      final legacyManifest = GroupManifest(
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
      expect((vector['mg'] as Map), contains('${defaultChannel.hex}|clear'));
      expect((vector['mg'] as Map), contains('${secondChannel!.hex}|clear'));
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
          (((forkedRequest['ms'] as Map)['group|clear'] as Map)[owner.hex]
                  as Map)['f']
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

  test('a protected channel key can be replaced without touching its ACL', () async {
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
    expect(await service.setChannelMembers(spaceId, channelId!, [bob]), isTrue);

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
  });

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
      epochService: GroupEpochService(LoopbackMailboxCrypto(senderForOpen: bob)),
    );
    expect(
      await bobSvc.ingestSnapshot(
        ownerSvc.snapshotJson((await ownerSvc.load(spaceId))!, recipient: bob),
      ),
      isTrue,
    );
    final epochForBob =
        (await bobSvc.stateOf(spaceId))!
            .protectedChannels[channelId.hex]!
            .channelEpoch;

    expect(
      await bobSvc.rotateChannelKey(spaceId, channelId),
      isFalse,
      reason: 'a reader of the channel is not thereby its key holder',
    );
    expect(
      (await bobSvc.stateOf(spaceId))!
          .protectedChannels[channelId.hex]!
          .channelEpoch,
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
    final epochAtRest =
        (await service.stateOf(spaceId))!
            .protectedChannels[channelId!.hex]!
            .channelEpoch;

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
    final rotated =
        (await service.stateOf(spaceId))!
            .protectedChannels[channelId.hex]!
            .channelEpoch;
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
    final epochAtRest =
        (await service.stateOf(spaceId))!
            .protectedChannels[channelId!.hex]!
            .channelEpoch;

    for (var i = 0; i < GroupService.protectedChannelKeyMaxMessages; i++) {
      expect(
        await service.postMessage(spaceId, 'm$i', channelId: channelId),
        isTrue,
      );
    }
    expect(await service.sweepStaleChannelKeys(), 1);
    expect(
      (await service.stateOf(spaceId))!
          .protectedChannels[channelId.hex]!
          .channelEpoch,
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
      final draftMedia = MediaObjectRef(
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
        media: [MediaObjectRef(contentId: 'e' * 64, kind: 'image')],
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
        media: [MediaObjectRef(contentId: 'a' * 64, kind: 'image')],
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
        media: [MediaObjectRef(contentId: 'a' * 64, kind: 'image')],
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
        media: [MediaObjectRef(contentId: 'b' * 64, kind: 'image')],
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
      expect(
        toBob,
        isEmpty,
        reason: 'a revoked member is absent from post-fold delivery fanout',
      );
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
          ((syncVector['cg'] as Map)['${channelId!.hex}|channelEpoch:1']
                  as Map)[bob.hex]
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
        media: [
          MediaObjectRef(contentId: cid, kind: 'file', size: bytes.length),
        ],
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
}
