import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/domain/file_download_policy.dart';
import 'package:xveil/state/messaging.dart';
import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Storage extends HiddenVolumeStorage {
  _Storage(super.opener);
  int blobWrites = 0;
  bool refuseExpiry = false;
  @override
  Future<bool> recordExpiredMessage(
    String conversation,
    String id, {
    String? author,
    int? seq,
  }) {
    if (refuseExpiry) throw StateError('fixture expiry unavailable');
    return super.recordExpiredMessage(
      conversation,
      id,
      author: author,
      seq: seq,
    );
  }

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
}

class _Link implements VeilTransport {
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
  }) async => sent.add(WireEnvelope.decode(payload));
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
  final peer = _id(2);
  late FakeHvContainer container;
  late _Storage storage;
  late _Link link;
  late MessagingService service;
  late DateTime now;
  late List<String> published;
  setUp(() async {
    now = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
    );
    container = FakeHvContainer();
    storage = _Storage(container.passwordOpener);
    await storage.open(password: 'fixture', createIfMissing: true);
    await storage.upsertContact(
      Contact(
        nodeId: peer,
        status: ContactStatus.accepted,
        disappearingTtlSeconds: 30,
      ),
    );
    link = _Link();
    service = MessagingService(link, storage, now: () => now);
    published = [];
    service.onMessageStored = (_, m) => published.add(m.body);
  });
  tearDown(() async {
    await service.dispose();
    await link.dispose();
    await storage.close();
  });
  Future<void> receive(WireEnvelope e) => service.deliverInbound(
    InboundMessage(
      src: peer,
      provenance: SenderProvenance.sessionPeer,
      payload: e.encode(),
    ),
  );
  Future<void> meta(DateTime at, {String id = 'legacy-expired'}) => receive(
    fileMetaEnvelope(
      transferId: id,
      name: 'PRIVATE_OLD_FILE.png',
      size: 2,
      count: 2,
      seq: 1,
      sentAtMs: at.millisecondsSinceEpoch,
    ),
  );
  Future<void> chunk(int index, {String id = 'legacy-expired'}) => receive(
    fileChunkEnvelope(
      transferId: id,
      index: index,
      total: 2,
      data: Uint8List.fromList([index + 1]),
    ),
  );
  bool ack(String id) =>
      link.sent.any((e) => e.kind == WireKind.ack && e.id == id);
  ContentManifest manifest(DateTime at, {String id = 'content-expired'}) =>
      ContentManifest.fromBytes(
        'PRIVATE_OLD_FILE.png',
        Uint8List.fromList([1, 2]),
      ).withEvent(
        msgId: id,
        author: peer.hex,
        seq: 1,
        ts: at.millisecondsSinceEpoch,
      );
  WireEnvelope offer(ContentManifest m, bool ref) => contentManifestEnvelope(
    jsonEncode(
      ref
          ? {
              'ref': 1,
              'id': m.contentId,
              'name': m.name,
              'size': m.size,
              'mid': m.msgId,
              'sq': m.seq,
              'mts': m.ts,
              'au': m.author,
            }
          : m.toJson(),
    ),
  );
  bool rawContains(String needle) => [
    for (var ns = Ns.messageLogShardFirst; ns <= Ns.messageLogShardLast; ns++)
      for (final row
          in container
              .rawStoreFor('fixture')!
              .iterLogRange(namespace: ns, limit: 8192))
        utf8.decode(row.payload),
  ].any((s) => s.contains(needle));

  test(
    'expired legacy meta/chunks cannot write blob, message or own-device publication',
    () async {
      await meta(now.subtract(const Duration(seconds: 31)));
      await chunk(0);
      await chunk(1);
      expect(storage.blobWrites, 0);
      expect(await storage.loadMessages(peer.hex), isEmpty);
      expect(published, isEmpty);
      expect(
        await storage.isMessageDeleted(peer.hex, 'legacy-expired'),
        isTrue,
      );
      expect(ack('legacy-expired'), isTrue);
      expect(rawContains('PRIVATE_OLD_FILE'), isFalse);
    },
  );
  test(
    'legacy transfer expiring between chunks is dropped before assembly persistence',
    () async {
      await meta(now.subtract(const Duration(seconds: 29)));
      await chunk(0);
      expect(storage.blobWrites, 0);
      now = now.add(const Duration(seconds: 1));
      await chunk(1);
      expect(storage.blobWrites, 0);
      expect(await storage.loadMessages(peer.hex), isEmpty);
      expect(
        await storage.isMessageDeleted(peer.hex, 'legacy-expired'),
        isTrue,
      );
      expect(ack('legacy-expired'), isTrue);
    },
  );
  test('expired legacy gap-fill query does not solicit old chunks', () async {
    await receive(
      fileQueryEnvelope(
        transferId: 'legacy-expired',
        name: 'PRIVATE_OLD_FILE.png',
        seq: 1,
        sentAtMs: now
            .subtract(const Duration(seconds: 31))
            .millisecondsSinceEpoch,
      ),
    );
    expect(link.sent.any((e) => e.kind == WireKind.fileNack), isFalse);
    expect(ack('legacy-expired'), isTrue);
    expect(await storage.isMessageDeleted(peer.hex, 'legacy-expired'), isTrue);
  });
  for (final ref in [false, true]) {
    test(
      'expired ${ref ? 'ref' : 'manifest'} is neither surfaced nor retained for download',
      () async {
        if (ref) {
          await service.setFileDownloadPolicy(
            const FileDownloadPolicy(autoMaxBytes: 0, blockedExts: {}),
          );
        }
        final m = manifest(now.subtract(const Duration(seconds: 30)));
        await receive(offer(m, ref));
        await pumpEventQueue();
        expect(await storage.loadMessages(peer.hex), isEmpty);
        expect(service.offeredContentCount, 0);
        expect(published, isEmpty);
        expect(
          link.sent.any(
            (e) =>
                e.kind == WireKind.pieceRequest ||
                e.kind == WireKind.contentReoffer,
          ),
          isFalse,
        );
        expect(await storage.isMessageDeleted(peer.hex, m.msgId!), isTrue);
        expect(ack(m.msgId!), isTrue);
        expect(rawContains('PRIVATE_OLD_FILE'), isFalse);
      },
    );
    test(
      'deleted live ${ref ? 'ref' : 'manifest'} cannot restart an unsolicited download',
      () async {
        if (ref) {
          await service.setFileDownloadPolicy(
            const FileDownloadPolicy(autoMaxBytes: 0, blockedExts: {}),
          );
        }
        final m = manifest(now);
        await storage.recordExpiredMessage(
          peer.hex,
          m.msgId!,
          author: peer.hex,
          seq: 1,
        );
        await receive(offer(m, ref));
        await pumpEventQueue();
        expect(service.offeredContentCount, 0);
        expect(await storage.loadMessages(peer.hex), isEmpty);
        expect(
          link.sent.any(
            (e) =>
                e.kind == WireKind.pieceRequest ||
                e.kind == WireKind.contentReoffer,
          ),
          isFalse,
        );
      },
    );
    test(
      'failed expiry for ${ref ? 'ref' : 'manifest'} leaves message receipt retryable',
      () async {
        await service.setFileDownloadPolicy(
          const FileDownloadPolicy(autoMaxBytes: 0, blockedExts: {}),
        );
        final m = manifest(now.subtract(const Duration(seconds: 31)));
        storage.refuseExpiry = true;
        await receive(offer(m, ref));
        expect(ack(m.msgId!), isFalse);
        expect(service.offeredContentCount, 0);
        expect(await storage.loadMessages(peer.hex), isEmpty);
        storage.refuseExpiry = false;
        await receive(offer(m, ref));
        expect(ack(m.msgId!), isTrue);
        expect(await storage.isMessageDeleted(peer.hex, m.msgId!), isTrue);
      },
    );
  }
  test(
    'claimed query cannot create expiry evidence or poison later authenticated metadata',
    () async {
      final query = fileQueryEnvelope(
        transferId: 'legacy-expired',
        name: 'PRIVATE_OLD_FILE.png',
        seq: 1,
        sentAtMs: now
            .subtract(const Duration(seconds: 31))
            .millisecondsSinceEpoch,
      );
      await service.deliverInbound(
        InboundMessage(
          src: peer,
          provenance: SenderProvenance.claimed,
          payload: query.encode(),
        ),
      );
      expect(
        await storage.isMessageDeleted(peer.hex, 'legacy-expired'),
        isFalse,
      );
      expect(
        (await storage.conversationSync(peer.hex)).highWater[peer.hex],
        isNull,
      );
      expect(
        link.sent.any((e) => e.kind == WireKind.fileNack),
        isTrue,
        reason: 'the legacy read-only probe remains usable',
      );
      await meta(now);
      await chunk(0);
      await chunk(1);
      expect((await storage.loadMessages(peer.hex)).single.fileSize, 2);
    },
  );
  test(
    'metadata without a sender timestamp retains the first receipt clock across chunks',
    () async {
      await receive(
        fileMetaEnvelope(
          transferId: 'legacy-expired',
          name: 'PRIVATE_OLD_FILE.png',
          size: 2,
          count: 2,
          seq: 1,
        ),
      );
      await chunk(0);
      now = now.add(const Duration(seconds: 30));
      await chunk(1);
      expect(storage.blobWrites, 0);
      expect(
        await storage.isMessageDeleted(peer.hex, 'legacy-expired'),
        isTrue,
      );
    },
  );

  test(
    'new metadata cannot reset a live partial transfer original clock',
    () async {
      await meta(now.subtract(const Duration(seconds: 29)));
      await chunk(0);
      now = now.add(const Duration(seconds: 1));
      await meta(now);
      await chunk(1);
      expect(storage.blobWrites, 0);
      expect(
        await storage.isMessageDeleted(peer.hex, 'legacy-expired'),
        isTrue,
      );
    },
  );

  test('a fresh legacy transfer still saves the exact bytes', () async {
    await meta(now);
    await chunk(0);
    await chunk(1);
    final row = (await storage.loadMessages(peer.hex)).single;
    expect(row.fileName, 'PRIVATE_OLD_FILE.png');
    expect(await storage.loadFile(row.fileId!), Uint8List.fromList([1, 2]));
    expect(storage.blobWrites, 1);
    expect(ack('legacy-expired'), isTrue);
  });

  test(
    'a failed legacy expiry commit neither saves bytes nor acknowledges the message',
    () async {
      storage.refuseExpiry = true;
      await meta(now.subtract(const Duration(seconds: 31)));
      await chunk(0);
      await chunk(1);
      expect(ack('legacy-expired'), isFalse);
      expect(storage.blobWrites, 0);
      storage.refuseExpiry = false;
      await meta(now.subtract(const Duration(seconds: 31)));
      expect(ack('legacy-expired'), isTrue);
      expect(
        await storage.isMessageDeleted(peer.hex, 'legacy-expired'),
        isTrue,
      );
    },
  );

  for (final ref in [false, true]) {
    test(
      'expired ${ref ? 'ref' : 'manifest'} does not ban a fresh message sharing its blob',
      () async {
        final old = manifest(now.subtract(const Duration(seconds: 31)));
        await storage.storeFile(
          old.contentId,
          Uint8List.fromList([1, 2]),
          name: old.name,
        );
        await receive(offer(old, ref));
        final fresh = old.withEvent(
          msgId: 'content-fresh',
          seq: 2,
          ts: now.millisecondsSinceEpoch,
        );
        await receive(offer(fresh, ref));
        expect((await storage.loadMessages(peer.hex)).map((m) => m.id), [
          'content-fresh',
        ]);
        expect(
          await storage.loadFile(old.contentId),
          Uint8List.fromList([1, 2]),
        );
        expect(await storage.isMessageDeleted(peer.hex, old.msgId!), isTrue);
        expect(await storage.isMessageDeleted(peer.hex, fresh.msgId!), isFalse);
        expect(link.sent.any((e) => e.kind == WireKind.pieceRequest), isFalse);
      },
    );
  }
  for (final expired in [false, true]) {
    test(
      'eventless hint cannot revive expired named offer, expired=$expired',
      () async {
        await service.setFileDownloadPolicy(
          const FileDownloadPolicy(autoMaxBytes: 0, blockedExts: {}),
        );
        final base = ContentManifest.fromBytes(
          'PRIVATE_OLD_FILE.png',
          Uint8List.fromList([1, 2]),
        );
        await storage.appendMessage(
          Message(
            id: 'known-file-message',
            conversationId: peer.hex,
            direction: MessageDirection.incoming,
            body: 'existing offer',
            timestamp: expired
                ? now.subtract(const Duration(seconds: 31))
                : now,
            author: peer.hex,
            seq: 1,
            fileContentId: base.contentId,
            fileName: base.name,
            fileSize: base.size,
          ),
        );
        await receive(contentManifestEnvelope(jsonEncode(base.toJson())));
        expect((await storage.loadMessages(peer.hex)).map((m) => m.id), [
          'known-file-message',
        ]);
        expect(service.offeredContentCount, expired ? 0 : 1);
        expect(
          await storage.isMessageDeleted(peer.hex, base.contentId),
          isFalse,
          reason: 'the anonymous hint proves no new deletion slot',
        );
      },
    );
  }
}
