@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/storage.dart' show MessageDeletionIntent;
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Store extends HiddenVolumeStorage {
  _Store(String path) : super.async(workerSpaceOpener(path));
  final entered = Completer<void>(), release = Completer<void>();
  bool loseReply = false;
  @override
  Future<void> deleteMessage(
    String conversation,
    String id, {
    MessageDeletionIntent? intent,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    await super.deleteMessage(conversation, id, intent: intent);
    if (loseReply) throw StateError('fixture lost reply after durable erase');
  }
}

class _Capture implements VeilTransport {
  final input = StreamController<InboundMessage>.broadcast();
  final sent = <WireEnvelope>[];
  @override
  Future<NodeId> nodeId() async => _id(1);
  @override
  Stream<InboundMessage> messages() => input.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    sent.add(WireEnvelope.decode(payload));
  }

  @override
  Future<void> sendWithReply(NodeId dst, Uint8List payload) =>
      send(dst, payload);
  @override
  Future<void> sendReply(int replyId, Uint8List payload) async {}
  @override
  Stream<int> sessionCount() => Stream.value(0);
  @override
  Future<List<PeerInfo>> peers() async => [];
  @override
  Future<void> dispose() => input.close();
}

void main() {
  for (final loseReply in [false, true]) {
    test(
      'native peer history void waits for durable erase, lost reply=$loseReply',
      () async {
        expect(
          ensureHiddenVolumeLoaded(
            dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
          ),
          isTrue,
        );
        final dir = await Directory.systemTemp.createTemp(
          'xveil-peer-expiry-native-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final path = '${dir.path}/store.hv';
        final password = Uint8List.fromList(utf8.encode('fixture'));
        HvKvLogStore(
          hv.HvSpace.create(
            path: path,
            password: password,
            argon: hv.ArgonPreset.light,
          ),
        ).close();
        final storage = _Store(path)..loseReply = loseReply;
        final transport = _Capture();
        final peer = _id(2);
        final now = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch,
        );
        final service = MessagingService(transport, storage, now: () => now);
        addTearDown(() async {
          if (!storage.release.isCompleted) storage.release.complete();
          await service.dispose();
          await transport.dispose();
          await storage.close();
        });
        expect(await storage.open(password: 'fixture'), isTrue);
        await storage.upsertContact(
          Contact(
            nodeId: peer,
            status: ContactStatus.accepted,
            disappearingTtlSeconds: 30,
          ),
        );
        for (final row in [
          ('old', 1, now.subtract(const Duration(seconds: 31))),
          ('live', 3, now),
        ]) {
          await storage.appendMessage(
            Message(
              id: row.$1,
              conversationId: peer.hex,
              direction: MessageDirection.outgoing,
              body: row.$1,
              timestamp: row.$3,
              author: _id(1).hex,
              seq: row.$2,
              status: MessageStatus.delivered,
            ),
          );
        }
        await storage.editMessage(peer.hex, 'old', 'expired edit', seq: 2);
        expect(
          (await storage.loadMessageById(peer.hex, 'old'))!.body,
          'expired edit',
        );
        final request = service.deliverInbound(
          InboundMessage(
            src: peer,
            provenance: SenderProvenance.sessionPeer,
            payload: WireEnvelope.sync(jsonEncode({'hw': {}})).encode(),
          ),
        );
        await storage.entered.future.timeout(const Duration(seconds: 10));
        expect(
          transport.sent.where((e) => e.kind == WireKind.voidSeq),
          isEmpty,
        );
        expect(await storage.isMessageDeleted(peer.hex, 'old'), isFalse);
        storage.release.complete();
        await request;
        expect(
          transport.sent
              .where((e) => e.kind == WireKind.voidSeq)
              .map((e) => e.seq),
          [1, 2],
        );
        expect(
          transport.sent.where((e) => e.kind == WireKind.message).single.body,
          'live',
        );
        expect(
          transport.sent.any((e) => e.body.contains('expired edit')),
          isFalse,
        );
        await service.dispose();
        await storage.close();
        final reopened = HiddenVolumeStorage.async(workerSpaceOpener(path));
        try {
          expect(await reopened.open(password: 'fixture'), isTrue);
          expect(await reopened.isMessageDeleted(peer.hex, 'old'), isTrue);
          expect(await reopened.loadMessageById(peer.hex, 'old'), isNull);
          expect((await reopened.loadMessages(peer.hex)).map((m) => m.id), [
            'live',
          ]);
        } finally {
          await reopened.close();
        }
      },
    );
  }
}
