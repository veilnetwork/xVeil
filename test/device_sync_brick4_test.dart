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
  Future<void> send(NodeId dst, Uint8List payload,
      {bool anonymous = false}) async {}
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
  test('contact pref setters fire onContactPrefsChanged with the fresh record; '
      'applyMirroredContact writes silently and keeps local-only fields',
      () async {
    final me = _id(1), peer = _id(2);
    final storage = await _openStorage();
    await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted));
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
    expect(emitted.length, 2, reason: 'a mirrored contact must not re-mirror');
    final c = (await storage.getContact(peer))!;
    expect(c.name, 'Алиса');
    expect(c.archived, isTrue);
    expect(c.pinned, isFalse);
    expect(c.retentionDays, 7);
    expect(c.allowPeerDelete, isFalse);
    expect(c.status, ContactStatus.accepted, reason: 'status is local-only');
    expect(c.p2pOverride, ContactP2POverride.allow,
        reason: 'p2pOverride is local-only');

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

    expect(await hub.applyIncoming('close_to_tray', '1'), isFalse,
        reason: 'platform-local keys are not allowlisted');
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
    expect([for (final e in list) e.id], ['c2', 'c1'],
        reason: 'newest first');

    // Cap: overfill and check the oldest rows fall off.
    for (var i = 0; i < kCallLogCap + 10; i++) {
      await store.addMirrored(entry('x$i', 10000 + i));
    }
    final capped = await store.list();
    expect(capped.length, kCallLogCap);
    expect(capped.any((e) => e.id == 'c1'), isFalse,
        reason: 'the oldest row was evicted');
    expect(capped.first.id, 'x${kCallLogCap + 9}');
  });

  test('callLogOutcomeFor maps terminal snapshots to journal outcomes', () {
    CallLogOutcome f({
      required bool out,
      required bool conn,
      required CallEndReason r,
    }) =>
        callLogOutcomeFor(outgoing: out, connected: conn, reason: r);

    expect(f(out: true, conn: true, r: CallEndReason.hangup),
        CallLogOutcome.completed);
    expect(f(out: false, conn: false, r: CallEndReason.declined),
        CallLogOutcome.declined);
    expect(f(out: true, conn: false, r: CallEndReason.busy),
        CallLogOutcome.busy);
    expect(f(out: true, conn: false, r: CallEndReason.cancelled),
        CallLogOutcome.cancelled);
    expect(f(out: false, conn: false, r: CallEndReason.cancelled),
        CallLogOutcome.missed,
        reason: 'caller cancelled while we rang = missed');
    expect(f(out: false, conn: false, r: CallEndReason.timeout),
        CallLogOutcome.missed);
    expect(f(out: true, conn: false, r: CallEndReason.error),
        CallLogOutcome.failed);

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
    expect(CallLogEntry.fromJson({...e.toJson(), 'o': 'teleported'}), isNull,
        reason: 'newer vocabulary is skipped, not guessed');
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
    final foldWinner =
        foldDeviceSync([first, second])[(DeviceSyncKind.contactUp, 'aa')]!;
    // Whatever the fold picks, the live comparison must agree from both sides.
    final liveSecondBeatsFirst = isNewerDeviceSync(second, first);
    expect(liveSecondBeatsFirst, foldWinner.payload['pin'] == true);
    expect(isNewerDeviceSync(first, second), !liveSecondBeatsFirst,
        reason: 'the order is total: exactly one side wins a tie');
    // And a strictly newer timestamp always wins regardless of payload.
    final newer = DeviceSyncEvent(
      kind: DeviceSyncKind.contactUp,
      key: 'aa',
      tsMs: 1001,
      payload: {'name': 'a', 'pin': false},
    );
    expect(isNewerDeviceSync(newer, second), isTrue);
  });

  test('readMark (brick 4c): local markRead fires the tap with the advanced '
      'watermark; a mirrored mark applies monotonically and never echoes',
      () async {
    final me = _id(1), peer = _id(2);
    final storage = await _openStorage();
    await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted));
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
    expect(await svc.applyMirroredReadMark(peer.hex, localMark + 5000), isTrue);
    expect(await storage.readMarker(peer.hex), localMark + 5000);
    expect(taps, hasLength(1), reason: 'apply must not echo into the tap');

    // An OLDER mirrored mark never regresses what this device already read.
    expect(await svc.applyMirroredReadMark(peer.hex, localMark), isFalse);
    expect(await storage.readMarker(peer.hex), localMark + 5000);
  });

  test('file mirror applies OFFER-shaped (brick 4b): fileContentId + meta, '
      'no bytes, idempotent, and deniability still holds', () async {
    final me = _id(1), peer = _id(2);
    final storage = await _openStorage();
    await storage.upsertContact(
        Contact(nodeId: peer, status: ContactStatus.accepted));
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
        isTrue);
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
        isFalse);
    expect((await storage.loadMessages(peer.hex))
        .where((x) => x.id == 'fm1').length, 1);
  });
}
