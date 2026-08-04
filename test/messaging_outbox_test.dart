import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/transport/veil_mailbox.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/inline_custom_emoji.dart';
import 'package:xveil/state/mailbox_service.dart';
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
    if (!online) return; // disconnected — drop
    peer?._inbound.add(
      InboundMessage(
        src: _me,
        payload: payload,
        provenance: SenderProvenance.sessionPeer,
      ),
    );
  }

  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() async => _inbound.close();
}

class _BlockingMailboxSink implements MailboxSink {
  final _release = Completer<void>();
  int calls = 0;

  @override
  bool backgroundDrainPaused = false;

  @override
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) {
    calls++;
    return _release.future;
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  void nudgeDrain() {}

  @override
  void noteActivity() {}
}

/// Refuses every deposit the way a peer with no advertised mailbox does.
class _UnresolvedMailboxSink implements MailboxSink {
  int calls = 0;

  @override
  bool backgroundDrainPaused = false;

  @override
  Future<void> stash({
    required NodeId recipient,
    required Uint8List payload,
    required Uint8List contentId,
  }) async {
    calls++;
    throw const MailboxPeerUnresolved('no usable KEM key in this test');
  }

  @override
  void nudgeDrain() {}

  @override
  void noteActivity() {}
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
    expect(
      (await sB.loadMessages(a.hex)).any((m) => m.body == 'meet at noon'),
      isTrue,
    );

    // 2. A edits its own message; B's copy updates in place (same id).
    await mA.editOwnMessage(id, 'meet at one');
    await _pump();
    expect(
      (await sA.loadMessages(b.hex)).firstWhere((m) => m.id == id).body,
      'meet at one',
    );
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
    expect(
      (await sB.loadMessages(a.hex)).any((m) => m.id == id),
      isFalse,
      reason: 'deleted message stays gone across the full flow',
    );
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
    expect(
      await sB.loadFile(fileMsg.fileId!),
      isNull,
      reason: 'the file blob must be erased when its message is deleted',
    );
  });

  test(
    'the connection greeting is not duplicated on the recipient by a flush',
    () async {
      // setUp already ran A.sendRequest('hi') + B.acceptContact: B holds the
      // greeting once. The greeting is stored on A as an outgoing `sent` message
      // (the request flow never acks it), so A's outbox re-sends it as a message.
      // It must dedup against the copy B stored from the request — not duplicate.
      expect(
        (await sB.loadMessages(a.hex)).where((m) => m.body == 'hi').length,
        1,
      );
      await mA.flushOutbox();
      await _pump();
      expect(
        (await sB.loadMessages(a.hex)).where((m) => m.body == 'hi').length,
        1,
        reason: 'greeting must dedup, not double via the outbox re-send',
      );
    },
  );

  test(
    'a deleted message does not resurrect when the sender re-delivers it',
    () async {
      await mA.sendText(b, 'secret');
      await _pump();
      final id = (await aMsg('secret')).id; // wire id == stored id
      expect(
        (await sB.loadMessages(a.hex)).where((m) => m.body == 'secret').length,
        1,
      );

      // B erases it (deniable delete).
      final bMsg = (await sB.loadMessages(
        a.hex,
      )).firstWhere((m) => m.body == 'secret');
      await mB.deleteMessageLocally(bMsg.id);
      expect(
        (await sB.loadMessages(a.hex)).where((m) => m.body == 'secret').length,
        0,
      );

      // The sender re-delivers the SAME id (an outbox retry that raced the
      // delete). Deniability core: deleted must stay deleted, never resurrect.
      await tA.send(b, WireEnvelope.message('secret', id: id).encode());
      await _pump();
      expect(
        (await sB.loadMessages(a.hex)).where((m) => m.body == 'secret').length,
        0,
        reason: 'a deleted message must not resurrect on re-delivery',
      );
    },
  );

  test('two senders using the same frameId are BOTH processed', () async {
    // The dedup seen-set was keyed by frameId alone. Two peers can easily use
    // the same one — `reconnect:`/`accept:` ids are derived from the peer, and
    // a `gcr:` id is shared across every holder asked — so whoever got there
    // first made the other's frame look already-processed and it was dropped
    // without a trace (audit XV-02).
    final c = _id(3);
    final tC = _FakeTransport(c)..peer = tB;
    final sC = HiddenVolumeStorage(_memOpener());
    await sC.open(password: 'c', createIfMissing: true);
    final mC = MessagingService(tC, sC)..start();
    addTearDown(mC.dispose);

    // B must accept C too, or the consent gate drops C's frame before the
    // seen-set is ever consulted and the test would prove nothing.
    await mC.sendRequest(b, 'hi');
    await _pump();
    await mB.acceptContact(c);
    await _pump();

    const shared = 'reconnect:shared-id';
    await tA.send(
      b,
      WireEnvelope.message('from-a', id: 'ma').withFrameId(shared).encode(),
    );
    await _pump();
    await tC.send(
      b,
      WireEnvelope.message('from-c', id: 'mc').withFrameId(shared).encode(),
    );
    await _pump();

    expect(
      (await sB.loadMessages(a.hex)).map((m) => m.body),
      contains('from-a'),
    );
    expect(
      (await sB.loadMessages(c.hex)).map((m) => m.body),
      contains('from-c'),
      reason: "the first sender's frameId must not suppress the second's",
    );
  });

  test('a duplicate fileMeta does not reset an in-progress transfer', () async {
    const tid = 'transfer-1';
    Uint8List meta() => fileMetaEnvelope(
      transferId: tid,
      name: 'f.bin',
      size: 2,
      count: 2,
    ).encode();
    await tA.send(b, meta());
    await tA.send(
      b,
      fileChunkEnvelope(
        transferId: tid,
        index: 0,
        total: 2,
        data: Uint8List.fromList([10]),
      ).encode(),
    );
    await tA.send(b, meta()); // DUPLICATE meta mid-transfer — must not reset
    await tA.send(
      b,
      fileChunkEnvelope(
        transferId: tid,
        index: 1,
        total: 2,
        data: Uint8List.fromList([20]),
      ).encode(),
    );
    await _pump();
    // Both chunks survived the duplicate meta → the transfer completes + stores.
    expect(
      (await sB.loadMessages(
        a.hex,
      )).any((m) => m.isFile && m.fileName == 'f.bin'),
      isTrue,
      reason: 'a duplicate meta must not discard already-received chunks',
    );
  });

  test(
    'a deleted file does not resurrect when the transfer is re-delivered',
    () async {
      const tid = 'file-xfer-1';
      Future<void> deliver() async {
        await tA.send(
          b,
          fileMetaEnvelope(
            transferId: tid,
            name: 'doc.bin',
            size: 3,
            count: 1,
          ).encode(),
        );
        await tA.send(
          b,
          fileChunkEnvelope(
            transferId: tid,
            index: 0,
            total: 1,
            data: Uint8List.fromList([1, 2, 3]),
          ).encode(),
        );
      }

      await deliver();
      await _pump();
      final fileMsg = (await sB.loadMessages(
        a.hex,
      )).firstWhere((m) => m.isFile);
      await mB.deleteMessageLocally(fileMsg.id);
      expect((await sB.loadMessages(a.hex)).any((m) => m.isFile), isFalse);

      // Re-deliver the SAME transfer (a hostile re-send) — must stay deleted.
      await deliver();
      await _pump();
      expect(
        (await sB.loadMessages(a.hex)).any((m) => m.isFile),
        isFalse,
        reason: 'a deleted file must not resurrect on re-delivery',
      );
    },
  );

  test('an edit for a deleted message does not resurrect it', () async {
    await mA.sendText(b, 'secret');
    await _pump();
    final bMsg = (await sB.loadMessages(
      a.hex,
    )).firstWhere((m) => m.body == 'secret');
    await mB.deleteMessageLocally(bMsg.id);
    expect(
      (await sB.loadMessages(a.hex)).where((m) => m.body == 'secret').length,
      0,
    );

    // The sender edits the message the recipient deleted — the edit must NOT
    // bring it back (deniability: deleted stays deleted across every vector).
    await tA.send(b, WireEnvelope.edit(bMsg.id, 'secret v2').encode());
    await _pump();
    expect(
      (await sB.loadMessages(a.hex)).where((m) => m.body.startsWith('secret')),
      isEmpty,
      reason: 'an edit must not resurrect a deleted message',
    );
  });

  test('an ack flips the sender message sent -> delivered', () async {
    await mA.sendText(b, 'hello');
    await _pump();
    expect(
      (await sB.loadMessages(a.hex)).map((m) => m.body),
      contains('hello'),
    );
    expect((await aMsg('hello')).status, MessageStatus.delivered);
  });

  test(
    'a completed file transfer flips the sender file message to delivered',
    () async {
      await mA.sendFile(b, Uint8List.fromList([1, 2, 3, 4, 5]), 'doc.txt');
      await _pump();
      // B received + reassembled the file.
      expect(
        (await sB.loadMessages(
          a.hex,
        )).any((m) => m.isFile && m.fileName == 'doc.txt'),
        isTrue,
      );
      // A's file message must flip to delivered (B acks on completion), not stay
      // 'sent' forever like text without an ack.
      final fileMsg = (await sA.loadMessages(
        b.hex,
      )).firstWhere((m) => m.isFile);
      expect(
        fileMsg.status,
        MessageStatus.delivered,
        reason: 'receiver must ack a completed file transfer',
      );
    },
  );

  test(
    'message composed offline stays sent, then flush delivers it on reconnect',
    () async {
      tA.online = false; // A goes offline
      await mA.sendText(b, 'composed offline');
      await _pump();
      // Stored locally as un-acked, never reached B.
      expect((await aMsg('composed offline')).status, MessageStatus.sent);
      expect(
        (await sB.loadMessages(a.hex)).any((m) => m.body == 'composed offline'),
        isFalse,
      );

      tA.online = true; // reconnect
      await mA.flushOutbox();
      await _pump();
      expect(
        (await sB.loadMessages(a.hex)).any((m) => m.body == 'composed offline'),
        isTrue,
      );
      expect((await aMsg('composed offline')).status, MessageStatus.delivered);
    },
  );

  test(
    'a peer with no mailbox is left alone until the backoff expires',
    () async {
      // Two things had to be true for this to work, and neither was. The
      // condition has two spellings — the native path answers `PeerUnresolved`,
      // the Dart path throws MailboxPeerUnresolved — and only the first earned a
      // backoff. And the backoff was consulted in the outbox flush loop alone,
      // while a user send finishes with its OWN background deposit that walked
      // straight past it. So an asleep phone was re-asked on every send.
      final mailbox = _UnresolvedMailboxSink();
      mA.attachMailbox(mailbox);
      tA.online = false;

      await mA.sendText(b, 'first');
      await _pump();
      expect(mailbox.calls, 1, reason: 'the first deposit is attempted');

      await mA.sendText(b, 'second');
      await _pump();
      expect(
        mailbox.calls,
        1,
        reason:
            'and the second is not: this peer has no mailbox to reach, and '
            'the frame stays durable for the flush loop to deposit later',
      );
    },
  );

  test('flush keeps live retries moving and dedupes a slow stash', () async {
    final mailbox = _BlockingMailboxSink();
    addTearDown(mailbox.release);
    mA.attachMailbox(mailbox);

    tA.online = false;
    await mA.sendText(b, 'queued behind mailbox');
    await _pump();
    expect((await aMsg('queued behind mailbox')).status, MessageStatus.sent);

    await mA.flushOutbox().timeout(const Duration(milliseconds: 100));
    expect(
      mailbox.calls,
      1,
      reason: 'sendText and flush must share one in-flight deposit',
    );
  });

  test(
    'background durable stashes are bounded while one deposit is slow',
    () async {
      final mailbox = _BlockingMailboxSink();
      addTearDown(mailbox.release);
      mA.attachMailbox(mailbox);
      tA.online = false;

      await mA.sendDurable(b, 'test:one', const WireEnvelope.reconnect('one'));
      await mA.sendDurable(b, 'test:two', const WireEnvelope.reconnect('two'));
      await _pump();

      expect(
        mailbox.calls,
        1,
        reason: 'a durable backlog must not fan out KEM stashes in parallel',
      );
    },
  );

  test(
    'a call can pause background stash without losing the durable frame',
    () async {
      final mailbox = _BlockingMailboxSink();
      addTearDown(mailbox.release);
      mA.attachMailbox(mailbox);
      tA.online = false;
      mA.backgroundStashPaused = true;
      expect(mailbox.backgroundDrainPaused, isTrue);

      await mA.sendDurable(
        b,
        'test:during-call',
        const WireEnvelope.reconnect('call'),
      );
      await _pump();
      expect(mailbox.calls, 0);
      expect(
        (await sA.pendingOutboxFrames()).map((f) => f.frameId),
        contains('test:during-call'),
        reason: 'pausing mailbox work must not drop its durable source',
      );

      mA.backgroundStashPaused = false;
      expect(mailbox.backgroundDrainPaused, isFalse);
      await mA.flushOutbox();
      await _pump();
      expect(mailbox.calls, 1);
    },
  );

  test(
    'non-contact Space join ACK is scoped to a persisted valid request',
    () async {
      final x = _id(21);
      final y = _id(22);
      final tx = _FakeTransport(x);
      final ty = _FakeTransport(y);
      tx.peer = ty;
      ty.peer = tx;
      final sx = HiddenVolumeStorage(_memOpener());
      final sy = HiddenVolumeStorage(_memOpener());
      await sx.open(password: 'x', createIfMissing: true);
      await sy.open(password: 'y', createIfMissing: true);
      final mx = MessagingService(tx, sx)..start();
      final my = MessagingService(ty, sy)..start();
      addTearDown(() async {
        await mx.dispose();
        await my.dispose();
        await sx.close();
        await sy.close();
        await tx.dispose();
        await ty.dispose();
      });

      my.onSpaceJoinRequest = (peer, json) async => json == 'valid';
      await mx.sendSpaceJoinRequest(y, 'aa' * 32, 'valid');
      await _pump();
      expect(
        (await sx.pendingOutboxFrames()).map((frame) => frame.frameId),
        isNot(contains('space-join-request:${'aa' * 32}')),
        reason: 'durably accepted request must ACK across the contact boundary',
      );

      await mx.sendSpaceJoinRequest(y, 'bb' * 32, 'invalid');
      await _pump();
      final invalidId = 'space-join-request:${'bb' * 32}';
      expect(
        (await sx.pendingOutboxFrames()).map((frame) => frame.frameId),
        contains(invalidId),
        reason: 'policy rejection must remain unacknowledged',
      );

      await ty.send(
        x,
        const WireEnvelope.ack('space-join-request:guessed').encode(),
      );
      await _pump();
      expect(
        (await sx.pendingOutboxFrames()).map((frame) => frame.frameId),
        contains(invalidId),
        reason: 'a stranger cannot retire another durable frame by guessing',
      );
    },
  );

  test(
    'non-contact moderation appeal ACK waits for durable Space validation',
    () async {
      final x = _id(23);
      final y = _id(24);
      final tx = _FakeTransport(x);
      final ty = _FakeTransport(y);
      tx.peer = ty;
      ty.peer = tx;
      final sx = HiddenVolumeStorage(_memOpener());
      final sy = HiddenVolumeStorage(_memOpener());
      await sx.open(password: 'x', createIfMissing: true);
      await sy.open(password: 'y', createIfMissing: true);
      final mx = MessagingService(tx, sx)..start();
      final my = MessagingService(ty, sy)..start();
      addTearDown(() async {
        await mx.dispose();
        await my.dispose();
        await sx.close();
        await sy.close();
        await tx.dispose();
        await ty.dispose();
      });

      my.onSpaceModerationAppeal = (peer, json) async => json == 'valid';
      await mx.sendSpaceModerationAppeal(y, 'ac' * 32, 'valid');
      await _pump();
      expect(
        (await sx.pendingOutboxFrames()).map((frame) => frame.frameId),
        isNot(contains('space-moderation-appeal:${'ac' * 32}')),
      );

      await mx.sendSpaceModerationAppeal(y, 'ad' * 32, 'invalid');
      await _pump();
      expect(
        (await sx.pendingOutboxFrames()).map((frame) => frame.frameId),
        contains('space-moderation-appeal:${'ad' * 32}'),
        reason: 'invalid proposals must not be ACKed or retired',
      );

      mx.onSpaceModerationAppealDecision = (peer, json) async =>
          json == 'decision';
      await my.sendSpaceModerationAppealDecision(x, 'ac' * 32, 'decision');
      await _pump();
      expect(
        (await sy.pendingOutboxFrames()).map((frame) => frame.frameId),
        isNot(contains('space-moderation-appeal-decision:${'ac' * 32}')),
      );
    },
  );

  test(
    'non-contact abuse report ACK waits for durable owner validation',
    () async {
      final x = _id(25);
      final y = _id(26);
      final tx = _FakeTransport(x);
      final ty = _FakeTransport(y);
      tx.peer = ty;
      ty.peer = tx;
      final sx = HiddenVolumeStorage(_memOpener());
      final sy = HiddenVolumeStorage(_memOpener());
      await sx.open(password: 'x', createIfMissing: true);
      await sy.open(password: 'y', createIfMissing: true);
      final mx = MessagingService(tx, sx)..start();
      final my = MessagingService(ty, sy)..start();
      addTearDown(() async {
        await mx.dispose();
        await my.dispose();
        await sx.close();
        await sy.close();
        await tx.dispose();
        await ty.dispose();
      });

      my.onSpaceAbuseReport = (peer, json) async => json == 'valid';
      await mx.sendSpaceAbuseReport(y, 'ae' * 32, 'valid');
      await _pump();
      expect(
        (await sx.pendingOutboxFrames()).map((frame) => frame.frameId),
        isNot(contains('space-abuse-report:${'ae' * 32}')),
      );

      await mx.sendSpaceAbuseReport(y, 'af' * 32, 'invalid');
      await _pump();
      expect(
        (await sx.pendingOutboxFrames()).map((frame) => frame.frameId),
        contains('space-abuse-report:${'af' * 32}'),
        reason: 'invalid reports must remain durable and unacknowledged',
      );

      mx.onSpaceAbuseReportDecision = (peer, json) async => json == 'decision';
      await my.sendSpaceAbuseReportDecision(x, 'ae' * 32, 'decision');
      await _pump();
      expect(
        (await sy.pendingOutboxFrames()).map((frame) => frame.frameId),
        isNot(contains('space-abuse-report-decision:${'ae' * 32}')),
      );
    },
  );

  test(
    're-sending an already-delivered message does not duplicate it',
    () async {
      await mA.sendText(b, 'hello');
      await _pump();
      final id = (await aMsg('hello')).id;

      // Sender's outbox re-sends the same id (e.g. it missed the first ack).
      await tA.send(b, WireEnvelope.message('hello', id: id).encode());
      await _pump();
      expect(
        (await sB.loadMessages(a.hex)).where((m) => m.body == 'hello').length,
        1,
      );
    },
  );

  test('flush is a no-op for already-delivered messages', () async {
    await mA.sendText(b, 'hello');
    await _pump();
    await mA.flushOutbox();
    await _pump();
    // No duplicate appeared on the receiver.
    expect(
      (await sB.loadMessages(a.hex)).where((m) => m.body == 'hello').length,
      1,
    );
  });

  test(
    'custom emoji survives send, offline retry, storage, and edit',
    () async {
      final first = InlineCustomEmoji(
        offset: 3,
        dataB64: base64Encode([1, 2, 3]),
      );
      tA.online = false;
      await mA.sendText(b, 'hi ☺', customEmoji: [first]);
      final local = (await sA.loadMessages(
        b.hex,
      )).singleWhere((m) => m.body == 'hi ☺');
      expect(local.customEmoji.single.dataB64, first.dataB64);

      tA.online = true;
      await mA.flushOutbox();
      await _pump();
      final received = (await sB.loadMessages(
        a.hex,
      )).singleWhere((m) => m.id == local.id);
      expect(received.customEmoji.single.offset, 3);

      final editedEmoji = InlineCustomEmoji(
        offset: 4,
        dataB64: base64Encode([4, 5, 6]),
      );
      await mA.editOwnMessage(local.id, 'now ☺!', customEmoji: [editedEmoji]);
      await _pump();
      for (final stored in [
        (await sA.loadMessages(b.hex)).singleWhere((m) => m.id == local.id),
        (await sB.loadMessages(a.hex)).singleWhere((m) => m.id == local.id),
      ]) {
        expect(stored.body, 'now ☺!');
        expect(stored.customEmoji.single.offset, 4);
        expect(stored.customEmoji.single.dataB64, editedEmoji.dataB64);
      }
    },
  );

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
    expect(
      (await sB.loadMessages(
        a.hex,
      )).any((m) => m.body == 'teh meeting is at 5'),
      isFalse,
    );
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

  test(
    'a peer cannot edit or delete OUR outgoing message (authz by direction)',
    () async {
      await mA.sendText(b, 'our statement');
      await _pump();
      final id = (await aMsg('our statement')).id;

      // B (an accepted peer) maliciously sends edit + del for A's OWN message id.
      await tB.send(a, WireEnvelope.edit(id, 'doctored').encode());
      await tB.send(a, WireEnvelope.del(id).encode());
      await _pump();

      final ours = await sA.loadMessages(b.hex);
      expect(
        ours.any((m) => m.id == id && m.body == 'our statement'),
        isTrue,
        reason: 'a peer must not rewrite or destroy our own sent message',
      );
      expect(ours.any((m) => m.body == 'doctored'), isFalse);
    },
  );

  test(
    'deleteForEveryone is a no-op on a received message (can only unsend own)',
    () async {
      await mA.sendText(b, 'from A');
      await _pump();
      final received = (await sB.loadMessages(
        a.hex,
      )).firstWhere((m) => m.body == 'from A');

      await mB.deleteForEveryone(received.id); // B did not send it
      await _pump();

      // Nothing removed on either side.
      expect(
        (await sB.loadMessages(a.hex)).any((m) => m.id == received.id),
        isTrue,
      );
      expect(
        (await sA.loadMessages(b.hex)).any((m) => m.body == 'from A'),
        isTrue,
      );
    },
  );

  test(
    'deleteMessageLocally on your OWN message is delete-for-me, not unsend',
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
      expect(
        (await sB.loadMessages(a.hex)).any((m) => m.body == 'oops'),
        isTrue,
        reason: 'delete-for-me must not unsend the peer copy',
      );
    },
  );

  test(
    'deleteMessageLocally purges a received message from this device',
    () async {
      await mA.sendText(b, 'sensitive');
      await _pump();
      final received = (await sB.loadMessages(
        a.hex,
      )).firstWhere((m) => m.body == 'sensitive');

      await mB.deleteMessageLocally(received.id);

      expect(
        (await sB.loadMessages(a.hex)).any((m) => m.body == 'sensitive'),
        isFalse,
      );
      // The sender's own copy is untouched (local-only delete).
      expect(
        (await sA.loadMessages(b.hex)).any((m) => m.body == 'sensitive'),
        isTrue,
      );
    },
  );
}
