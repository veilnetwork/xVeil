// Two devices of one identity writing to one group.
//
// The message log is a per-author hash chain — `seq` and `prevHash` — and a
// hash chain has exactly one writer. The author is the IDENTITY, and an
// identity now has several devices, none of which can see the others' unsent
// rows. So both pick the same next number, and the equivocation guard — which
// exists to catch an author rewriting history — reads two honest devices as one
// lying author.
//
// Measured on the stand before the fix: two rows each at seq 8 and 9, twelve
// rows retained and eight canonical, and the restored device refusing to write
// ever again (`/group_post` → ok:false, for good) because it could see its own
// chain was forked. Its own posts were invisible on it, and the newest message
// from the other device was invisible too — the whole forked suffix drops.
//
// The chain is scoped by the signing key now, so each device keeps its own.
// What must NOT change: a single device that signs two different rows at one
// seq is still equivocating, and must still be quarantined. Both are asserted
// here.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_call.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/domain/space_moderation.dart';
import 'package:xveil/domain/space_post.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/state/group_service.dart';
import 'package:xveil/state/messaging_core.dart';

import 'support/fake_hv_container.dart';

Uint8List _sig(Uint8List publicKey, Uint8List message) {
  final digest = sha256.convert([...publicKey, ...message]).bytes;
  return Uint8List.fromList([...digest, ...digest]);
}

/// One DEVICE of an identity: the same `selfId` as its sibling, its own key.
///
/// Verification here is the production rule for a sovereign identity — the
/// signature is checked against the key the row carries, and the key is
/// authorised by the identity rather than required to hash to it. That is what
/// a master-signed device subkey is, and modelling it is the whole point: with
/// the hash binding in place a second device could not sign at all, which is
/// how this went unnoticed.
class _DeviceSigner implements GroupSigner {
  _DeviceSigner({required NodeId identity, required int deviceSeed})
    : _self = identity,
      _key = Uint8List.fromList(
        List<int>.generate(32, (i) => (deviceSeed + i) & 0xff),
      );

  final NodeId _self;
  final Uint8List _key;

  @override
  NodeId get selfId => _self;
  @override
  Uint8List get selfPubKey => _key;

  @override
  SpaceManifest signSpaceManifest(SpaceManifest v) =>
      v.withSignature(_sig(selfPubKey, v.canonicalBytes()));
  @override
  ControlEntry signControl(ControlEntry u) =>
      u.withSignature(_sig(selfPubKey, u.canonicalBytes()), selfPubKey);
  @override
  GroupMessage signMessage(GroupMessage u) =>
      u.withSignature(_sig(selfPubKey, u.canonicalBytes()), selfPubKey);
  @override
  GroupReaction signReaction(GroupReaction u) =>
      u.withSignature(_sig(selfPubKey, u.canonicalBytes()), selfPubKey);
  @override
  SpacePost signPost(SpacePost u) =>
      u.withSignature(_sig(selfPubKey, u.canonicalBytes()), selfPubKey);
  @override
  GroupContentRequest signContentRequest(GroupContentRequest u) =>
      u.withSignature(_sig(selfPubKey, u.canonicalBytes()), selfPubKey);
  @override
  GroupCallSignal signCallSignal(GroupCallSignal u) =>
      u.withSignature(_sig(selfPubKey, u.canonicalBytes()), selfPubKey);
  @override
  SpaceModerationAppeal signModerationAppeal(SpaceModerationAppeal u) =>
      u.withSignature(_sig(selfPubKey, u.canonicalBytes()), selfPubKey);
  @override
  SpaceModerationAppealDecision signModerationAppealDecision(
    SpaceModerationAppealDecision u,
  ) => u.withSignature(_sig(selfPubKey, u.canonicalBytes()), selfPubKey);

  bool _ok(Uint8List key, Uint8List bytes, Uint8List signature) =>
      key.length == 32 &&
      _bytesEqual(_sig(key, bytes), signature);

  @override
  bool verifyControl(ControlEntry e) =>
      _ok(e.authorPubKey, e.canonicalBytes(), e.signature);
  @override
  bool verifyMessage(GroupMessage m) =>
      _ok(m.authorPubKey, m.canonicalBytes(), m.signature);
  @override
  bool verifyReaction(GroupReaction r) =>
      _ok(r.authorPubKey, r.canonicalBytes(), r.signature);
  @override
  bool verifyPost(SpacePost p) =>
      _ok(p.authorPubKey, p.canonicalBytes(), p.signature);
  @override
  bool verifyContentRequest(GroupContentRequest r) =>
      _ok(r.authorPubKey, r.canonicalBytes(), r.signature);
  @override
  bool verifyCallSignal(GroupCallSignal s) =>
      _ok(s.authorPubKey, s.canonicalBytes(), s.signature);
  @override
  bool verifyModerationAppeal(SpaceModerationAppeal a) =>
      _ok(a.authorPubKey, a.canonicalBytes(), a.signature);
  @override
  bool verifyModerationAppealDecision(SpaceModerationAppealDecision d) =>
      _ok(d.authorPubKey, d.canonicalBytes(), d.signature);
  @override
  bool verifySpaceManifest(SpaceManifest m) =>
      _bytesEqual(_sig(m.genesisPubKey, m.canonicalBytes()), m.signature);
  @override
  ({Uint8List signature, Uint8List publicKey}) signDetached(Uint8List message) =>
      (signature: _sig(selfPubKey, message), publicKey: selfPubKey);
  @override
  bool verifyDetached({
    required NodeId signer,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => _ok(publicKey, message, signature);
  @override
  bool verifySovereign({
    required String algorithm,
    required NodeId nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) => algorithm == 'ed25519' && _ok(publicKey, message, signature);
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<Storage> _storage() async {
  final storage = FakeHvContainer().storage();
  await storage.open(password: 'pw', createIfMissing: true);
  return storage;
}

void main() {
  final identity = NodeId(Uint8List.fromList(List.filled(32, 0xA1)));

  test('two devices of one identity do not fork each other out of the log',
      () async {
    final phone = GroupService(await _storage(), _DeviceSigner(
      identity: identity,
      deviceSeed: 1,
    ));
    final desktop = GroupService(await _storage(), _DeviceSigner(
      identity: identity,
      deviceSeed: 200,
    ));
    addTearDown(phone.dispose);
    addTearDown(desktop.dispose);

    final gid = await phone.createGroup('one identity, two devices');
    final seeded = (await phone.load(gid))!;
    expect(await desktop.ingestSnapshot(desktop.snapshotJson(seeded)), isTrue);

    // Both write while neither has seen the other's row — the concurrency that
    // used to hand them the same sequence number.
    expect(await phone.postMessage(gid, 'from the phone'), isTrue);
    expect(await desktop.postMessage(gid, 'from the desktop'), isTrue);

    // Each takes the other's snapshot, exactly as a device sync delivers it.
    final fromPhone = phone.snapshotJson((await phone.load(gid))!);
    final fromDesktop = desktop.snapshotJson((await desktop.load(gid))!);
    await desktop.ingestSnapshot(fromPhone);
    await phone.ingestSnapshot(fromDesktop);

    for (final (name, service) in [('phone', phone), ('desktop', desktop)]) {
      final bodies = (await service.messagesOf(gid))
          .map((m) => m.body)
          .toList();
      expect(
        bodies,
        containsAll(<String>['from the phone', 'from the desktop']),
        reason: 'on the $name, one device\'s row quarantined the other\'s',
      );
    }

    // And the log stays writable. Before, the first device to see the fork
    // refused every later post — permanently, since the evidence is retained.
    expect(
      await phone.postMessage(gid, 'still writable'),
      isTrue,
      reason: 'the phone stopped being able to write to its own group',
    );
    expect(
      await desktop.postMessage(gid, 'still writable too'),
      isTrue,
      reason: 'the desktop stopped being able to write to its own group',
    );
  });

  test('the outbox flush does not delete frames addressed to my own device',
      () async {
    // The flush retires any frame whose peer is not a contact, and a sibling
    // is never a contact — the identity does not befriend itself. Measured on
    // the stand: a chunked snapshot's first chunk deposited, the rest deferred
    // "for the outbox flush to reconsider", and the flush had already deleted
    // the frames it would have reconsidered. The sender's outbox read 0 and
    // the sibling waited forever.
    final storage = await _storage();
    final messaging = MessagingService(
      LoopbackTransport(localNodeId: NodeId(Uint8List.fromList(List.filled(32, 1)))),
      storage,
    );
    addTearDown(messaging.dispose);
    final sibling = NodeId(Uint8List.fromList(List.filled(32, 0xB2)));
    messaging.isOwnDevice = (peer) async => peer == sibling;

    await storage.enqueueOutboxFrame(
      'grpc:grp:aa:bb:${sibling.hex}:0',
      sibling.hex,
      Uint8List.fromList([1, 2, 3]),
    );
    final stranger = NodeId(Uint8List.fromList(List.filled(32, 0xC3)));
    await storage.enqueueOutboxFrame(
      'grpc:grp:aa:bb:${stranger.hex}:0',
      stranger.hex,
      Uint8List.fromList([4, 5, 6]),
    );

    await messaging.debugFlushOutboxFrames();

    final kept = (await storage.pendingOutboxFrames())
        .map((frame) => frame.peerHex)
        .toList();
    expect(
      kept,
      contains(sibling.hex),
      reason: 'the flush deleted a frame addressed to my own device',
    );
    expect(
      kept,
      isNot(contains(stranger.hex)),
      reason: 'a frame to an actual stranger must still be retired',
    );
  });

  test('a membership append survives a concurrent snapshot ingest', () async {
    // The lost update, reproduced: the sibling's periodic device-group
    // snapshot ingests every few seconds, and an append that runs
    // load-to-save beside it loses its entry to the ingest's save of what it
    // had read earlier. On the stand a revoke answered ok TWICE and removed
    // nobody. The append now runs under the group's mutation lock, reloading
    // inside it, so whichever runs second sees the other's write.
    final signerA = _DeviceSigner(identity: identity, deviceSeed: 21);
    final service = GroupService(await _storage(), signerA);
    addTearDown(service.dispose);
    final gid = await service.createGroup('membership under fire');
    final peer = NodeId(Uint8List.fromList(List.filled(32, 0xE1)));
    await service.addControlOp(
      gid,
      ControlOp.addMember,
      target: peer,
      role: GroupRole.member,
    );
    // A stale snapshot of the group BEFORE the member was added — exactly what
    // the sibling holds when the race fires.
    final stale = service.snapshotJson(
      (await service.load(gid))!,
    );
    await service.addControlOp(
      gid,
      ControlOp.removeMember,
      target: peer,
    );
    // The stale snapshot lands AFTER the removal. Union-merge must keep the
    // removal; last-write-wins would resurrect the member.
    await service.ingestSnapshot(stale);
    final state = (await service.stateOf(gid))!;
    expect(
      state.isMember(peer),
      isFalse,
      reason: 'a stale snapshot resurrected a removed member',
    );
  });

  test('one device signing two rows at one seq is still equivocation',
      () async {
    // The guard must keep doing its job WITHIN a device: this is an author
    // rewriting history, and scoping by device must not have made it legal.
    final signer = _DeviceSigner(identity: identity, deviceSeed: 7);
    final service = GroupService(await _storage(), signer);
    addTearDown(service.dispose);
    final gid = await service.createGroup('equivocation still counts');
    expect(await service.postMessage(gid, 'first'), isTrue);

    final bundle = (await service.load(gid))!;
    final original = bundle.messages.last;
    final twin = signer.signMessage(
      GroupMessage(
        groupId: original.groupId,
        author: original.author,
        seq: original.seq,
        prevHash: original.prevHash,
        body: 'a different row at the same number',
        version: original.version,
        policyVersion: original.policyVersion,
        createdAtMs: original.createdAtMs + 1,
        signature: Uint8List(0),
      ),
    );
    expect(
      await service.ingestSnapshot(
        service.snapshotJson(
          GroupBundle(
            manifest: bundle.manifest,
            control: bundle.control,
            messages: [...bundle.messages, twin],
          ),
        ),
      ),
      isTrue,
    );

    expect(
      await service.postMessage(gid, 'after the fork'),
      isFalse,
      reason: 'a device that equivocated must not keep writing',
    );
  });
}
