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
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Store extends HiddenVolumeStorage {
  _Store(String path) : super.async(workerSpaceOpener(path));
  final entered = Completer<void>(), release = Completer<void>();
  bool armed = true;
  Message? staged;
  @override
  Future<Message> appendMessage(Message message) async {
    final stored = await super.appendMessage(message);
    if (armed) {
      armed = false;
      staged = stored;
      entered.complete();
      await release.future;
    }
    return stored;
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
  for (final shape in [
    'incoming',
    'outgoing',
    'legacy-file',
    'pending-delete',
  ]) {
    test(
      'native append expiry $shape does not publish after commit gate',
      () async {
        expect(
          ensureHiddenVolumeLoaded(
            dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
          ),
          isTrue,
        );
        final dir = await Directory.systemTemp.createTemp(
          'xveil-store-expiry-native-',
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
        final storage = _Store(path), transport = _Capture();
        final peer = _id(2);
        var now = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch,
        );
        final service = MessagingService(transport, storage, now: () => now);
        final published = <String>[];
        var deletions = 0;
        service.onMessageDeleted = (_, _) {
          deletions++;
        };
        service.onMessageStored = (_, row) => published.add(row.body);
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
        Future<void> receive(WireEnvelope e) => service.deliverInbound(
          InboundMessage(
            src: peer,
            provenance: SenderProvenance.sessionPeer,
            payload: e.encode(),
          ),
        );
        if (shape == 'pending-delete') {
          await receive(const WireEnvelope.del('native-append-post'));
        }
        Future<Object?> accepting;
        if (shape == 'outgoing') {
          accepting = service.sendText(peer, 'NATIVE_EXPIRES_WHILE_APPEND');
        } else if (shape == 'legacy-file') {
          await receive(
            fileMetaEnvelope(
              transferId: 'native-append-file',
              name: 'NATIVE_EXPIRES_WHILE_APPEND.bin',
              seq: 1,
              size: 2,
              count: 1,
              sentAtMs: now.millisecondsSinceEpoch,
            ),
          );
          accepting = receive(
            fileChunkEnvelope(
              transferId: 'native-append-file',
              index: 0,
              total: 1,
              data: Uint8List.fromList([1, 2]),
            ),
          );
        } else {
          accepting = receive(
            WireEnvelope.message(
              'NATIVE_EXPIRES_WHILE_APPEND',
              id: 'native-append-post',
              seq: 1,
              sentAtMs: now.millisecondsSinceEpoch,
            ),
          );
        }
        try {
          await storage.entered.future.timeout(const Duration(seconds: 10));
          expect(
            await storage.loadMessageById(peer.hex, storage.staged!.id),
            isNotNull,
          );
          expect(published, isEmpty);
          expect(
            transport.sent.where(
              (e) => e.kind == WireKind.ack || e.kind == WireKind.message,
            ),
            isEmpty,
          );
          now = now.add(const Duration(seconds: 30));
        } finally {
          storage.release.complete();
        }
        final result = await accepting;
        if (shape == 'outgoing') expect(result, isFalse);
        final original = storage.staged!;
        expect(deletions, 1);
        expect(published, isEmpty);
        expect(await storage.isMessageDeleted(peer.hex, original.id), isTrue);
        expect(await storage.loadMessageById(peer.hex, original.id), isNull);
        if (shape == 'legacy-file') {
          expect(await storage.hasFile(original.fileId!), isFalse);
        }
        if (shape != 'outgoing') {
          expect(
            transport.sent.any(
              (e) => e.kind == WireKind.ack && e.id == original.id,
            ),
            isTrue,
          );
        }
        expect(
          await service.sendText(peer, 'NATIVE_FRESH_APPEND_CONTROL'),
          isTrue,
        );
        await service.dispose();
        await storage.close();
        final raw = (await workerSpaceOpener(path)(
          password: password,
          create: false,
        ))!;
        try {
          var fresh = 0;
          for (
            var ns = Ns.messageLogShardFirst;
            ns <= Ns.messageLogShardLast;
            ns++
          ) {
            for (final row in await raw.iterLogRange(
              namespace: ns,
              limit: 8192,
            )) {
              final body = utf8.decode(row.payload, allowMalformed: true);
              expect(body.contains('NATIVE_EXPIRES_WHILE_APPEND'), isFalse);
              if (body.contains('NATIVE_FRESH_APPEND_CONTROL')) fresh++;
            }
          }
          expect(fresh, 1);
        } finally {
          await raw.close();
        }
        final reopened = HiddenVolumeStorage.async(workerSpaceOpener(path));
        try {
          expect(await reopened.open(password: 'fixture'), isTrue);
          expect(
            await reopened.isMessageDeleted(peer.hex, original.id),
            isTrue,
          );
          expect(
            (await reopened.loadMessages(peer.hex)).single.body,
            'NATIVE_FRESH_APPEND_CONTROL',
          );
          final slots = await reopened.loadEventsSince(
            peer.hex,
            original.author!,
            0,
          );
          final slot = slots.singleWhere((e) => e.seq == original.seq);
          expect(slot.body, isNull);
          expect(slot.target, isNull);
        } finally {
          await reopened.close();
        }
      },
    );
  }
}
