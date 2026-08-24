// Multi-device brick 4: contacts / app settings / call journal sync.
// Covers the EMIT taps (fire on local change, silent on apply), the loop
// guards, and the journal store's idempotence + cap — the pure halves of the
// bridge; the wire path itself is device-verified.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/domain/call_log.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/p2p_policy.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/domain/disappearing_messages.dart';
import 'package:xveil/state/device_sync_bridge.dart';
import 'package:xveil/state/call_log.dart';
import 'package:xveil/state/device_settings_sync.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

class _Noop implements VeilTransport {
  _Noop(this._me);
  final NodeId _me;
  final _in = StreamController<InboundMessage>.broadcast();
  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _in.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {}
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) async {}
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _in.close();
}

SpaceOpener _mem() {
  final s = FakeKvLogStore();
  return ({required password, required bool create}) => s;
}

Future<HiddenVolumeStorage> _openStorage() async {
  final storage = HiddenVolumeStorage(_mem());
  await storage.open(password: 'p', createIfMissing: true);
  return storage;
}

void main() {
  test(
    'contact pref setters fire onContactPrefsChanged with the fresh record; '
    'applyMirroredContact writes silently and keeps local-only fields',
    () async {
      final me = _id(1), peer = _id(2);
      final storage = await _openStorage();
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final svc = MessagingService(_Noop(me), storage)..start();
      addTearDown(svc.dispose);

      final emitted = <Contact>[];
      svc.onContactPrefsChanged = emitted.add;

      await svc.setContactName(peer, 'Alice');
      await svc.setContactPinned(peer, true);
      expect(emitted.length, 2, reason: 'one emit per local pref edit');
      expect(emitted.last.name, 'Alice');
      expect(emitted.last.pinned, isTrue);

      // The per-device P2P override must NOT sync — no emit.
      await svc.setContactP2POverride(peer, ContactP2POverride.allow);
      expect(emitted.length, 2, reason: 'p2pOverride stays local-only');

      // Apply a record mirrored from another device: no re-emit (loop guard),
      // synced fields land, local-only status/p2pOverride survive.
      final wrote = await svc.applyMirroredContact(
        peer: peer,
        name: 'Алиса',
        mutedUntilMs: null,
        pinned: false,
        archived: true,
        retentionDays: 7,
        allowPeerDelete: false,
      );
      expect(wrote, isTrue);
      expect(
        emitted.length,
        2,
        reason: 'a mirrored contact must not re-mirror',
      );
      final c = (await storage.getContact(peer))!;
      expect(c.name, 'Алиса');
      expect(c.archived, isTrue);
      expect(c.pinned, isFalse);
      expect(c.retentionDays, 7);
      expect(c.allowPeerDelete, isFalse);
      expect(c.status, ContactStatus.accepted, reason: 'status is local-only');
      expect(
        c.p2pOverride,
        ContactP2POverride.allow,
        reason: 'p2pOverride is local-only',
      );

      // An unknown peer is skipped silently (the relationship is not synced).
      expect(
        await svc.applyMirroredContact(
          peer: _id(9),
          pinned: true,
          archived: false,
          allowPeerDelete: true,
        ),
        isFalse,
      );
      expect(await storage.getContact(_id(9)), isNull);
    },
  );

  /// The retention window is the one preference the interface makes a promise
  /// about, and mirroring an unrelated edit used to switch it off.
  ///
  /// `applyContact` rebuilt the whole record from the seven fields the bridge
  /// carries, so everything it was not told about fell to its default: ttl to
  /// null, the stamp to 0, the setter to empty. Renaming a contact on a phone
  /// silently stopped the laptop deleting anything in that conversation.
  test('a mirrored alias edit leaves the disappearing window alone', () async {
    final me = _id(1), peer = _id(2);
    final storage = await _openStorage();
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final svc = MessagingService(_Noop(me), storage)..start();
    addTearDown(svc.dispose);

    await svc.setContactDisappearing(peer, 3600);
    await svc.setContactHideAfterRead(peer, 300);
    final set = (await storage.getContact(peer))!;
    expect(set.disappearingTtlSeconds, 3600);
    expect(set.hideAfterReadSeconds, 300);
    expect(set.disappearingSetAtMs, greaterThan(0));

    // An event from a build that never carried the policy: no keys, so
    // nothing to say about it. Silence is not "off".
    await svc.applyMirroredContact(
      peer: peer,
      name: 'renamed elsewhere',
      pinned: true,
      archived: false,
      allowPeerDelete: true,
    );
    final after = (await storage.getContact(peer))!;
    expect(after.name, 'renamed elsewhere', reason: 'the edit still lands');
    expect(after.pinned, isTrue);
    expect(
      after.disappearingTtlSeconds,
      3600,
      reason: 'an unrelated mirror must not switch the window off',
    );
    expect(after.hideAfterReadSeconds, 300);
    expect(after.disappearingSetAtMs, set.disappearingSetAtMs);
    expect(after.disappearingSetBy, set.disappearingSetBy);
  });

  /// The wire half of the same finding: a policy that never leaves the device
  /// cannot converge anywhere, however carefully the receiver merges it.
  test('the prefs payload carries every field it promises', () async {
    final c = Contact(
      nodeId: _id(2),
      name: 'Alice',
      status: ContactStatus.accepted,
      mutedUntil: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      notificationMuteMode: NotificationMuteMode.mentionsOnly,
      pinned: true,
      archived: true,
      retentionDays: 30,
      disappearingTtlSeconds: 3600,
      disappearingSetAtMs: 1700000000123,
      disappearingSetBy: 'bb',
      hideAfterReadSeconds: 300,
      allowPeerDelete: false,
    );

    final payload = contactPrefsPayload(c);
    expect(payload['name'], 'Alice');
    expect(payload['mutedMs'], 1700000000000);
    expect(payload['muteMode'], NotificationMuteMode.mentionsOnly.name);
    expect(payload['pin'], isTrue);
    expect(payload['arc'], isTrue);
    expect(payload['ret'], 30);
    expect(payload['apd'], isFalse);

    final policy = disappearingFromPayload(payload)!;
    expect(policy.ttlSeconds, 3600);
    expect(policy.hideAfterReadSeconds, 300);
    expect(
      policy.setAtMs,
      1700000000123,
      reason: 'the stamp travels, or the sibling cannot order two views',
    );
    expect(policy.setBy, 'bb', reason: 'the setter breaks an exact tie');

    // An event from before the policy travelled says nothing about it, and
    // nothing is not "off".
    expect(disappearingFromPayload(const {'name': 'x'}), isNull);
  });

  /// Convergence, and which way it goes. A sibling that has been offline holds
  /// an older view; its edit must not roll the window back, and a genuinely
  /// newer choice must win — the same last-writer-wins rule a peer's own
  /// announcement goes through, so both devices land on one answer whichever
  /// order the events arrive in.
  test('a sibling policy wins only when it is newer', () async {
    final me = _id(1), peer = _id(2);
    final storage = await _openStorage();
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final svc = MessagingService(_Noop(me), storage)..start();
    addTearDown(svc.dispose);

    await svc.setContactDisappearing(peer, 3600);
    final stamp = (await storage.getContact(peer))!.disappearingSetAtMs;

    // Stale: an older stamp, whatever it claims.
    await svc.applyMirroredContact(
      peer: peer,
      pinned: false,
      archived: false,
      allowPeerDelete: true,
      disappearing: DisappearingSetting(
        ttlSeconds: null,
        setAtMs: stamp - 1000,
        setBy: 'aa',
      ),
    );
    expect(
      (await storage.getContact(peer))!.disappearingTtlSeconds,
      3600,
      reason: 'an older view does not roll the window back',
    );

    // Newer: the other device really did change it, including to off.
    await svc.applyMirroredContact(
      peer: peer,
      pinned: false,
      archived: false,
      allowPeerDelete: true,
      disappearing: DisappearingSetting(
        ttlSeconds: null,
        setAtMs: stamp + 1000,
        setBy: 'aa',
      ),
    );
    final off = (await storage.getContact(peer))!;
    expect(
      off.disappearingTtlSeconds,
      isNull,
      reason: 'turning it off IS an act, and a newer one wins',
    );
    expect(off.disappearingSetAtMs, stamp + 1000);
  });

  test('settings hub: local sets pass through, applyIncoming is echo-proof, '
      'unregistered keys are refused', () async {
    final hub = DeviceSettingsSyncHub();
    final sent = <(String, String)>[];
    hub.onLocalSet = (k, v) => sent.add((k, v));

    // A registered applier that itself calls notifyLocalSet — exactly what a
    // real controller's set() does. The _applying guard must swallow it.
    final applied = <String>[];
    hub.register(kSyncShowReactions, (v) async {
      applied.add(v);
      hub.notifyLocalSet(kSyncShowReactions, v);
    });

    hub.notifyLocalSet(kSyncShowReactions, '0');
    expect(sent, [(kSyncShowReactions, '0')]);

    expect(await hub.applyIncoming(kSyncShowReactions, '1'), isTrue);
    expect(applied, ['1']);
    expect(sent.length, 1, reason: 'an applied value must not echo back');

    expect(
      await hub.applyIncoming('close_to_tray', '1'),
      isFalse,
      reason: 'platform-local keys are not allowlisted',
    );
  });

  test('call journal: idempotent by id, capped, newest first; the tap fires '
      'for local rows only', () async {
    final storage = await _openStorage();
    final store = CallLogStore(storage);
    final tapped = <String>[];
    store.onAdded = (e) => tapped.add(e.id);

    CallLogEntry entry(String id, int atMs) => CallLogEntry(
      id: id,
      peerHex: 'aa',
      outgoing: true,
      video: false,
      outcome: CallLogOutcome.completed,
      atMs: atMs,
      durationSec: 5,
    );

    expect(await store.add(entry('c1', 1000)), isTrue);
    expect(await store.add(entry('c1', 1000)), isFalse, reason: 'dedupe by id');
    expect(await store.addMirrored(entry('c2', 2000)), isTrue);
    expect(await store.addMirrored(entry('c2', 2000)), isFalse);
    expect(tapped, ['c1'], reason: 'mirrored rows never fire the tap');

    final list = await store.list();
    expect([for (final e in list) e.id], ['c2', 'c1'], reason: 'newest first');

    // Cap: overfill and check the oldest rows fall off.
    for (var i = 0; i < kCallLogCap + 10; i++) {
      await store.addMirrored(entry('x$i', 10000 + i));
    }
    final capped = await store.list();
    expect(capped.length, kCallLogCap);
    expect(
      capped.any((e) => e.id == 'c1'),
      isFalse,
      reason: 'the oldest row was evicted',
    );
    expect(capped.first.id, 'x${kCallLogCap + 9}');
  });

  test('callLogOutcomeFor maps terminal snapshots to journal outcomes', () {
    CallLogOutcome f({
      required bool out,
      required bool conn,
      required CallEndReason r,
    }) => callLogOutcomeFor(outgoing: out, connected: conn, reason: r);

    expect(
      f(out: true, conn: true, r: CallEndReason.hangup),
      CallLogOutcome.completed,
    );
    expect(
      f(out: false, conn: false, r: CallEndReason.declined),
      CallLogOutcome.declined,
    );
    expect(
      f(out: true, conn: false, r: CallEndReason.busy),
      CallLogOutcome.busy,
    );
    expect(
      f(out: true, conn: false, r: CallEndReason.cancelled),
      CallLogOutcome.cancelled,
    );
    expect(
      f(out: false, conn: false, r: CallEndReason.cancelled),
      CallLogOutcome.missed,
      reason: 'caller cancelled while we rang = missed',
    );
    expect(
      f(out: false, conn: false, r: CallEndReason.timeout),
      CallLogOutcome.missed,
    );
    expect(
      f(out: true, conn: false, r: CallEndReason.error),
      CallLogOutcome.failed,
    );

    // Codec round-trip incl. unknown-outcome refusal.
    final e = CallLogEntry(
      id: 'z',
      peerHex: 'bb',
      outgoing: false,
      video: true,
      outcome: CallLogOutcome.missed,
      atMs: 42,
    );
    final back = CallLogEntry.fromJson(e.toJson())!;
    expect(back.id, 'z');
    expect(back.video, isTrue);
    expect(back.outcome, CallLogOutcome.missed);
    expect(
      CallLogEntry.fromJson({...e.toJson(), 'o': 'teleported'}),
      isNull,
      reason: 'newer vocabulary is skipped, not guessed',
    );
  });

  test('live apply guard ranks same-millisecond events exactly like the fold '
      '(regression: a bare ts>= guard dropped the second of two edits landing '
      'in one millisecond)', () {
    DeviceSyncEvent ev(bool pin) => DeviceSyncEvent(
      kind: DeviceSyncKind.contactUp,
      key: 'aa',
      tsMs: 1000, // the SAME millisecond — the device-verify repro
      payload: {'name': 'x', 'pin': pin},
    );
    final first = ev(false), second = ev(true);
    final foldWinner = foldDeviceSync([
      first,
      second,
    ])[(DeviceSyncKind.contactUp, 'aa')]!;
    // Whatever the fold picks, the live comparison must agree from both sides.
    final liveSecondBeatsFirst = isNewerDeviceSync(second, first);
    expect(liveSecondBeatsFirst, foldWinner.payload['pin'] == true);
    expect(
      isNewerDeviceSync(first, second),
      !liveSecondBeatsFirst,
      reason: 'the order is total: exactly one side wins a tie',
    );
    // And a strictly newer timestamp always wins regardless of payload.
    final newer = DeviceSyncEvent(
      kind: DeviceSyncKind.contactUp,
      key: 'aa',
      tsMs: 1001,
      payload: {'name': 'a', 'pin': false},
    );
    expect(isNewerDeviceSync(newer, second), isTrue);
  });

  test(
    'contact-list sync (brick 4d): status transitions fire the tap; a '
    'mirrored status CREATES a missing contact and preserves other fields',
    () async {
      final me = _id(1), peer = _id(2), stranger = _id(7);
      final storage = await _openStorage();
      await storage.upsertContact(
        Contact(nodeId: peer, name: 'Алиса', status: ContactStatus.accepted),
      );
      final svc = MessagingService(_Noop(me), storage)..start();
      addTearDown(svc.dispose);

      final statusTaps = <(NodeId, ContactStatus)>[];
      svc.onContactStatusChanged = (p, s) => statusTaps.add((p, s));

      // Local block funnels through _setStatus → the tap fires.
      await svc.blockContact(peer);
      expect(statusTaps, [(peer, ContactStatus.blocked)]);

      // Mirrored status for an UNKNOWN peer creates the record — this is what
      // materializes the contact list on a fresh device.
      expect(
        await svc.applyMirroredContactStatus(stranger, ContactStatus.accepted),
        isTrue,
      );
      expect(
        (await storage.getContact(stranger))!.status,
        ContactStatus.accepted,
      );
      expect(statusTaps, hasLength(1), reason: 'apply must not echo');

      // Mirrored unblock of the known peer preserves its other fields…
      expect(
        await svc.applyMirroredContactStatus(peer, ContactStatus.accepted),
        isTrue,
      );
      final c = (await storage.getContact(peer))!;
      expect(c.status, ContactStatus.accepted);
      expect(c.name, 'Алиса');
      // …and an identical status is a no-op (idempotent on re-delivery).
      expect(
        await svc.applyMirroredContactStatus(peer, ContactStatus.accepted),
        isFalse,
      );
    },
  );

  test(
    'readMark (brick 4c): local markRead fires the tap with the advanced '
    'watermark; a mirrored mark applies monotonically and never echoes',
    () async {
      final me = _id(1), peer = _id(2);
      final storage = await _openStorage();
      await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted),
      );
      final svc = MessagingService(_Noop(me), storage)..start();
      addTearDown(svc.dispose);

      final taps = <(String, int)>[];
      svc.onConversationRead = (c, ts) => taps.add((c, ts));

      await svc.sendText(peer, 'hello');
      await svc.markRead(peer.hex);
      expect(taps, hasLength(1));
      expect(taps.single.$1, peer.hex);
      final localMark = taps.single.$2;
      expect(localMark, greaterThan(0));
      expect(await storage.readMarker(peer.hex), localMark);

      // A NEWER mirrored mark advances the watermark — without firing the tap.
      expect(
        await svc.applyMirroredReadMark(peer.hex, localMark + 5000),
        isTrue,
      );
      expect(await storage.readMarker(peer.hex), localMark + 5000);
      expect(taps, hasLength(1), reason: 'apply must not echo into the tap');

      // An OLDER mirrored mark never regresses what this device already read.
      expect(await svc.applyMirroredReadMark(peer.hex, localMark), isFalse);
      expect(await storage.readMarker(peer.hex), localMark + 5000);
    },
  );

  test('file mirror applies OFFER-shaped (brick 4b): fileContentId + meta, '
      'no bytes, idempotent, and deniability still holds', () async {
    final me = _id(1), peer = _id(2);
    final storage = await _openStorage();
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    final svc = MessagingService(_Noop(me), storage)..start();
    addTearDown(svc.dispose);

    expect(
      await svc.applyMirroredMessage(
        peer: peer,
        msgId: 'fm1',
        direction: MessageDirection.outgoing,
        body: '📎 report.pdf',
        tsMs: 7000,
        fileContentId: 'cafe01',
        fileName: 'report.pdf',
        fileSize: 12345,
        thumb: 'dGh1bWI=',
      ),
      isTrue,
    );
    final rows = await storage.loadMessages(peer.hex);
    final m = rows.singleWhere((x) => x.id == 'fm1');
    expect(m.fileContentId, 'cafe01');
    expect(m.fileId, isNull, reason: 'no bytes yet — offer-shaped');
    expect(m.fileName, 'report.pdf');
    expect(m.fileSize, 12345);
    expect(m.thumb, 'dGh1bWI=');
    expect(m.isFile, isTrue);

    // Idempotent on re-delivery.
    expect(
      await svc.applyMirroredMessage(
        peer: peer,
        msgId: 'fm1',
        direction: MessageDirection.outgoing,
        body: '📎 report.pdf',
        tsMs: 7000,
        fileContentId: 'cafe01',
      ),
      isFalse,
    );
    expect(
      (await storage.loadMessages(peer.hex)).where((x) => x.id == 'fm1').length,
      1,
    );
  });

  test('a MIRRORED message stamped past the tolerated skew is stored at the '
      'moment it arrived, once — a boot re-drive never restamps it', () async {
    final me = _id(1), peer = _id(2);
    final storage = await _openStorage();
    await storage.upsertContact(
      Contact(nodeId: peer, status: ContactStatus.accepted),
    );
    var wall = DateTime.utc(2026, 8, 3, 12);
    final arrivedAt = wall.millisecondsSinceEpoch;
    final svc = MessagingService(_Noop(me), storage, now: () => wall)..start();
    addTearDown(svc.dispose);

    Future<int> tsOf(String id) async => (await storage.loadMessages(
      peer.hex,
    )).firstWhere((m) => m.id == id).timestamp.millisecondsSinceEpoch;

    // A sibling honestly a few minutes fast is believed to the millisecond, so
    // ordinary mirrored traffic keeps the send order it was mirrored under.
    final honest = arrivedAt + kMessageClockSkew.inMilliseconds;
    expect(
      await svc.applyMirroredMessage(
        peer: peer,
        msgId: 'ok-1',
        direction: MessageDirection.incoming,
        body: 'nearly now',
        tsMs: honest,
      ),
      isTrue,
    );
    expect(await tsOf('ok-1'), honest);

    // One-sided: a device back from a week offline receives last Tuesday's
    // mirror and keeps last Tuesday.
    final lastWeek = arrivedAt - const Duration(days: 7).inMilliseconds;
    expect(
      await svc.applyMirroredMessage(
        peer: peer,
        msgId: 'old-1',
        direction: MessageDirection.incoming,
        body: 'last tuesday',
        tsMs: lastWeek,
      ),
      isTrue,
    );
    expect(await tsOf('old-1'), lastWeek);

    // A compromised sibling mirrors a row stamped a year ahead. This path needs
    // the bound MORE than the wire path does: a mirrored row is stored with no
    // author and no seq, so loadMessages' author-monotone effective-ts floor
    // never sees it and its raw stamp is its display time, forever.
    final hostile = arrivedAt + const Duration(days: 365).inMilliseconds;
    expect(
      await svc.applyMirroredMessage(
        peer: peer,
        msgId: 'fut-1',
        direction: MessageDirection.incoming,
        body: 'from the future',
        tsMs: hostile,
      ),
      isTrue,
    );
    expect(
      await tsOf('fut-1'),
      arrivedAt,
      reason: 'not a time — stored as the moment of receipt',
    );

    // ONCE. nudgeDeviceSync re-ships the FULL device-group snapshot on every
    // boot, so this exact event is offered again and again against a clock that
    // has moved on. The stamp must not move with it.
    wall = wall.add(const Duration(hours: 5));
    expect(
      await svc.applyMirroredMessage(
        peer: peer,
        msgId: 'fut-1',
        direction: MessageDirection.incoming,
        body: 'from the future',
        tsMs: hostile,
      ),
      isFalse,
      reason: 'already present — idempotent',
    );
    expect(
      await tsOf('fut-1'),
      arrivedAt,
      reason: 'stamped once on arrival; a re-drive must not restamp it',
    );

    // The visible consequence: the conversation is no longer pinned to the top
    // of the chat list (loadConversations ranks on the raw stored timestamp).
    final conv = (await storage.loadConversations()).firstWhere(
      (c) => c.peer.nodeId.hex == peer.hex,
    );
    expect(
      conv.lastMessage!.timestamp.millisecondsSinceEpoch,
      lessThanOrEqualTo(arrivedAt + kMessageClockSkew.inMilliseconds),
    );
  });
}
