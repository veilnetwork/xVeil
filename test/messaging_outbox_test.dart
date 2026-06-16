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

/// Direct 1:1 fake link with an [online] switch: while offline, send() drops
/// the datagram (simulating the node being disconnected), so the local outbox
/// can be exercised across an offline window.
class _FakeTransport implements VeilTransport {
  _FakeTransport(this._me);
  final NodeId _me;
  final _inbound = StreamController<InboundMessage>.broadcast();
  _FakeTransport? peer;
  bool online = true;

  @override
  Future<NodeId> nodeId() async => _me;
  @override
  Stream<InboundMessage> messages() => _inbound.stream;
  @override
  Future<void> send(NodeId dst, Uint8List payload) async {
    if (!online) return; // disconnected — drop
    peer?._inbound.add(InboundMessage(src: _me, payload: payload));
  }

  @override
  Future<void> dispose() async => _inbound.close();
}

SpaceOpener _memOpener() {
  final store = FakeKvLogStore();
  return ({required password, required bool create}) => store;
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

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
    // Establish a mutually-accepted contact so free messaging is allowed.
    await mA.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(a);
    await _pump();
  });

  Future<Message> aMsg(String body) async =>
      (await sA.loadMessages(b.hex)).firstWhere((m) => m.body == body);

  test('full conversation flow: send -> edit -> delete-for-everyone -> flush '
      'converges on both sides with no resurrection', () async {
    // 1. A sends; B receives.
    await mA.sendText(b, 'meet at noon');
    await _pump();
    final id = (await aMsg('meet at noon')).id;
    expect((await sB.loadMessages(a.hex)).any((m) => m.body == 'meet at noon'),
        isTrue);

    // 2. A edits its own message; B's copy updates in place (same id).
    await mA.editOwnMessage(id, 'meet at one');
    await _pump();
    expect((await sA.loadMessages(b.hex)).firstWhere((m) => m.id == id).body,
        'meet at one');
    final bEdited = (await sB.loadMessages(a.hex)).where((m) => m.id == id);
    expect(bEdited.length, 1, reason: 'edit replaces, never duplicates');
    expect(bEdited.first.body, 'meet at one');

    // 3. A deletes it for everyone; it is erased on BOTH sides.
    await mA.deleteForEveryone(id);
    await _pump();
    expect((await sA.loadMessages(b.hex)).any((m) => m.id == id), isFalse);
    expect((await sB.loadMessages(a.hex)).any((m) => m.id == id), isFalse);

    // 4. An outbox flush after the delete must not resurrect it on either side
    //    (the message is tombstoned, so it is neither re-sent nor re-stored).
    await mA.flushOutbox();
    await _pump();
    expect((await sA.loadMessages(b.hex)).any((m) => m.id == id), isFalse);
    expect((await sB.loadMessages(a.hex)).any((m) => m.id == id), isFalse,
        reason: 'deleted message stays gone across the full flow');
  });

  test('deleting a file message erases its blob, not just the chat row '
      '(deniability)', () async {
    await mA.sendFile(b, Uint8List.fromList([9, 8, 7, 6, 5]), 'secret.bin');
    await _pump();
    final fileMsg = (await sB.loadMessages(a.hex)).firstWhere((m) => m.isFile);
    // The attachment blob is present on B.
    expect(await sB.loadFile(fileMsg.fileId!), isNotNull);

    // B deletes the file message. The blob must be purged too — an attachment
    // that lingers in the container after the row is gone is a deniability hole.
    await mB.deleteMessageLocally(fileMsg.id);
    expect((await sB.loadMessages(a.hex)).any((m) => m.isFile), isFalse);
    expect(await sB.loadFile(fileMsg.fileId!), isNull,
        reason: 'the file blob must be erased when its message is deleted');
  });

  test('the connection greeting is not duplicated on the recipient by a flush',
      () async {
    // setUp already ran A.sendRequest('hi') + B.acceptContact: B holds the
    // greeting once. The greeting is stored on A as an outgoing `sent` message
    // (the request flow never acks it), so A's outbox re-sends it as a message.
    // It must dedup against the copy B stored from the request — not duplicate.
    expect((await sB.loadMessages(a.hex)).where((m) => m.body == 'hi').length, 1);
    await mA.flushOutbox();
    await _pump();
    expect((await sB.loadMessages(a.hex)).where((m) => m.body == 'hi').length, 1,
        reason: 'greeting must dedup, not double via the outbox re-send');
  });

  test('a deleted message does not resurrect when the sender re-delivers it',
      () async {
    await mA.sendText(b, 'secret');
    await _pump();
    final id = (await aMsg('secret')).id; // wire id == stored id
    expect((await sB.loadMessages(a.hex)).where((m) => m.body == 'secret').length,
        1);

    // B erases it (deniable delete).
    final bMsg =
        (await sB.loadMessages(a.hex)).firstWhere((m) => m.body == 'secret');
    await mB.deleteMessageLocally(bMsg.id);
    expect((await sB.loadMessages(a.hex)).where((m) => m.body == 'secret').length,
        0);

    // The sender re-delivers the SAME id (an outbox retry that raced the
    // delete). Deniability core: deleted must stay deleted, never resurrect.
    await tA.send(b, WireEnvelope.message('secret', id: id).encode());
    await _pump();
    expect((await sB.loadMessages(a.hex)).where((m) => m.body == 'secret').length,
        0,
        reason: 'a deleted message must not resurrect on re-delivery');
  });

  test('a duplicate fileMeta does not reset an in-progress transfer', () async {
    const tid = 'transfer-1';
    Uint8List meta() =>
        fileMetaEnvelope(transferId: tid, name: 'f.bin', size: 2, count: 2)
            .encode();
    await tA.send(b, meta());
    await tA.send(
        b,
        fileChunkEnvelope(
                transferId: tid,
                index: 0,
                total: 2,
                data: Uint8List.fromList([10]))
            .encode());
    await tA.send(b, meta()); // DUPLICATE meta mid-transfer — must not reset
    await tA.send(
        b,
        fileChunkEnvelope(
                transferId: tid,
                index: 1,
                total: 2,
                data: Uint8List.fromList([20]))
            .encode());
    await _pump();
    // Both chunks survived the duplicate meta → the transfer completes + stores.
    expect(
        (await sB.loadMessages(a.hex))
            .any((m) => m.isFile && m.fileName == 'f.bin'),
        isTrue,
        reason: 'a duplicate meta must not discard already-received chunks');
  });

  test('a deleted file does not resurrect when the transfer is re-delivered',
      () async {
    const tid = 'file-xfer-1';
    Future<void> deliver() async {
      await tA.send(
          b,
          fileMetaEnvelope(transferId: tid, name: 'doc.bin', size: 3, count: 1)
              .encode());
      await tA.send(
          b,
          fileChunkEnvelope(
                  transferId: tid,
                  index: 0,
                  total: 1,
                  data: Uint8List.fromList([1, 2, 3]))
              .encode());
    }

    await deliver();
    await _pump();
    final fileMsg = (await sB.loadMessages(a.hex)).firstWhere((m) => m.isFile);
    await mB.deleteMessageLocally(fileMsg.id);
    expect((await sB.loadMessages(a.hex)).any((m) => m.isFile), isFalse);

    // Re-deliver the SAME transfer (a hostile re-send) — must stay deleted.
    await deliver();
    await _pump();
    expect((await sB.loadMessages(a.hex)).any((m) => m.isFile), isFalse,
        reason: 'a deleted file must not resurrect on re-delivery');
  });

  test('an edit for a deleted message does not resurrect it', () async {
    await mA.sendText(b, 'secret');
    await _pump();
    final bMsg =
        (await sB.loadMessages(a.hex)).firstWhere((m) => m.body == 'secret');
    await mB.deleteMessageLocally(bMsg.id);
    expect((await sB.loadMessages(a.hex)).where((m) => m.body == 'secret').length,
        0);

    // The sender edits the message the recipient deleted — the edit must NOT
    // bring it back (deniability: deleted stays deleted across every vector).
    await tA.send(b, WireEnvelope.edit(bMsg.id, 'secret v2').encode());
    await _pump();
    expect(
        (await sB.loadMessages(a.hex)).where((m) => m.body.startsWith('secret')),
        isEmpty,
        reason: 'an edit must not resurrect a deleted message');
  });

  test('an ack flips the sender message sent -> delivered', () async {
    await mA.sendText(b, 'hello');
    await _pump();
    expect((await sB.loadMessages(a.hex)).map((m) => m.body), contains('hello'));
    expect((await aMsg('hello')).status, MessageStatus.delivered);
  });

  test('a completed file transfer flips the sender file message to delivered',
      () async {
    await mA.sendFile(b, Uint8List.fromList([1, 2, 3, 4, 5]), 'doc.txt');
    await _pump();
    // B received + reassembled the file.
    expect(
        (await sB.loadMessages(a.hex))
            .any((m) => m.isFile && m.fileName == 'doc.txt'),
        isTrue);
    // A's file message must flip to delivered (B acks on completion), not stay
    // 'sent' forever like text without an ack.
    final fileMsg = (await sA.loadMessages(b.hex)).firstWhere((m) => m.isFile);
    expect(fileMsg.status, MessageStatus.delivered,
        reason: 'receiver must ack a completed file transfer');
  });

  test('message composed offline stays sent, then flush delivers it on reconnect',
      () async {
    tA.online = false; // A goes offline
    await mA.sendText(b, 'composed offline');
    await _pump();
    // Stored locally as un-acked, never reached B.
    expect((await aMsg('composed offline')).status, MessageStatus.sent);
    expect((await sB.loadMessages(a.hex)).any((m) => m.body == 'composed offline'),
        isFalse);

    tA.online = true; // reconnect
    await mA.flushOutbox();
    await _pump();
    expect((await sB.loadMessages(a.hex)).any((m) => m.body == 'composed offline'),
        isTrue);
    expect((await aMsg('composed offline')).status, MessageStatus.delivered);
  });

  test('re-sending an already-delivered message does not duplicate it', () async {
    await mA.sendText(b, 'hello');
    await _pump();
    final id = (await aMsg('hello')).id;

    // Sender's outbox re-sends the same id (e.g. it missed the first ack).
    await tA.send(b, WireEnvelope.message('hello', id: id).encode());
    await _pump();
    expect((await sB.loadMessages(a.hex)).where((m) => m.body == 'hello').length, 1);
  });

  test('flush is a no-op for already-delivered messages', () async {
    await mA.sendText(b, 'hello');
    await _pump();
    await mA.flushOutbox();
    await _pump();
    // No duplicate appeared on the receiver.
    expect((await sB.loadMessages(a.hex)).where((m) => m.body == 'hello').length, 1);
  });

  test('editOwnMessage replaces the text and marks it edited', () async {
    await mA.sendText(b, 'wrong');
    await _pump();
    final id = (await aMsg('wrong')).id;

    await mA.editOwnMessage(id, 'right');

    final msgs = await sA.loadMessages(b.hex);
    expect(msgs.where((m) => m.body == 'wrong'), isEmpty);
    final edited = msgs.firstWhere((m) => m.id == id);
    expect(edited.body, 'right');
    expect(edited.edited, isTrue);
  });

  test('editOwnMessage propagates the new text to the recipient', () async {
    await mA.sendText(b, 'teh meeting is at 5');
    await _pump();
    final id = (await aMsg('teh meeting is at 5')).id;

    await mA.editOwnMessage(id, 'the meeting is at 6');
    await _pump();

    final theirs = (await sB.loadMessages(a.hex)).firstWhere((m) => m.id == id);
    expect(theirs.body, 'the meeting is at 6');
    expect(theirs.edited, isTrue);
    expect((await sB.loadMessages(a.hex)).any((m) => m.body == 'teh meeting is at 5'),
        isFalse);
  });

  test('deleteForEveryone unsends from the recipient too', () async {
    await mA.sendText(b, 'oops wrong chat');
    await _pump();
    final id = (await aMsg('oops wrong chat')).id;

    await mA.deleteForEveryone(id);
    await _pump();

    expect((await sA.loadMessages(b.hex)).any((m) => m.id == id), isFalse);
    expect((await sB.loadMessages(a.hex)).any((m) => m.id == id), isFalse);
  });

  test('a peer cannot edit or delete OUR outgoing message (authz by direction)',
      () async {
    await mA.sendText(b, 'our statement');
    await _pump();
    final id = (await aMsg('our statement')).id;

    // B (an accepted peer) maliciously sends edit + del for A's OWN message id.
    await tB.send(a, WireEnvelope.edit(id, 'doctored').encode());
    await tB.send(a, WireEnvelope.del(id).encode());
    await _pump();

    final ours = await sA.loadMessages(b.hex);
    expect(ours.any((m) => m.id == id && m.body == 'our statement'), isTrue,
        reason: 'a peer must not rewrite or destroy our own sent message');
    expect(ours.any((m) => m.body == 'doctored'), isFalse);
  });

  test('deleteForEveryone is a no-op on a received message (can only unsend own)',
      () async {
    await mA.sendText(b, 'from A');
    await _pump();
    final received = (await sB.loadMessages(a.hex)).firstWhere((m) => m.body == 'from A');

    await mB.deleteForEveryone(received.id); // B did not send it
    await _pump();

    // Nothing removed on either side.
    expect((await sB.loadMessages(a.hex)).any((m) => m.id == received.id), isTrue);
    expect((await sA.loadMessages(b.hex)).any((m) => m.body == 'from A'), isTrue);
  });

  test('deleteMessageLocally on your OWN message is delete-for-me, not unsend',
      () async {
    await mA.sendText(b, 'oops');
    await _pump();
    final id = (await aMsg('oops')).id;

    // A deletes its own message for ITSELF only (not deleteForEveryone).
    await mA.deleteMessageLocally(id);
    await _pump();

    // A's copy is gone, but B STILL has it — delete-for-me never propagates
    // (contrast deleteForEveryone, which unsends the peer copy).
    expect((await sA.loadMessages(b.hex)).any((m) => m.id == id), isFalse);
    expect((await sB.loadMessages(a.hex)).any((m) => m.body == 'oops'), isTrue,
        reason: 'delete-for-me must not unsend the peer copy');
  });

  test('deleteMessageLocally purges a received message from this device',
      () async {
    await mA.sendText(b, 'sensitive');
    await _pump();
    final received =
        (await sB.loadMessages(a.hex)).firstWhere((m) => m.body == 'sensitive');

    await mB.deleteMessageLocally(received.id);

    expect((await sB.loadMessages(a.hex)).any((m) => m.body == 'sensitive'),
        isFalse);
    // The sender's own copy is untouched (local-only delete).
    expect((await sA.loadMessages(b.hex)).any((m) => m.body == 'sensitive'),
        isTrue);
  });
}
