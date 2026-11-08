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
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/domain/file_download_policy.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Store extends HiddenVolumeStorage {
  _Store(String path) : super.async(workerSpaceOpener(path));
  final entered = Completer<void>(), release = Completer<void>();
  bool loseReply = false;
  int blobWrites = 0;
  @override
  Future<void> storeFile(
    String id,
    Uint8List bytes, {
    String? name,
    List<String> retireHints = const [],
  }) {
    blobWrites++;
    return super.storeFile(id, bytes, name: name, retireHints: retireHints);
  }

  @override
  Future<bool> recordExpiredMessage(
    String conversation,
    String id, {
    String? author,
    int? seq,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    final result = await super.recordExpiredMessage(
      conversation,
      id,
      author: author,
      seq: seq,
    );
    if (loseReply) {
      loseReply = false;
      throw StateError('fixture lost expiry reply');
    }
    return result;
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
  for (final shape in ['legacy', 'manifest', 'ref', 'manifest-lost-reply']) {
    test(
      'native expired media admission $shape is bodyless across cold reopen',
      () async {
        expect(
          ensureHiddenVolumeLoaded(
            dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
          ),
          isTrue,
        );
        final dir = await Directory.systemTemp.createTemp(
          'xveil-media-expiry-native-',
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
        final storage = _Store(path)..loseReply = shape.endsWith('lost-reply');
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
        await service.setFileDownloadPolicy(
          const FileDownloadPolicy(autoMaxBytes: 0, blockedExts: {}),
        );
        Future<void> receive(WireEnvelope e) => service.deliverInbound(
          InboundMessage(
            src: peer,
            provenance: SenderProvenance.sessionPeer,
            payload: e.encode(),
          ),
        );
        final ts = now
            .subtract(const Duration(seconds: 31))
            .millisecondsSinceEpoch;
        final manifest =
            ContentManifest.fromBytes(
              'NATIVE_EXPIRED_MEDIA.png',
              Uint8List.fromList([1, 2]),
            ).withEvent(
              msgId: 'expired-native-media',
              author: peer.hex,
              seq: 1,
              ts: ts,
            );
        final old = shape == 'legacy'
            ? fileMetaEnvelope(
                transferId: 'expired-native-media',
                name: 'NATIVE_EXPIRED_MEDIA.png',
                size: 2,
                count: 1,
                seq: 1,
                sentAtMs: ts,
              )
            : contentManifestEnvelope(
                jsonEncode(
                  shape == 'ref'
                      ? {
                          'ref': 1,
                          'id': manifest.contentId,
                          'name': manifest.name,
                          'size': manifest.size,
                          'mid': manifest.msgId,
                          'sq': 1,
                          'mts': ts,
                        }
                      : manifest.toJson(),
                ),
              );
        final receiving = receive(old);
        try {
          await storage.entered.future.timeout(const Duration(seconds: 10));
          expect(transport.sent.where((e) => e.kind == WireKind.ack), isEmpty);
          expect(
            await storage.isMessageDeleted(peer.hex, 'expired-native-media'),
            isFalse,
          );
        } finally {
          storage.release.complete();
          await receiving;
        }
        if (shape.endsWith('lost-reply')) {
          expect(transport.sent.where((e) => e.kind == WireKind.ack), isEmpty);
          expect(
            await storage.isMessageDeleted(peer.hex, 'expired-native-media'),
            isTrue,
          );
          await receive(old);
        }
        if (shape == 'legacy') {
          await receive(
            fileChunkEnvelope(
              transferId: 'expired-native-media',
              index: 0,
              total: 1,
              data: Uint8List.fromList([1, 2]),
            ),
          );
        }
        expect(
          transport.sent.any(
            (e) => e.kind == WireKind.ack && e.id == 'expired-native-media',
          ),
          isTrue,
        );
        expect(
          transport.sent.any(
            (e) =>
                e.kind == WireKind.pieceRequest ||
                e.kind == WireKind.contentReoffer,
          ),
          isFalse,
        );
        expect(service.offeredContentCount, 0);
        expect(storage.blobWrites, 0);
        expect(await storage.loadMessages(peer.hex), isEmpty);
        await receive(
          WireEnvelope.message(
            'NATIVE_FRESH_MEDIA_CONTROL',
            id: 'live',
            seq: 2,
            sentAtMs: now.millisecondsSinceEpoch,
          ),
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
              expect(body.contains('NATIVE_EXPIRED_MEDIA'), isFalse);
              if (body.contains('NATIVE_FRESH_MEDIA_CONTROL')) fresh++;
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
            await reopened.isMessageDeleted(peer.hex, 'expired-native-media'),
            isTrue,
          );
          expect((await reopened.loadMessages(peer.hex)).map((m) => m.id), [
            'live',
          ]);
          expect(
            (await reopened.conversationSync(peer.hex)).highWater[peer.hex],
            2,
          );
        } finally {
          await reopened.close();
        }
      },
      skip: Platform.environment['XVEIL_HV_DYLIB'] == null
          ? 'set XVEIL_HV_DYLIB to a qualified native library'
          : false,
    );
  }
}
