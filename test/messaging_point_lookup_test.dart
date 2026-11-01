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
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List.fromList(List.filled(32, n)));

class _ObservedStorage extends HiddenVolumeStorage {
  _ObservedStorage(super.opener);
  _ObservedStorage.async(super.opener) : super.async();
  int fullReads = 0, projectedRows = 0, pointReads = 0;

  void resetCounts() {
    fullReads = 0;
    projectedRows = 0;
    pointReads = 0;
  }

  @override
  Future<List<Message>> loadMessages(
    String conversationId, {
    int? limit,
  }) async {
    fullReads++;
    final rows = await super.loadMessages(conversationId, limit: limit);
    projectedRows += rows.length;
    return rows;
  }

  @override
  Future<Message?> loadMessageById(String conversationId, String messageId) {
    pointReads++;
    return super.loadMessageById(conversationId, messageId);
  }
}

class _Link extends LoopbackTransport {
  _Link() : super(localNodeId: _id(1));

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {}
}

void main() {
  final peer = _id(2), other = _id(4);
  final native = Platform.environment['XVEIL_POINT_LOOKUP_NATIVE'] == '1';
  late _ObservedStorage storage;
  late MessagingService service;
  Directory? directory;

  setUp(() async {
    if (native) {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      directory = await Directory.systemTemp.createTemp('xveil-point-lookup-');
      final path = '${directory!.path}/fixture.hv';
      HvKvLogStore(
        hv.HvSpace.create(
          path: path,
          password: Uint8List.fromList(utf8.encode('fixture')),
          argon: hv.ArgonPreset.light,
        ),
      ).close();
      storage = _ObservedStorage.async(workerSpaceOpener(path));
    } else {
      storage = _ObservedStorage(FakeHvContainer().passwordOpener);
    }
    await storage.open(password: 'fixture', createIfMissing: true);
    for (final p in [peer, other]) {
      await storage.upsertContact(
        Contact(nodeId: p, status: ContactStatus.accepted),
      );
    }
    service = MessagingService(_Link(), storage);
  });

  tearDown(() async {
    await service.dispose();
    await storage.close();
    await directory?.delete(recursive: true);
    directory = null;
  });

  Future<void> seed(
    NodeId to,
    String id, {
    bool outgoing = false,
    int seq = 1,
  }) => storage.appendMessage(
    Message(
      id: id,
      conversationId: to.hex,
      direction: outgoing
          ? MessageDirection.outgoing
          : MessageDirection.incoming,
      body: 'original-$id',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1000 + seq),
      status: MessageStatus.delivered,
      author: outgoing ? _id(1).hex : to.hex,
      seq: seq,
    ),
  );

  Future<bool> mirror(String id) => service.applyMirroredMessage(
    peer: peer,
    msgId: id,
    direction: MessageDirection.outgoing,
    body: 'mirror-$id',
    tsMs: 2000,
    status: MessageStatus.delivered,
  );

  Future<void> receive(WireEnvelope frame) => service.deliverInbound(
    InboundMessage(
      src: peer,
      provenance: SenderProvenance.sessionPeer,
      payload: frame.encode(),
    ),
  );

  for (final baseRows in [0, 500, 2000]) {
    test(
      '100 mirrors use point lookups with $baseRows existing rows',
      () async {
        for (var i = 0; i < baseRows; i++) {
          await seed(peer, 'base-$i', outgoing: true, seq: i + 1);
        }
        storage.resetCounts();
        final watch = Stopwatch()..start();
        for (var i = 0; i < 100; i++) {
          expect(await mirror('new-$i'), isTrue);
        }
        watch.stop();
        final fullReads = storage.fullReads,
            projectedRows = storage.projectedRows;
        final pointReads = storage.pointReads;
        final rows = await storage.loadMessages(peer.hex);
        expect(rows, hasLength(baseRows + 100));
        expect(rows.map((m) => m.id).toSet(), hasLength(baseRows + 100));
        expect(rows.every((m) => m.status == MessageStatus.delivered), isTrue);
        // Counts prove work avoided; elapsed time is evidence, never a test gate.
        // ignore: avoid_print
        print(
          'MESSAGE_POINT_LOOKUP ${jsonEncode({'baseRows': baseRows, 'workerBacked': native, 'mirrors': 100, 'fullReads': fullReads, 'projectedRows': projectedRows, 'pointReads': pointReads, 'elapsedUs': watch.elapsedMicroseconds})}',
        );
        expect(
          fullReads,
          0,
          reason:
              'a single-ID question must not project and sort the entire chat',
        );
        expect(pointReads, greaterThanOrEqualTo(100));
      },
      timeout: Timeout(
        native ? const Duration(minutes: 2) : const Duration(seconds: 30),
      ),
    );
  }

  test(
    'indexed mirror dedup stays conversation scoped and respects tombstones',
    () async {
      await seed(other, 'shared');
      await seed(peer, 'gone');
      await storage.deleteMessage(peer.hex, 'gone');
      storage.resetCounts();

      expect(await mirror('shared'), isTrue);
      expect(await mirror('shared'), isFalse);
      expect(await mirror('gone'), isFalse);
      expect(
        (await storage.loadMessageById(other.hex, 'shared'))!.body,
        'original-shared',
      );
      expect(
        (await storage.loadMessageById(peer.hex, 'shared'))!.body,
        'mirror-shared',
      );
      expect(await storage.loadMessageById(peer.hex, 'gone'), isNull);
      expect(await storage.isMessageDeleted(peer.hex, 'gone'), isTrue);
      expect(storage.fullReads, 0);
    },
  );

  test(
    'indexed mutation checks preserve author and conversation boundaries',
    () async {
      await seed(peer, 'incoming');
      await seed(peer, 'outgoing', outgoing: true, seq: 2);
      await seed(other, 'elsewhere');
      storage.resetCounts();

      await receive(const WireEnvelope.edit('incoming', 'edited', seq: 3));
      await receive(const WireEnvelope.edit('outgoing', 'forged', seq: 4));
      await receive(const WireEnvelope.del('outgoing'));
      await receive(const WireEnvelope.edit('elsewhere', 'wrong chat', seq: 5));
      await receive(const WireEnvelope.del('elsewhere'));

      expect(
        (await storage.loadMessageById(peer.hex, 'incoming'))!.body,
        'edited',
      );
      expect(
        (await storage.loadMessageById(peer.hex, 'outgoing'))!.body,
        'original-outgoing',
      );
      expect(
        (await storage.loadMessageById(other.hex, 'elsewhere'))!.body,
        'original-elsewhere',
      );
      expect(await storage.loadMessageById(peer.hex, 'elsewhere'), isNull);
      expect(storage.fullReads, 0);
    },
  );
}
