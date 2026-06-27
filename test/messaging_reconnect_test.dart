import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// A link whose live send can be dropped, and which can inject inbound frames.
class _Link implements VeilTransport {
  _Link(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _Link? peer;
  bool drop = false;

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _inbound.stream;
  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload, anonymous: true);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Future<void> send(NodeId dst, Uint8List payload,
      {bool anonymous = false}) async {
    if (drop) return;
    peer?._inbound.add(InboundMessage(src: _me, payload: payload));
  }

  void inject(NodeId from, Uint8List payload) =>
      _inbound.add(InboundMessage(src: from, payload: payload));

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

void main() {
  test('a reconnect from a peer that FORGOT us surfaces as a pending intro '
      '(Case-A re-establish)', () async {
    final a = _id(1), b = _id(2);
    final tB = _Link(b);
    final sB = HiddenVolumeStorage(_memOpener());
    await sB.open(password: 'b', createIfMissing: true);
    final mB = MessagingService(tB, sB)..start();
    addTearDown(mB.dispose);

    // B has NO record of A (B wiped its chat data). A's plain message would be
    // dropped by the consent gate — but a reconnect re-intros A.
    expect(await sB.getContact(a), isNull);
    tB.inject(a, const WireEnvelope.reconnect('').encode());
    await _settle();

    final contact = await sB.getContact(a);
    expect(contact, isNotNull, reason: 'reconnect created a contact');
    expect(contact!.status, ContactStatus.pendingIncoming,
        reason: 'surfaced as a pending re-intro the user can accept');
  });

  test('a reconnect from a BLOCKED peer is dropped silently (no oracle)',
      () async {
    final a = _id(1), b = _id(2);
    final tB = _Link(b);
    final sB = HiddenVolumeStorage(_memOpener());
    await sB.open(password: 'b', createIfMissing: true);
    await sB.upsertContact(Contact(nodeId: a, status: ContactStatus.blocked));
    final mB = MessagingService(tB, sB)..start();
    addTearDown(mB.dispose);

    tB.inject(a, const WireEnvelope.reconnect('').encode());
    await _settle();

    // Stays blocked — no pending intro, no state change (no "you're blocked" leak).
    expect((await sB.getContact(a))!.status, ContactStatus.blocked);
  });

  test('a message un-acked past the bound flips to "not delivered" (failed) '
      'and stops retrying', () async {
    final a = _id(1), b = _id(2);
    var clock = DateTime(2026, 1, 1, 12);
    final tA = _Link(a);
    final sA = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    // A holds B as an accepted contact, but every send to B is lost (B never
    // acks) — models a peer that wiped us / went away for good.
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    final mA = MessagingService(tA, sA, now: () => clock)..start();
    addTearDown(mA.dispose);
    tA.drop = true; // nothing reaches B → no ack ever

    await mA.sendText(b, 'are you there?');
    await _settle();
    final id = (await sA.loadMessages(b.hex)).single.id;
    expect((await sA.loadMessages(b.hex)).single.status, MessageStatus.sent);

    // Drive the bounded reconnect: each flush past the interval re-intros; once
    // THIS message's own age passes the give-up window (90min) it terminates at
    // failed. 8 × 16min = 128min comfortably exceeds it.
    for (var i = 0; i < 8; i++) {
      clock = clock.add(const Duration(minutes: 16));
      await mA.flushOutbox();
      await _settle();
    }

    expect((await sA.loadMessages(b.hex)).single.status, MessageStatus.failed,
        reason: 'gave up after the per-message bound → not delivered');
  });

  test('a steady drip of NEW sends to a dead peer does NOT keep an old '
      'undelivered message alive forever (give-up is per-message age)', () async {
    final a = _id(1), b = _id(2);
    var clock = DateTime(2026, 1, 1, 12);
    final tA = _Link(a);
    final sA = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    final mA = MessagingService(tA, sA, now: () => clock)..start();
    addTearDown(mA.dispose);
    tA.drop = true; // B never acks

    await mA.sendText(b, 'the FIRST message (must eventually fail)');
    await _settle();
    final firstId = (await sA.loadMessages(b.hex)).single.id;

    // Keep sending fresh messages every 16 min — under a shared per-peer counter
    // this would reset the budget forever and `firstId` would never terminate.
    for (var i = 0; i < 8; i++) {
      clock = clock.add(const Duration(minutes: 16));
      await mA.sendText(b, 'drip $i');
      await mA.flushOutbox();
      await _settle();
    }

    final msgs = await sA.loadMessages(b.hex);
    final first = msgs.firstWhere((m) => m.id == firstId);
    expect(first.status, MessageStatus.failed,
        reason: 'the old message gave up on its OWN age despite newer sends');
    // A just-sent message is still within its own window → not falsely failed.
    expect(msgs.last.status, MessageStatus.sent,
        reason: 'a fresh send is not dragged down by the old failure');
  });

  test('an ack before the bound resets the reconnect cycle (no false failure)',
      () async {
    final a = _id(1), b = _id(2);
    var clock = DateTime(2026, 1, 1, 12);
    final tA = _Link(a);
    final sA = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    await sA.upsertContact(Contact(nodeId: b, status: ContactStatus.accepted));
    final mA = MessagingService(tA, sA, now: () => clock)..start();
    addTearDown(mA.dispose);
    tA.drop = true;

    await mA.sendText(b, 'hi');
    await _settle();
    final id = (await sA.loadMessages(b.hex)).single.id;

    // A few reconnect attempts...
    for (var i = 0; i < 3; i++) {
      clock = clock.add(const Duration(minutes: 16));
      await mA.flushOutbox();
      await _settle();
    }
    // ...then the peer acks (reachable again): inject the ack from B.
    tA.inject(b, WireEnvelope.ack(id).encode());
    await _settle();
    expect((await sA.loadMessages(b.hex)).single.status,
        MessageStatus.delivered);

    // Even far past where the old cycle would have failed, it stays delivered.
    for (var i = 0; i < 8; i++) {
      clock = clock.add(const Duration(minutes: 16));
      await mA.flushOutbox();
      await _settle();
    }
    expect((await sA.loadMessages(b.hex)).single.status,
        MessageStatus.delivered);
  });
}
