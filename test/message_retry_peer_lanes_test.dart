import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/ratchet_persistence.dart';

NodeId _id(int tag) => NodeId(Uint8List(32)..fillRange(0, 32, tag));

class _Storage extends HiddenVolumeStorage {
  _Storage()
    : super(({required password, required create}) => FakeKvLogStore());
  final failedReads = <String>{};
  Future<void> Function(String id)? beforeFailureWrite;
  Future<void> Function(String id)? beforeDeletedRead;
  Future<void> Function(String id, bool deleted)? afterDeletedRead;
  Future<void> Function(NodeId)? afterContactRead;
  bool deferMessageHandoff = false;
  int fileReads = 0;

  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) {
    fileReads++;
    return super.loadFile(fileId, maxBytes: maxBytes);
  }

  @override
  Future<Contact?> getContact(NodeId nodeId) async {
    final contact = await super.getContact(nodeId);
    await afterContactRead?.call(nodeId);
    return contact;
  }

  @override
  bool Function() captureMessageSendReadFence() {
    final current = super.captureMessageSendReadFence();
    return () => !deferMessageHandoff && current();
  }

  @override
  Future<bool> isMessageDeleted(String conversationId, String messageId) async {
    await beforeDeletedRead?.call(messageId);
    final deleted = await super.isMessageDeleted(conversationId, messageId);
    await afterDeletedRead?.call(messageId, deleted);
    return deleted;
  }

  @override
  Future<bool> markMessageStatus(
    String conversationId,
    String messageId,
    MessageStatus status,
  ) async {
    if (status == MessageStatus.failed) {
      await beforeFailureWrite?.call(messageId);
    }
    return super.markMessageStatus(conversationId, messageId, status);
  }

  @override
  Future<List<Message>> loadMessages(String id, {int? limit}) async {
    if (failedReads.contains(id)) throw StateError('damaged conversation');
    return super.loadMessages(id, limit: limit);
  }

  @override
  Future<List<Conversation>> loadConversations() async =>
      (await super.loadConversations())
        ..sort((a, b) => a.peer.nodeId.hex.compareTo(b.peer.nodeId.hex));
}

class _HeldReservation extends Fake implements RatchetPersistence {
  _HeldReservation(this.entered, this.release);

  final Completer<void> entered;
  final Completer<void> release;

  @override
  bool get degraded => false;

  @override
  Future<void> reserveBeforePublish(NodeId peer) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  @override
  Future<int> flush({String why = 'unknown', bool now = false}) async => 0;

  @override
  Future<int> close() async => 0;
}

class _Transport implements VeilTransport {
  final inbound = StreamController<InboundMessage>.broadcast();
  final gates = <String, Completer<void>>{};
  final failAfterGate = <String>{};
  final sent = <({NodeId peer, String id})>[];
  final fileFrames = <WireEnvelope>[];
  final historyFrames = <WireEnvelope>[];
  final reofferRequests = <WireEnvelope>[];
  Future<void> Function(WireEnvelope)? onFileFrame;
  int active = 0, peak = 0;
  @override
  Future<NodeId> nodeId() async => _id(1);
  @override
  Future<void> send(
    NodeId peer,
    Uint8List bytes, {
    bool anonymous = false,
  }) async {
    final frame = WireEnvelope.decode(bytes);
    if (frame.kind == WireKind.contentReoffer) reofferRequests.add(frame);
    if (const {
          WireKind.edit,
          WireKind.voidSeq,
          WireKind.fileQuery,
        }.contains(frame.kind) ||
        (frame.kind == WireKind.sync && frame.body.contains('"echo"'))) {
      historyFrames.add(frame);
    }
    if (const {
      WireKind.fileMeta,
      WireKind.fileChunk,
      WireKind.contentManifest,
    }.contains(frame.kind)) {
      fileFrames.add(frame);
      await onFileFrame?.call(frame);
      return;
    }
    if (frame.kind != WireKind.message) return;
    final id = frame.id!;
    sent.add((peer: peer, id: id));
    active++;
    if (active > peak) peak = active;
    try {
      await gates[id]?.future;
      if (failAfterGate.contains(id)) {
        throw StateError('late transport failure');
      }
    } finally {
      active--;
    }
  }

  @override
  Future<void> sendWithReply(NodeId peer, Uint8List bytes) => send(peer, bytes);
  @override
  Future<void> sendReply(int replyId, Uint8List bytes) async {}
  @override
  Stream<InboundMessage> messages() => inbound.stream;
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => const [];
  @override
  Future<void> dispose() => inbound.close();
}

void main() {
  late _Storage storage;
  late _Transport transport;
  late MessagingService service;
  late List<Future<void>> runs;
  late DateTime? testNow;
  setUp(() async {
    storage = _Storage();
    await storage.open(password: 'fixture', createIfMissing: true);
    transport = _Transport();
    testNow = null;
    service = MessagingService(
      transport,
      storage,
      now: () => testNow ?? DateTime.now(),
    );
    runs = [];
  });
  tearDown(() async {
    for (final gate in transport.gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await Future.wait(runs);
    expect(transport.active, 0);
    await service.dispose();
    await storage.close();
  });
  Future<void> queue(
    int peer,
    String id, {
    int seq = 1,
    DateTime? timestamp,
  }) async {
    await storage.upsertContact(Contact(nodeId: _id(peer)));
    await storage.appendMessage(
      Message(
        id: id,
        conversationId: _id(peer).hex,
        direction: MessageDirection.outgoing,
        author: _id(1).hex,
        body: id,
        seq: seq,
        timestamp: timestamp ?? DateTime.now(),
      ),
    );
  }

  Future<void> barrier() => Future<void>.delayed(Duration.zero);
  Future<void> flush() {
    final run = service.flushOutbox();
    runs.add(run);
    return run;
  }

  List<String> ids(int peer) => [
    for (final sent in transport.sent)
      if (sent.peer == _id(peer)) sent.id,
  ];

  for (final stage in ['journal', 'ratchet']) {
    for (final change in ['block', 'block then unblock', 'sibling receipt']) {
      test('first send rechecks $change after waiting on $stage', () async {
        final peer = _id(2);
        await storage.upsertContact(Contact(nodeId: peer));
        final entered = Completer<void>(), release = Completer<void>();
        if (stage == 'journal') {
          service.onMessageStored = (_, _) async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          };
        } else {
          service.ratchet = _HeldReservation(entered, release);
        }

        final sending = service.sendText(peer, 'first attempt');
        final acknowledged = change == 'sibling receipt';
        late final Message original;
        late final bool reported;
        try {
          await entered.future;
          original = (await storage.loadMessages(peer.hex)).single;
          expect(ids(2), isEmpty);
          if (acknowledged) {
            await service.applyMirroredMessageStatus(
              peer: peer,
              msgId: original.id,
              status: MessageStatus.delivered,
            );
          } else {
            await service.blockContact(peer);
            if (change == 'block then unblock') {
              await service.unblockContact(peer);
            }
          }
        } finally {
          release.complete();
          reported = await sending;
        }
        expect(ids(2), isEmpty);
        expect(reported, acknowledged);
        final saved = (await storage.loadMessages(peer.hex)).single;
        expect(saved.id, original.id);
        expect(
          saved.status,
          acknowledged ? MessageStatus.delivered : MessageStatus.sent,
        );
        if (change == 'block') await service.unblockContact(peer);
        await flush();
        expect(ids(2), acknowledged ? isEmpty : [original.id]);
      });
    }
  }

  for (final stage in ['storage', 'ratchet']) {
    for (final change in ['block', 'block then unblock', 'receipt']) {
      test('retry rechecks $change after waiting on $stage', () async {
        final peer = _id(2);
        Future<void> receiveReceipt(String id) => service.deliverInbound(
          InboundMessage(
            src: peer,
            payload: WireEnvelope.ack(id).encode(),
            provenance: SenderProvenance.sessionPeer,
          ),
        );
        // Finish the first advisory sync before adding the reservation gate.
        await queue(2, 'prime');
        await flush();
        await receiveReceipt('prime');
        await barrier();
        transport.sent.clear();
        await queue(2, 'outstanding', seq: 2);
        final entered = Completer<void>(), release = Completer<void>();
        if (stage == 'storage') {
          storage.beforeDeletedRead = (id) async {
            if (id != 'outstanding' || entered.isCompleted) return;
            entered.complete();
            await release.future;
          };
        } else {
          service.ratchet = _HeldReservation(entered, release);
        }

        final retry = flush();
        try {
          await entered.future;
          expect(ids(2), isEmpty);
          if (change == 'receipt') {
            await receiveReceipt('outstanding');
          } else {
            await service.blockContact(peer);
            if (change == 'block then unblock') {
              await service.unblockContact(peer);
            }
          }
        } finally {
          release.complete();
          await retry;
        }
        expect(ids(2), isEmpty);

        if (change == 'block') await service.unblockContact(peer);
        await flush();
        expect(ids(2), change == 'receipt' ? isEmpty : ['outstanding']);
      });
    }
  }

  for (final firstSend in [true, false]) {
    for (final delete in [true, false]) {
      final attempt = firstSend ? 'first send' : 'retry';
      final change = delete ? 'deletion' : 'expiry';
      test('$attempt respects $change during ratchet preparation', () async {
        final peer = _id(2);
        final start = testNow = DateTime.now();
        if (!firstSend) {
          // Finish advisory sync before pausing the actual message send.
          await queue(2, 'prime');
          await flush();
          await service.deliverInbound(
            InboundMessage(
              src: peer,
              payload: WireEnvelope.ack('prime').encode(),
              provenance: SenderProvenance.sessionPeer,
            ),
          );
          await barrier();
          transport.sent.clear();
          await queue(2, 'outstanding', seq: 2, timestamp: start);
        }
        await storage.upsertContact(
          Contact(nodeId: peer, disappearingTtlSeconds: delete ? null : 30),
        );
        final entered = Completer<void>(), release = Completer<void>();
        service.ratchet = _HeldReservation(entered, release);
        final Future<bool?> sending = firstSend
            ? service.sendText(peer, 'first attempt')
            : flush().then((_) => null);
        try {
          await entered.future;
          final row = (await storage.loadMessages(peer.hex)).last;
          expect(ids(2), isEmpty);
          if (delete) {
            await storage.deleteMessage(peer.hex, row.id);
          } else {
            testNow = start.add(const Duration(seconds: 30));
          }
        } finally {
          release.complete();
          final reported = await sending;
          if (firstSend) expect(reported, isFalse);
        }
        expect(ids(2), isEmpty);
      });
    }
  }

  for (final delete in [true, false]) {
    final change = delete ? 'a committed deletion' : 'a shorter expiry policy';
    test('handoff discards a stale read after $change', () async {
      final peer = _id(2);
      final start = testNow = DateTime.now();
      await storage.upsertContact(Contact(nodeId: peer));
      final reserved = Completer<void>(),
          releaseReservation = Completer<void>();
      final read = Completer<void>(), releaseRead = Completer<void>();
      service.ratchet = _HeldReservation(reserved, releaseReservation);
      final sending = service.sendText(peer, 'first attempt');
      try {
        await reserved.future;
        final row = (await storage.loadMessages(peer.hex)).single;
        storage.afterDeletedRead = (id, deleted) async {
          if (id != row.id || read.isCompleted) return;
          read.complete();
          expect(deleted, isFalse);
          await releaseRead.future;
        };
        releaseReservation.complete();
        await Future.any([
          read.future,
          sending.then((_) => fail('transport finished before the late read')),
        ]);
        if (delete) {
          await storage.deleteMessage(peer.hex, row.id);
        } else {
          testNow = start.add(const Duration(seconds: 30));
          await storage.upsertContact(
            Contact(nodeId: peer, disappearingTtlSeconds: 30),
          );
        }
      } finally {
        if (!releaseReservation.isCompleted) releaseReservation.complete();
        releaseRead.complete();
        expect(await sending, isFalse);
      }
      expect(ids(2), isEmpty);
    });
  }

  Future<void> sendAttachment(String mode, NodeId peer) async {
    final bytes = Uint8List(mode == 'manifest' ? 140 * 1024 : 12000);
    if (mode == 'stream') {
      await service.sendFileStreaming(
        peer,
        'fixture.bin',
        bytes.length,
        (offset, length) async =>
            Uint8List.sublistView(bytes, offset, offset + length),
        close: () async {},
      );
    } else {
      await service.sendFile(peer, bytes, 'fixture.bin');
    }
  }

  for (final mode in ['inline', 'manifest', 'stream', 'share']) {
    for (final change in ['delete', 'expire', 'block then unblock']) {
      test('$mode attachment rechecks $change after ratchet wait', () async {
        final peer = _id(2);
        final start = testNow = DateTime.now();
        await storage.upsertContact(
          Contact(nodeId: peer, disappearingTtlSeconds: 30),
        );
        final shareId = mode == 'share'
            ? await service.sendContent(peer, Uint8List(12000), 'fixture.bin')
            : null;
        transport.fileFrames.clear();
        final entered = Completer<void>(), release = Completer<void>();
        service.ratchet = _HeldReservation(entered, release);
        final sending = shareId == null
            ? sendAttachment(mode, peer)
            : service.shareStoredContent(peer, shareId).then<void>((_) {});
        late final Message row;
        try {
          await entered.future;
          row = (await storage.loadMessages(peer.hex)).single;
          expect(transport.fileFrames, isEmpty);
          if (change == 'delete') {
            await storage.deleteMessage(peer.hex, row.id);
          } else if (change == 'expire') {
            testNow = start.add(const Duration(seconds: 30));
          } else {
            await service.blockContact(peer);
            await service.unblockContact(peer);
          }
        } finally {
          release.complete();
          await sending;
        }
        expect(transport.fileFrames, isEmpty);
        if (mode != 'inline' && change == 'block then unblock') {
          await flush();
          final frame = transport.fileFrames.single;
          expect(frame.kind, WireKind.contentManifest);
          expect(jsonDecode(frame.body)['mid'], row.id);
        }
      });
    }
  }

  for (final mode in ['manifest', 'stream']) {
    test('$mode first offer carries the stored message timestamp', () async {
      final peer = _id(2);
      final start = testNow = DateTime.now();
      await storage.upsertContact(Contact(nodeId: peer));
      await sendAttachment(mode, peer);
      final frame = transport.fileFrames.single;
      expect(frame.kind, WireKind.contentManifest);
      expect(jsonDecode(frame.body)['mts'], start.millisecondsSinceEpoch);
    });
  }

  test('deletion after inline metadata stops every unsent chunk', () async {
    final peer = _id(2);
    await storage.upsertContact(Contact(nodeId: peer));
    final entered = Completer<void>(), release = Completer<void>();
    transport.onFileFrame = (frame) async {
      if (frame.kind != WireKind.fileMeta) return;
      entered.complete();
      await release.future;
    };
    final sending = sendAttachment('inline', peer);
    try {
      await entered.future;
      final row = (await storage.loadMessages(peer.hex)).single;
      await storage.deleteMessage(peer.hex, row.id);
    } finally {
      release.complete();
      await sending;
    }
    expect(transport.fileFrames.map((frame) => frame.kind), [
      WireKind.fileMeta,
    ]);
  });

  Future<void> requestFileRepair(
    NodeId peer,
    String transferId, {
    List<int>? missing,
  }) => service.deliverInbound(
    InboundMessage(
      src: peer,
      provenance: SenderProvenance.sessionPeer,
      payload: fileNackEnvelope(
        transferId: transferId,
        missing: missing,
      ).encode(),
    ),
  );

  for (final change in ['delete', 'expire', 'block then unblock']) {
    test('file repair rechecks $change after ratchet wait', () async {
      final peer = _id(2);
      final start = testNow = DateTime.now();
      await storage.upsertContact(
        Contact(nodeId: peer, disappearingTtlSeconds: 30),
      );
      await sendAttachment('inline', peer);
      final message = (await storage.loadMessages(peer.hex)).single;
      transport.fileFrames.clear();

      final entered = Completer<void>(), release = Completer<void>();
      service.ratchet = _HeldReservation(entered, release);
      final repairing = requestFileRepair(peer, message.id);
      try {
        await Future.any([
          entered.future,
          repairing.then((_) => fail('repair completed before ratchet wait')),
        ]);
        expect(transport.fileFrames, isEmpty);
        if (change == 'delete') {
          await storage.deleteMessage(peer.hex, message.id);
        } else if (change == 'expire') {
          testNow = start.add(const Duration(seconds: 30));
        } else {
          await service.blockContact(peer);
          await service.unblockContact(peer);
        }
      } finally {
        release.complete();
        await repairing;
      }
      expect(transport.fileFrames, isEmpty);
    });
  }

  test(
    'file repair stops after the first chunk when the message is erased',
    () async {
      final peer = _id(2);
      await storage.upsertContact(Contact(nodeId: peer));
      await sendAttachment('inline', peer);
      final message = (await storage.loadMessages(peer.hex)).single;
      transport.fileFrames.clear();

      final entered = Completer<void>(), release = Completer<void>();
      transport.onFileFrame = (frame) async {
        if (frame.kind != WireKind.fileChunk || entered.isCompleted) return;
        entered.complete();
        await release.future;
      };
      final repairing = requestFileRepair(peer, message.id);
      try {
        await Future.any([
          entered.future,
          repairing.then(
            (_) => fail('repair completed before sending a chunk'),
          ),
        ]);
        await storage.deleteMessage(peer.hex, message.id);
      } finally {
        release.complete();
        await repairing;
      }
      expect(transport.fileFrames.map((frame) => frame.kind), [
        WireKind.fileChunk,
      ]);
    },
  );

  test('an expired file repair never opens the blob', () async {
    final peer = _id(2);
    final start = testNow = DateTime.now();
    await storage.upsertContact(
      Contact(nodeId: peer, disappearingTtlSeconds: 30),
    );
    await sendAttachment('inline', peer);
    final message = (await storage.loadMessages(peer.hex)).single;
    transport.fileFrames.clear();
    storage.fileReads = 0;
    testNow = start.add(const Duration(seconds: 30));

    await requestFileRepair(peer, message.id);
    expect(storage.fileReads, 0);
    expect(transport.fileFrames, isEmpty);
  });

  test('file repair selects chunks of an acknowledged post by ID', () async {
    final peer = _id(2);
    await storage.upsertContact(Contact(nodeId: peer));
    await sendAttachment('inline', peer);
    final message = (await storage.loadMessages(peer.hex)).single;
    await service.applyMirroredMessageStatus(
      peer: peer,
      msgId: message.id,
      status: MessageStatus.delivered,
    );
    transport.fileFrames.clear();
    storage.failedReads.add(peer.hex);

    await requestFileRepair(peer, message.id, missing: [1]);
    final chunk = transport.fileFrames.single;
    expect(chunk.kind, WireKind.fileChunk);
    final part = parseFileChunk(chunk.body);
    expect(part.transferId, message.id);
    expect(part.index, 1);
  });

  Future<void> requestReoffer(NodeId peer, String contentId) =>
      service.deliverInbound(
        InboundMessage(
          src: peer,
          provenance: SenderProvenance.sessionPeer,
          payload: contentReofferEnvelope(contentId).encode(),
        ),
      );

  for (final change in ['delete', 'expire', 'block then unblock']) {
    test('large file reoffer rechecks $change after ratchet wait', () async {
      final peer = _id(2);
      final start = testNow = DateTime.now();
      await storage.upsertContact(
        Contact(nodeId: peer, disappearingTtlSeconds: 30),
      );
      await sendAttachment('manifest', peer);
      final row = (await storage.loadMessages(peer.hex)).single;
      transport.fileFrames.clear();

      final entered = Completer<void>(), release = Completer<void>();
      service.ratchet = _HeldReservation(entered, release);
      final sending = requestReoffer(peer, row.fileId!);
      try {
        await entered.future.timeout(const Duration(seconds: 3));
        expect(transport.fileFrames, isEmpty);
        if (change == 'delete') {
          await storage.deleteMessage(peer.hex, row.id);
        } else if (change == 'expire') {
          testNow = start.add(const Duration(seconds: 30));
        } else {
          await service.blockContact(peer);
          await service.unblockContact(peer);
        }
      } finally {
        release.complete();
        await sending;
      }
      await barrier();
      expect(transport.fileFrames, isEmpty);
    });
  }

  test('large file reoffer defers if chat history cannot be read', () async {
    final peer = _id(2);
    await storage.upsertContact(Contact(nodeId: peer));
    await sendAttachment('manifest', peer);
    final row = (await storage.loadMessages(peer.hex)).single;
    transport.fileFrames.clear();
    storage.failedReads.add(peer.hex);

    await requestReoffer(peer, row.fileId!);
    await barrier();
    expect(transport.fileFrames, isEmpty);

    storage.failedReads.clear();
    await requestReoffer(peer, row.fileId!);
    await barrier();
    expect(jsonDecode(transport.fileFrames.single.body)['mid'], row.id);
  });

  test(
    'large file reoffer survives a sender restart with stored bytes',
    () async {
      final peer = _id(2);
      await storage.upsertContact(Contact(nodeId: peer));
      await sendAttachment('manifest', peer);
      final row = (await storage.loadMessages(peer.hex)).single;
      final cid = row.fileId!;
      expect(await storage.hasFile(cid), isTrue);
      await service.dispose();
      service = MessagingService(transport, storage);
      transport.fileFrames.clear();

      await requestReoffer(peer, cid);
      await barrier();
      final reply = transport.fileFrames.single;
      expect(reply.kind, WireKind.contentManifest);
      final body = jsonDecode(reply.body);
      expect(body['id'], cid);
      expect(body['mid'], row.id);
      expect(body['mts'], row.timestamp.millisecondsSinceEpoch);
    },
  );

  test(
    'large file reoffer closes a temporarily reopened source on block',
    () async {
      final peer = _id(2);
      await storage.upsertContact(Contact(nodeId: peer));
      final data = Uint8List(12000);
      Future<Uint8List> read(int offset, int length) async =>
          Uint8List.sublistView(data, offset, offset + length);
      await service.sendFileStreaming(
        peer,
        'fixture.bin',
        data.length,
        read,
        close: () async {},
        sourcePath: 'mem://fixture',
      );
      final row = (await storage.loadMessages(peer.hex)).single;
      final cid = row.fileId!;
      expect(await storage.hasFile(cid), isFalse);
      await service.dispose();
      service = MessagingService(transport, storage);
      transport.fileFrames.clear();

      final entered = Completer<void>(), release = Completer<void>();
      var closed = 0;
      service.sourceOpener = (path) async {
        expect(path, 'mem://fixture');
        entered.complete();
        await release.future;
        return (read: read, close: () async => closed++);
      };
      final sending = requestReoffer(peer, cid);
      try {
        await Future.any([
          entered.future,
          sending.then((_) => fail('reoffer never opened the saved source')),
        ]);
        await service.blockContact(peer);
        await service.unblockContact(peer);
      } finally {
        release.complete();
        await sending;
      }
      await barrier();
      expect(closed, 1);
      expect(service.servingCount, 0);
      expect(transport.fileFrames, isEmpty);
    },
  );

  for (final parked in [false, true]) {
    for (final change in [
      'cancel',
      'cancel and restart',
      'block then unblock',
    ]) {
      final mode = parked ? 'parked' : 'direct';
      test('$mode reoffer request rechecks $change at handoff', () async {
        final peer = _id(2);
        final cid = List.filled(64, 'b').join();
        await storage.upsertContact(Contact(nodeId: peer));
        final entered = Completer<void>(), release = Completer<void>();
        service.ratchet = _HeldReservation(entered, release);
        Future<bool>? sending;
        if (parked) {
          expect(
            await service.downloadContent(peer, cid),
            ContentDownloadResult.requestedReoffer,
          );
        } else {
          sending = service.requestContentReoffer(peer, cid);
        }
        try {
          await entered.future.timeout(const Duration(seconds: 3));
          expect(transport.reofferRequests, isEmpty);
          if (change == 'block then unblock') {
            await service.blockContact(peer);
            await service.unblockContact(peer);
          } else {
            await service.cancelContentDownload(cid);
            if (change == 'cancel and restart') {
              expect(
                await service.downloadContent(peer, cid),
                ContentDownloadResult.requestedReoffer,
              );
            }
          }
        } finally {
          release.complete();
          if (sending != null) expect(await sending, isFalse);
        }
        await barrier();
        if (change == 'cancel and restart') {
          expect(transport.reofferRequests.single.body, cid);
        } else {
          expect(transport.reofferRequests, isEmpty);
        }
      });
    }
  }

  test('a reoffer cannot adopt a newer contact decision mid-read', () async {
    final peer = _id(2);
    final cid = List.filled(64, 'b').join();
    await storage.upsertContact(Contact(nodeId: peer));
    final entered = Completer<void>(), release = Completer<void>();
    storage.afterContactRead = (id) async {
      if (id != peer || entered.isCompleted) return;
      entered.complete();
      await release.future;
    };
    final sending = service.requestContentReoffer(peer, cid);
    try {
      await Future.any([
        entered.future,
        sending.then((_) => fail('request finished before the contact read')),
      ]);
      await service.blockContact(peer);
      await service.unblockContact(peer);
    } finally {
      release.complete();
    }
    expect(await sending, isFalse);
    expect(transport.reofferRequests, isEmpty);
  });

  Future<void> requestHistory(NodeId peer, Map<String, Object> body) =>
      service.deliverInbound(
        InboundMessage(
          src: peer,
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.sync(jsonEncode(body)).encode(),
        ),
      );

  for (final mode in [
    'post',
    'edit',
    'file query',
    'manifest',
    'echo',
    'edited echo',
  ]) {
    for (final change in ['delete', 'expire', 'block then unblock']) {
      test('history $mode rechecks $change after ratchet wait', () async {
        final peer = _id(2);
        final now = testNow = DateTime.now();
        final sentAt = now.subtract(const Duration(seconds: 20));
        final echo = mode.endsWith('echo');
        const echoId = 'echo-original';
        int floor = 0;
        if (mode == 'file query' || mode == 'manifest') {
          await storage.upsertContact(Contact(nodeId: peer));
          await sendAttachment(
            mode == 'manifest' ? 'manifest' : 'inline',
            peer,
          );
        } else if (echo) {
          await storage.appendMessage(
            Message(
              id: echoId,
              conversationId: peer.hex,
              direction: MessageDirection.incoming,
              author: peer.hex,
              body: 'echo body',
              seq: 1,
              timestamp: sentAt,
            ),
          );
          if (mode == 'edited echo') {
            await storage.editMessage(peer.hex, echoId, 'edited echo', seq: 2);
          }
        } else {
          await queue(2, 'original', timestamp: sentAt);
          if (mode == 'edit') {
            await storage.editMessage(peer.hex, 'original', 'edited', seq: 2);
            floor = 1;
          }
        }
        await storage.upsertContact(
          Contact(nodeId: peer, disappearingTtlSeconds: 30),
        );
        final row = (await storage.loadMessages(peer.hex)).single;
        transport.sent.clear();
        transport.fileFrames.clear();
        transport.historyFrames.clear();

        final entered = Completer<void>(), release = Completer<void>();
        service.ratchet = _HeldReservation(entered, release);
        final replay = requestHistory(peer, {
          'hw': {_id(1).hex: floor},
          if (echo) ...{
            'ow': [mode == 'edited echo' ? ownEchoKey(echoId) : '01020304'],
            'os': sentAt.millisecondsSinceEpoch - 1,
          },
        });
        try {
          await Future.any([
            entered.future,
            replay.then(
              (_) => fail('reply finished without ratchet preparation'),
            ),
          ]);
          expect(ids(2), isEmpty);
          expect(transport.fileFrames, isEmpty);
          expect(transport.historyFrames, isEmpty);
          if (change == 'delete') {
            await storage.deleteMessage(peer.hex, row.id);
          } else if (change == 'expire') {
            testNow = row.timestamp.add(const Duration(seconds: 30));
          } else {
            await service.blockContact(peer);
            await service.unblockContact(peer);
          }
        } finally {
          release.complete();
          await replay;
        }
        expect(ids(2), isEmpty);
        expect(transport.fileFrames, isEmpty);
        if (echo || change == 'block then unblock') {
          expect(transport.historyFrames, isEmpty);
        } else {
          final frame = transport.historyFrames.single;
          expect(frame.kind, WireKind.voidSeq);
          expect(frame.seq, mode == 'edit' ? 2 : 1);
          expect(await storage.isMessageDeleted(peer.hex, row.id), isTrue);
        }
      });
    }
  }

  for (final echo in [true, false]) {
    final mode = echo ? 'own-device echo' : 'gap-fill';
    test('$mode counts only admitted rounds towards its retry limit', () async {
      final peer = _id(2);
      final now = testNow = DateTime.now();
      await storage.upsertContact(Contact(nodeId: peer));
      await storage.appendMessage(
        Message(
          id: 'history-row',
          conversationId: peer.hex,
          direction: echo
              ? MessageDirection.incoming
              : MessageDirection.outgoing,
          author: echo ? peer.hex : _id(1).hex,
          body: 'durable history',
          seq: 1,
          timestamp: now,
        ),
      );
      for (var round = 0; round < 5; round++) {
        storage.deferMessageHandoff = round < 2;
        testNow = now.add(Duration(seconds: round * 6));
        transport.sent.clear();
        transport.historyFrames.clear();
        await requestHistory(peer, {
          'hw': <String, int>{},
          if (echo) ...{
            'ow': ['01020304'],
            'os': now.millisecondsSinceEpoch - 1,
          },
        });
        expect(
          echo ? transport.historyFrames.length : ids(2).length,
          round == 2 || round == 3 ? 1 : 0,
          reason: 'round $round',
        );
      }
    });
  }

  test('a held message does not delay another contact', () async {
    await queue(2, 'slow');
    await queue(3, 'healthy');
    transport.gates['slow'] = Completer<void>();
    unawaited(flush());
    await barrier();
    expect(ids(2), ['slow']);
    expect(ids(3), ['healthy']);
    expect(transport.gates['slow']!.isCompleted, isFalse);
  });

  test('shutdown joins an admitted retry status write and skips the next', () async {
    final old = DateTime.now().subtract(const Duration(hours: 2));
    await queue(2, 'first-expired', timestamp: old);
    await queue(
      2,
      'second-expired',
      seq: 2,
      timestamp: old.add(const Duration(seconds: 1)),
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final writes = <String>[];
    storage.beforeFailureWrite = (id) {
      writes.add(id);
      if (!entered.isCompleted) entered.complete();
      return release.future;
    };

    final retry = service.reconcileOnConnect();
    runs.add(retry);
    await entered.future;
    var closed = false;
    final closing = service.dispose().then<void>((_) => closed = true);
    try {
      await barrier();
      expect(closed, isFalse);
    } finally {
      release.complete();
      await Future.wait([retry, closing]);
    }
    expect(writes, ['first-expired']);
    expect(
      (await storage.loadMessageById(_id(2).hex, 'first-expired'))?.status,
      MessageStatus.failed,
    );
    expect(
      (await storage.loadMessageById(_id(2).hex, 'second-expired'))?.status,
      MessageStatus.sent,
    );

    final reopened = MessagingService(transport, storage);
    addTearDown(reopened.dispose);
    await reopened.reconcileOnConnect();
    expect(writes, ['first-expired', 'second-expired']);
    expect(
      (await storage.loadMessageById(_id(2).hex, 'second-expired'))?.status,
      MessageStatus.failed,
    );
  });

  test(
    'messages remain serial within a contact while others progress',
    () async {
      await queue(2, 'first');
      await queue(2, 'second', seq: 2);
      await queue(3, 'other');
      transport.gates['first'] = Completer<void>();
      final run = flush();
      await barrier();
      expect(ids(2), ['first']);
      expect(ids(3), ['other']);
      transport.gates['first']!.complete();
      await run;
      expect(ids(2), ['first', 'second']);
    },
  );

  test('at most four contacts run concurrently in a pass', () async {
    for (var i = 2; i < 8; i++) {
      await queue(i, 'peer-$i');
      transport.gates['peer-$i'] = Completer<void>();
    }
    unawaited(flush());
    await barrier();
    expect(transport.active, 4);
    expect(transport.sent, hasLength(4));
    transport.gates[transport.sent.first.id]!.complete();
    await barrier();
    expect(transport.sent, hasLength(5));
    expect(transport.peak, 4);
  });

  for (final lateFailure in [false, true]) {
    test(
      'a timed-out send retains its contact until settlement ($lateFailure)',
      () async {
        service.liveLegDeadline = Duration.zero;
        await queue(2, 'first');
        await queue(2, 'second', seq: 2);
        await queue(3, 'other');
        transport.gates['first'] = Completer<void>();
        if (lateFailure) transport.failAfterGate.add('first');
        await flush();
        expect(ids(2), ['first']);
        expect(ids(3), ['other']);
        await queue(2, 'third', seq: 3);
        await flush();
        expect(ids(2), ['first'], reason: 'deadline does not cancel transport');
        transport.gates['first']!.complete();
        await barrier();
        await flush();
        expect(ids(2), ['first', 'second', 'third']);
      },
    );
  }

  test('a pending send does not suppress terminal-age maintenance', () async {
    service.liveLegDeadline = Duration.zero;
    await queue(2, 'first');
    transport.gates['first'] = Completer<void>();
    await flush();
    await queue(
      2,
      'expired',
      seq: 2,
      timestamp: DateTime.now().subtract(const Duration(minutes: 91)),
    );
    await flush();
    final expired = (await storage.loadMessages(
      _id(2).hex,
    )).singleWhere((m) => m.id == 'expired');
    expect(expired.status, MessageStatus.failed);
    expect(ids(2), ['first']);
  });

  test('concurrent callers keep the four-contact bound', () async {
    for (var i = 2; i < 8; i++) {
      await queue(i, 'peer-$i');
      transport.gates['peer-$i'] = Completer<void>();
    }
    unawaited(flush());
    unawaited(flush());
    await barrier();
    expect(transport.active, 4);
    expect(transport.peak, 4);
    expect(transport.sent, hasLength(4));
  });

  test(
    'damaged histories do not abandon later contacts and failure remains visible',
    () async {
      for (var i = 2; i < 8; i++) {
        await queue(i, 'peer-$i');
      }
      storage.failedReads.addAll([for (var i = 2; i < 6; i++) _id(i).hex]);
      Object? failure;
      final run = service.flushOutbox().then<void>(
        (_) {},
        onError: (Object e) {
          failure = e;
        },
      );
      runs.add(run);
      await run;
      expect(failure, isA<StateError>());
      expect(ids(6), ['peer-6']);
      expect(ids(7), ['peer-7']);
    },
  );

  test(
    'concurrent flush callers do not duplicate a conversation pass',
    () async {
      await queue(2, 'first');
      transport.gates['first'] = Completer<void>();
      final a = flush(), b = flush();
      await barrier();
      expect(ids(2), ['first']);
      transport.gates['first']!.complete();
      await Future.wait([a, b]);
    },
  );

  test(
    'one contact journal cannot defer another contact or bypass persistence',
    () async {
      await queue(2, 'first');
      await queue(3, 'other');
      final held = Completer<void>();
      service.onMessageStored = (peer, _) async {
        if (peer == _id(2)) await held.future;
      };
      final run = flush();
      try {
        await barrier();
        expect(ids(2), isEmpty);
        expect(ids(3), ['other']);
      } finally {
        held.complete();
        await run;
      }
      expect(ids(2), ['first']);
    },
  );

  test(
    'a call pause while the journal is pending holds its later send',
    () async {
      await queue(2, 'first');
      final held = Completer<void>();
      service.onMessageStored = (_, _) => held.future;
      final run = flush();
      await barrier();
      service.backgroundStashPaused = true;
      held.complete();
      await run;
      expect(ids(2), isEmpty);
      service.backgroundStashPaused = false;
      await flush();
      expect(ids(2), ['first']);
    },
  );
}
