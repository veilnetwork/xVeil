import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/group.dart';
import 'package:xveil/domain/group_content.dart';
import 'package:xveil/domain/group_message.dart';
import 'package:xveil/domain/group_reaction.dart';
import 'package:xveil/state/group_service.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

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
  ControlEntry signControl(ControlEntry u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  GroupMessage signMessage(GroupMessage u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  GroupReaction signReaction(GroupReaction u) =>
      u.withSignature(Uint8List(64), u.author.bytes);
  @override
  GroupContentRequest signContentRequest(GroupContentRequest u) =>
      u.withSignature(Uint8List(64), u.requester.bytes);
  @override
  bool verifyControl(ControlEntry e) =>
      e.signature.length == 64 && e.authorPubKey.length == 32;
  @override
  bool verifyContentRequest(GroupContentRequest r) =>
      r.signature.length == 64 && r.authorPubKey.length == 32;
  @override
  bool verifyMessage(GroupMessage m) =>
      m.signature.length == 64 && m.authorPubKey.length == 32;
  @override
  bool verifyReaction(GroupReaction r) =>
      r.signature.length == 64 && r.authorPubKey.length == 32;
}

void main() {
  final owner = _id(1);
  final bob = _id(3);
  final carol = _id(4);
  final stranger = _id(7);

  /// Fresh storage + an owner-perspective service; extra services over the SAME
  /// storage model other members on their own devices.
  Future<(GroupService, dynamic Function(NodeId))> setup() async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    GroupService member(NodeId self) => GroupService(storage, _FakeSigner(self));
    return (member(owner), member);
  }

  test('create -> owner is sole member, group persists + lists', () async {
    final (svc, _) = await setup();
    final gid = await svc.createGroup('Family');
    final state = (await svc.stateOf(gid))!;
    expect(state.roleOf(owner), GroupRole.owner);
    expect(state.members.length, 1);
    final groups = await svc.listGroups();
    expect(groups.single.name, 'Family');
    expect(groups.single.groupId, gid);
  });

  test('owner adds a member; a plain member cannot add', () async {
    final (svc, member) = await setup();
    final gid = await svc.createGroup('G');
    expect(
        await svc.addControlOp(gid, ControlOp.addMember,
            target: bob, role: GroupRole.member),
        isTrue);
    expect((await svc.stateOf(gid))!.isMember(bob), isTrue);

    expect(
        await member(bob).addControlOp(gid, ControlOp.addMember,
            target: carol, role: GroupRole.member),
        isFalse);
    expect((await svc.stateOf(gid))!.isMember(carol), isFalse);
  });

  test('post + read: a member posts, a stranger cannot', () async {
    final (svc, member) = await setup();
    final gid = await svc.createGroup('G');
    await svc.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);

    expect(await svc.postMessage(gid, 'hi from owner'), isTrue);
    expect(await member(bob).postMessage(gid, 'hi from bob'), isTrue);
    expect(await member(stranger).postMessage(gid, 'spam'), isFalse);

    final msgs = await svc.messagesOf(gid);
    expect(msgs.map((m) => m.body),
        containsAll(['hi from owner', 'hi from bob']));
    expect(msgs.length, 2, reason: 'stranger message was never stored');
  });

  test('a muted member cannot post; unmute restores', () async {
    final (svc, member) = await setup();
    final gid = await svc.createGroup('G');
    await svc.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);
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
    await owned.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);
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
    expect(b!.control.length, 1);
    expect(b.messages.length, 1);
  });

  test('broadcast ships the snapshot to every other member', () async {
    final sent = <(NodeId, NodeId)>[];
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner),
        send: (peer, gid, json) async => sent.add((peer, gid)));
    final gid = await svc.createGroup('G');
    await svc.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);
    await svc.addControlOp(gid, ControlOp.addMember,
        target: carol, role: GroupRole.member);
    final n = await svc.broadcast(gid);
    expect(n, 2, reason: 'both members, not self');
    expect(sent.map((e) => e.$1).toSet(), {bob, carol});
    expect(sent.every((e) => e.$2 == gid), isTrue);
  });

  test('inline image attachment persists + survives snapshot round-trip',
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
    await owned.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);
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
  });

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
    final withImg =
        base(att: const GroupAttachment(kind: 'image', dataB64: 'QQ', w: 1, h: 1))
            .canonicalBytes();
    // The attachment is inside the signed bytes (tamper-evident)...
    expect(withImg, isNot(equals(textOnly)));
    // ...and a text-only message signs byte-identically to before the field
    // existed (the 'att' key is omitted, not null).
    expect(String.fromCharCodes(textOnly).contains('att'), isFalse);
    // JSON round-trip preserves the attachment.
    final rt = GroupMessage.fromJson(base(
            att: const GroupAttachment(
                kind: 'image', dataB64: 'QQ', w: 2, h: 3))
        .toJson())!;
    expect(rt.attachment?.w, 2);
    expect(rt.attachment?.h, 3);
    expect(rt.attachment?.dataB64, 'QQ');
  });

  test('voice attachment: durationMs rides in w, round-trips, signs stably',
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
              kind: 'voice', dataB64: 'Vk9QMQ', w: 4200, h: 1),
        );
    final rt = GroupMessage.fromJson(voiceMsg().toJson())!;
    expect(rt.attachment?.kind, 'voice');
    expect(rt.attachment?.w, 4200, reason: 'durationMs travels in w');
    expect(rt.attachment?.h, 1);
    // The parsed message re-canonicalizes byte-identically — a signature a
    // voice-aware build minted verifies on any build (zero schema change).
    expect(rt.canonicalBytes(), voiceMsg().canonicalBytes());
  });

  test('content path: member request → grant; stranger/replay/unknown → drop',
      () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final grants = <(NodeId, String)>[];
    final sentReq = <String>[];
    final svc = GroupService(storage, _FakeSigner(owner),
        grantContentServe: (peer, cid) => grants.add((peer, cid)));
    final gid = await svc.createGroup('G');
    await svc.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);
    await svc.postMessage(gid, '',
        attachment: const GroupAttachment(
            kind: 'image', dataB64: 'QQ', w: 1, h: 1, cid: 'c0ffee'));
    expect(await svc.referencedContentIds(gid), {'c0ffee'});

    // Bob (member, own service+store) mints a signed request…
    final bobStorage = FakeHvContainer().storage();
    await bobStorage.open(password: 'pw', createIfMissing: true);
    final bobSvc = GroupService(bobStorage, _FakeSigner(bob),
        sendContentRequest: (holder, json) async => sentReq.add(json));
    expect(await bobSvc.requestGroupContent(gid, 'c0ffee', owner), isTrue);
    // …and the holder authorizes: a grant for exactly (bob, cid).
    expect(await svc.handleContentRequest(sentReq.last), isTrue);
    expect(grants.single.$1, bob);
    expect(grants.single.$2, 'c0ffee');

    // A replay of the same request is refused (nonce cache).
    expect(await svc.handleContentRequest(sentReq.last), isFalse);

    // A stranger's request never grants.
    final evieSvc = GroupService(bobStorage, _FakeSigner(_id(7)),
        sendContentRequest: (holder, json) async => sentReq.add(json));
    expect(await evieSvc.requestGroupContent(gid, 'c0ffee', owner), isTrue);
    expect(await svc.handleContentRequest(sentReq.last), isFalse);

    // A cid the group never referenced never grants either.
    expect(await bobSvc.requestGroupContent(gid, 'beef', owner), isTrue);
    expect(await svc.handleContentRequest(sentReq.last), isFalse);
    expect(grants, hasLength(1));
  });

  test('fetchGroupContent ships the signed request, then starts the pull',
      () async {
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final sentReq = <String>[];
    final pulls = <(NodeId, String)>[];
    final svc = GroupService(storage, _FakeSigner(bob),
        sendContentRequest: (holder, json) async => sentReq.add(json),
        startContentPull: (holder, cid) async => pulls.add((holder, cid)));
    final gid = await svc.createGroup('G');
    expect(await svc.fetchGroupContent(gid, 'c0ffee', owner), isTrue);
    expect(sentReq, hasLength(1), reason: 'the membership proof went first');
    expect(pulls.single.$1, owner);
    expect(pulls.single.$2, 'c0ffee');
    // Without a pull sink the flow reports not-started (nothing to drive).
    final noPull = GroupService(storage, _FakeSigner(bob),
        sendContentRequest: (holder, json) async => sentReq.add(json));
    expect(await noPull.fetchGroupContent(gid, 'c0ffee', owner), isFalse);
  });

  test('stranger sync: member delta merges into a held group; others drop',
      () async {
    Future<void> drain() async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    final sent = <String>[];
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    final ownerSvc = GroupService(s1, _FakeSigner(owner),
        send: (p, g, j) async => sent.add(j));
    final gid = await ownerSvc.createGroup('G');
    await ownerSvc.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);
    await drain();
    final full = sent.last; // the join snapshot bob's device materializes from

    final s2 = FakeHvContainer().storage();
    await s2.open(password: 'pw', createIfMissing: true);
    final bobSvc = GroupService(s2, _FakeSigner(bob),
        send: (p, g, j) async => sent.add(j));
    expect(await bobSvc.ingestSnapshot(full), isTrue);
    sent.clear();
    await bobSvc.postMessage(gid, 'from-bob');
    await drain();
    final delta = sent.last;

    // Bob needs NO contact relationship: he is a member per the owner's fold.
    expect(await ownerSvc.allowStrangerGroupSync(bob, gid.hex), isTrue);
    expect(await ownerSvc.ingestSnapshotFromStranger(bob, delta), isTrue);
    expect((await ownerSvc.messagesOf(gid)).map((m) => m.body),
        contains('from-bob'));

    // A non-member stranger is refused even with a well-formed bundle…
    expect(await ownerSvc.ingestSnapshotFromStranger(_id(7), delta), isFalse);
    // …and a group we don't hold NEVER materializes from a stranger.
    expect(await ownerSvc.allowStrangerGroupSync(bob, 'ff' * 32), isFalse);
    expect(
        await ownerSvc.ingestSnapshotFromStranger(
            bob, '{"m":{"gid":"${'ff' * 32}"}}'),
        isFalse);
  });

  test('unread + incoming: ingest feeds the stream, watermark clears the count',
      () async {
    Future<void> drain() async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    final sent = <String>[];
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    final ownerSvc = GroupService(s1, _FakeSigner(owner),
        send: (p, g, j) async => sent.add(j));
    final gid = await ownerSvc.createGroup('G');
    await ownerSvc.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);
    await drain();
    final s2 = FakeHvContainer().storage();
    await s2.open(password: 'pw', createIfMissing: true);
    final bobSvc = GroupService(s2, _FakeSigner(bob),
        send: (p, g, j) async => sent.add(j));
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
    await ownerSvc.setGroupMuted(gid, false);
    expect(await ownerSvc.isGroupMuted(gid), isFalse);
  });

  test('mirror loop: msgMirror events fold + apply, deduped, deniability-safe',
      () async {
    // Pure fold/codec check of the mirror event vocabulary against the store's
    // dedup contract — the wiring (onMessageStored → postDeviceEvent →
    // deviceIncoming → applyMirroredMessage) is exercised on-device; here we
    // pin the fold that carries it.
    final a = DeviceSyncEvent(
        kind: DeviceSyncKind.msgMirror,
        key: 'm1',
        tsMs: 10,
        payload: const {'peer': 'aa', 'dir': 'incoming', 'body': 'hi'});
    final dup = DeviceSyncEvent(
        kind: DeviceSyncKind.msgMirror,
        key: 'm1',
        tsMs: 10,
        payload: const {'peer': 'aa', 'dir': 'incoming', 'body': 'hi'});
    final b = DeviceSyncEvent(
        kind: DeviceSyncKind.msgMirror,
        key: 'm2',
        tsMs: 20,
        payload: const {'peer': 'aa', 'dir': 'outgoing', 'body': 'yo'});
    final folded = foldDeviceSync([a, dup, b]);
    // One entry per msgId (the mirror key IS the message id → idempotent apply).
    expect(folded.length, 2);
    expect(folded[(DeviceSyncKind.msgMirror, 'm1')]!.payload['body'], 'hi');
    expect(folded[(DeviceSyncKind.msgMirror, 'm2')]!.payload['dir'],
        'outgoing');
    // Body codec preserves the mirror payload across the wire.
    expect(DeviceSyncEvent.fromBody(a.toBody())!.payload, a.payload);
  });

  test('device group: link/adopt/revoke lifecycle, hidden + silent', () async {
    Future<void> drain() async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    final sent = <String>[];
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    final primary = GroupService(s1, _FakeSigner(owner),
        send: (p, g, j) async => sent.add(j));

    // First link creates the device group; the second reuses it (a different
    // device — bob is _id(3), so link _id(4) as the second phone).
    expect(await primary.deviceGroupIdHex(), isNull);
    expect(await primary.linkDevice(bob), isTrue);
    final gidHex = (await primary.deviceGroupIdHex())!;
    expect(await primary.linkDevice(_id(4)), isTrue);
    expect(await primary.deviceGroupIdHex(), gidHex);
    await drain();

    // Hidden from the user-facing group list despite being a real group…
    expect((await primary.listGroups()).where((g) => g.groupId.hex == gidHex),
        isEmpty);
    // …and a linked device is an ADMIN (it can manage devices below it).
    final st = (await primary.stateOf(NodeId.fromHex(gidHex)))!;
    expect(st.roleOf(bob), GroupRole.admin);

    // The NEW device adopts via the handshake id, then sees the same group.
    final s2 = FakeHvContainer().storage();
    await s2.open(password: 'pw', createIfMissing: true);
    final secondary = GroupService(s2, _FakeSigner(bob));
    expect(await secondary.ingestSnapshot(sent.first), isTrue);
    await secondary.adoptDeviceGroup(NodeId.fromHex(gidHex));
    expect(await secondary.deviceGroupIdHex(), gidHex);

    // Sync events round-trip through the device log and fold newest-wins…
    final chat = <String>[];
    final sub = primary.incoming.listen((n) => chat.add(n.message.body));
    expect(
        await secondary.postDeviceEvent(DeviceSyncEvent(
            kind: DeviceSyncKind.settingSet,
            key: 'theme',
            tsMs: 111,
            payload: const {'v': 'dark'})),
        isTrue);
    final deltas = <String>[];
    final secondary2 = GroupService(s2, _FakeSigner(bob),
        send: (p, g, j) async => deltas.add(j));
    await secondary2.postDeviceEvent(DeviceSyncEvent(
        kind: DeviceSyncKind.settingSet,
        key: 'theme',
        tsMs: 222,
        payload: const {'v': 'light'}));
    await drain();
    for (final d in deltas) {
      await primary.ingestSnapshot(d);
    }
    await drain();
    final folded = await primary.deviceSyncState();
    expect(folded[(DeviceSyncKind.settingSet, 'theme')]!.payload['v'],
        'light');
    // …and device-group traffic NEVER feeds the chat notification stream.
    expect(chat, isEmpty);
    await sub.cancel();

    // Revoke removes the device and rotates the epoch.
    final epochBefore =
        (await primary.stateOf(NodeId.fromHex(gidHex)))!.epoch;
    expect(await primary.revokeDevice(bob), isTrue);
    final after = (await primary.stateOf(NodeId.fromHex(gidHex)))!;
    expect(after.isMember(bob), isFalse);
    expect(after.epoch, greaterThan(epochBefore));
  });

  test('postDeviceEvent: concurrent fire-and-forget emits ALL land '
      '(regression: two unawaited posts raced the group log read-modify-write '
      'and the later save dropped the earlier append — caught in the brick-4 '
      'device verify)', () async {
    final s = FakeHvContainer().storage();
    await s.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(s, _FakeSigner(owner));
    await svc.linkDevice(bob);

    // Fire a burst WITHOUT awaiting each — exactly what the sync taps do.
    final posts = [
      for (var i = 0; i < 5; i++)
        svc.postDeviceEvent(DeviceSyncEvent(
            kind: DeviceSyncKind.contactUp,
            key: 'peer$i',
            tsMs: 1000 + i,
            payload: {'pin': i.isEven})),
    ];
    expect(await Future.wait(posts), everyElement(isTrue));
    final folded = await svc.deviceSyncState();
    for (var i = 0; i < 5; i++) {
      expect(folded[(DeviceSyncKind.contactUp, 'peer$i')], isNotNull,
          reason: 'emit $i must survive the concurrent burst');
    }
  });

  test('isMyDevice: true only for current device-group members, and the '
      'cache invalidates on revoke (brick 4c mirror exclusion)', () async {
    final s = FakeHvContainer().storage();
    await s.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(s, _FakeSigner(owner));
    expect(await svc.isMyDevice(bob), isFalse,
        reason: 'no device group yet');
    await svc.linkDevice(bob);
    expect(await svc.isMyDevice(bob), isTrue);
    expect(await svc.isMyDevice(_id(9)), isFalse);
    await svc.revokeDevice(bob);
    expect(await svc.isMyDevice(bob), isFalse,
        reason: 'revoke must invalidate the cached member set');

    // Group seen mirror: apply is monotonic and never fires the local tap.
    final taps = <(String, int)>[];
    svc.onGroupSeen = (g, ts) => taps.add((g, ts));
    expect(await svc.applyMirroredGroupSeen('aa', 500), isTrue);
    expect(await svc.applyMirroredGroupSeen('aa', 400), isFalse);
    expect(taps, isEmpty, reason: 'apply must not echo into the tap');
  });

  test('postDeviceEvent with an attachment ref authorizes the membership pull '
      '(brick 4b: the cid lands in referencedContentIds of the device group)',
      () async {
    final s = FakeHvContainer().storage();
    await s.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(s, _FakeSigner(owner));
    await svc.linkDevice(bob);
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
              }),
          attachment: const GroupAttachment(
              kind: 'file', dataB64: 'AA==', w: 1, h: 1, cid: 'cafe01'),
        ),
        isTrue);
    expect(await svc.referencedContentIds(gid), contains('cafe01'),
        reason: 'the ref is what lets my other device fetch the bytes');
    // The event still parses as a normal msgMirror with the file payload.
    final msgs = await svc.messagesOf(gid);
    final e = DeviceSyncEvent.fromBody(msgs.last.body)!;
    expect(e.payload['cid'], 'cafe01');
    expect(msgs.last.attachment?.cid, 'cafe01');
  });

  // Auto-broadcast is unawaited (fire-and-forget) — let it drain.
  Future<void> pump() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('postMessage ships a DELTA (only the new message), not the whole log',
      () async {
    final sent = <String>[];
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner),
        send: (peer, gid, json) async => sent.add(json));
    final gid = await svc.createGroup('G');
    await svc.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);
    await svc.postMessage(gid, 'first');
    await svc.postMessage(gid, 'second');
    await pump();
    // The last send is the delta for 'second' — ONLY that message, no control.
    final last = jsonDecode(sent.last) as Map;
    final bodies =
        (last['g'] as List).map((m) => (m as Map)['body']).toList();
    expect(bodies, ['second'], reason: 'delta carries only the new message');
    expect(last['c'] as List, isEmpty);
    expect(last['m'], isNotNull, reason: 'manifest rides along for a racing join');
  });

  test('addMember ships a FULL snapshot so a joining member gets history',
      () async {
    final sent = <String>[];
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner),
        send: (peer, gid, json) async => sent.add(json));
    final gid = await svc.createGroup('G');
    await svc.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);
    await svc.postMessage(gid, 'history');
    await pump();
    sent.clear();
    await svc.addControlOp(gid, ControlOp.addMember,
        target: carol, role: GroupRole.member);
    await pump();
    final snap = jsonDecode(sent.last) as Map;
    final bodies =
        (snap['g'] as List).map((m) => (m as Map)['body']).toList();
    expect(bodies, contains('history'),
        reason: 'the full snapshot on join carries the prior log');
  });

  test('a mute op ships a control DELTA (no messages re-sent)', () async {
    final sent = <String>[];
    final storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    final svc = GroupService(storage, _FakeSigner(owner),
        send: (peer, gid, json) async => sent.add(json));
    final gid = await svc.createGroup('G');
    await svc.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);
    await svc.postMessage(gid, 'msg');
    await pump();
    sent.clear();
    await svc.addControlOp(gid, ControlOp.mute, target: bob);
    await pump();
    final delta = jsonDecode(sent.last) as Map;
    expect(delta['g'] as List, isEmpty, reason: 'a mute re-sends no messages');
    expect((delta['c'] as List).length, 1, reason: 'just the mute entry');
  });

  test('a member leaves: removed from state + hidden from their list; owner cannot',
      () async {
    final (svc, member) = await setup();
    final gid = await svc.createGroup('G');
    await svc.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);
    expect((await svc.stateOf(gid))!.isMember(bob), isTrue);

    final bobDev = member(bob);
    expect(await bobDev.leaveGroup(gid), isTrue);
    expect((await svc.stateOf(gid))!.isMember(bob), isFalse,
        reason: 'the leave op removes the author');
    expect((await bobDev.listGroups()).where((g) => g.groupId == gid), isEmpty,
        reason: 'a left group is hidden from the leaver');
    expect(
        (await svc.listGroups()).where((g) => g.groupId == gid), isNotEmpty,
        reason: 'the owner still sees it');

    // The owner is the genesis and cannot leave.
    expect(await svc.leaveGroup(gid), isFalse);
    expect((await svc.stateOf(gid))!.isMember(owner), isTrue);
  });

  test('reactions: toggle on/off, aggregate, and survive snapshot round-trip',
      () async {
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    final owned = GroupService(s1, _FakeSigner(owner));
    final gid = await owned.createGroup('G');
    await owned.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);
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
    await carolDev.ingestSnapshot(owned.snapshotJson((await owned.load(gid))!));
    final got = await carolDev.reactionsOf(gid);
    expect(got[ref]!['❤'], contains(bob));
  });

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
    expect(withReply, isNot(equals(plain)),
        reason: 'the reply ref is inside the signed bytes (tamper-evident)');
    expect(String.fromCharCodes(plain).contains('"rt"'), isFalse,
        reason: 'a non-reply message signs as before the field existed');
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
    final owned = GroupService(s1, _FakeSigner(owner),
        send: (peer, gid, json) async => lastDelta = json);
    final gid = await owned.createGroup('Shared');
    await owned.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);

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
    final e = _FakeSigner(owner).signControl(ControlEntry(
      author: owner,
      seq: 0,
      prevHash: '',
      op: ControlOp.addMember,
      target: bob,
      role: GroupRole.member,
      policyVersion: 0,
      createdAtMs: 1,
      signature: Uint8List(0),
    ));
    await svc.ingestControl(gid, e);
    await svc.ingestControl(gid, e); // duplicate
    final b = await svc.load(gid);
    expect(b!.control.length, 1);
    expect((await svc.stateOf(gid))!.isMember(bob), isTrue);
  });

  test('rename: owner renames, name folds + lists; a plain member cannot',
      () async {
    // Owner device, capturing what gets broadcast so we can confirm it's a
    // DELTA (a setName control op ships without re-sending the whole log).
    final s1 = FakeHvContainer().storage();
    await s1.open(password: 'pw', createIfMissing: true);
    String? lastDelta;
    final owned = GroupService(s1, _FakeSigner(owner),
        send: (peer, gid, json) async => lastDelta = json);
    final gid = await owned.createGroup('Old name');
    await owned.addControlOp(gid, ControlOp.addMember,
        target: bob, role: GroupRole.member);

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
  });
}
