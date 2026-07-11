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

/// Peer-visible delete (user decision 2026-07-11): deleting a chat stays a
/// silent local wipe by DEFAULT; the explicit `notifyPeer` opt-in sends a
/// [WireKind.chatDeleted] farewell that leaves a system-notice marker in the
/// peer's chat. The no-oracle canon holds everywhere else: nothing is sent to
/// non-accepted peers, and a crafted farewell from a stranger is dropped.
NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

class _FakeTransport implements VeilTransport {
  _FakeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _FakeTransport? peer;

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
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    peer?._inbound.add(InboundMessage(src: _me, payload: payload));
  }

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

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

Uint8List _farewell(String fid) =>
    const WireEnvelope(WireKind.chatDeleted, '').withFrameId(fid).encode();

void main() {
  late NodeId a, b;
  late _FakeTransport tA, tB;
  late HiddenVolumeStorage sA, sB;
  late MessagingService mA, mB;

  setUp(() async {
    a = _id(1);
    b = _id(2);
    tA = _FakeTransport(a);
    tB = _FakeTransport(b);
    tA.peer = tB;
    tB.peer = tA;
    sA = HiddenVolumeStorage(_memOpener());
    sB = HiddenVolumeStorage(_memOpener());
    await sA.open(password: 'a', createIfMissing: true);
    await sB.open(password: 'b', createIfMissing: true);
    mA = MessagingService(tA, sA)..start();
    mB = MessagingService(tB, sB)..start();
  });

  Future<void> befriend() async {
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
  }

  test('opt-in delete leaves a marker at the peer and wipes locally',
      () async {
    await befriend();
    for (final t in ['one', 'two', 'three']) {
      await mA.sendText(b, t);
      await _pump();
    }
    // B locally deletes a MIDDLE message: A's seq stream at B now has a gap.
    // A peer-authored marker would be allocated exactly that gap-free seq and
    // sort into the MIDDLE of the chat (caught twice in device-verify) — the
    // marker must be self-authored to close the chat regardless of gaps.
    final two =
        (await sB.loadMessages(a.hex)).firstWhere((m) => m.body == 'two');
    await mB.deleteMessageLocally(two.id);

    await mA.deleteConversation(b, notifyPeer: true);
    await _pump();

    // A wiped everything locally.
    expect(await sA.getContact(b), isNull);
    expect(await sA.loadMessages(b.hex), isEmpty);

    // B keeps its chat and got the incoming system marker.
    final all = await sB.loadMessages(a.hex);
    final markers = all.where((m) => isChatDeletedMarker(m.body)).toList();
    expect(markers, hasLength(1));
    expect(markers.single.direction, MessageDirection.incoming);
    expect(markers.single.author, b.hex,
        reason: 'a local annotation lives in OUR OWN event stream');
    // Send-time stamp + off the peer's seq stream ⇒ the marker CLOSES the
    // chat (an unstamped/peer-authored one sorted into the middle).
    expect(isChatDeletedMarker(all.last.body), isTrue,
        reason: 'the marker must be the final entry of the conversation');
  });

  test('the DEFAULT delete stays silent (no marker, canon intact)', () async {
    await befriend();
    await mA.sendText(b, 'bye');
    await _pump();

    await mA.deleteConversation(b);
    await _pump();

    expect(await sA.getContact(b), isNull);
    expect(
      (await sB.loadMessages(a.hex)).any((m) => isChatDeletedMarker(m.body)),
      isFalse,
      reason: 'without the opt-in nothing goes on the wire',
    );
  });

  test('notify to a not-yet-accepted peer sends NOTHING (no oracle)',
      () async {
    await mA.sendRequest(b, 'hi');
    await _pump(); // B: pendingIncoming with the intro only

    await mA.deleteConversation(b, notifyPeer: true);
    await _pump();

    expect(
      (await sB.loadMessages(a.hex)).any((m) => isChatDeletedMarker(m.body)),
      isFalse,
      reason: 'the farewell is gated on an accepted contact',
    );
  });

  test('a crafted farewell from a stranger is silently dropped', () async {
    await tA.send(b, _farewell('chatdel:forged'));
    await _pump();

    expect(await sB.getContact(a), isNull);
    expect(await sB.loadMessages(a.hex), isEmpty);
  });

  test('a re-delivered farewell (same frame id) stores exactly one marker',
      () async {
    await befriend();
    await tA.send(b, _farewell('chatdel:once'));
    await _pump();
    await tA.send(b, _farewell('chatdel:once'));
    await _pump();

    expect(
      (await sB.loadMessages(a.hex))
          .where((m) => isChatDeletedMarker(m.body))
          .length,
      1,
      reason: 'the generic durable-frame gate dedups the re-drive',
    );
  });

  test('marker helper matches only the exact token', () {
    expect(isChatDeletedMarker(kChatDeletedMarkerBody), isTrue);
    expect(isChatDeletedMarker('sys:chat-deleted '), isFalse);
    expect(isChatDeletedMarker('hello'), isFalse);
    expect(isChatDeletedMarker(''), isFalse);
  });
}
