@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Capture implements VeilTransport {
  _Capture(this.me);
  final NodeId me;
  final _incoming = StreamController<InboundMessage>.broadcast();
  final requests = <Map<String, dynamic>>[];
  Completer<void>? completed;
  int expectedRequests = 0;
  @override
  Future<NodeId> nodeId() async => me;
  @override
  Stream<InboundMessage> messages() => _incoming.stream;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final env = WireEnvelope.decode(payload);
    if (env.kind == WireKind.deviceGone) {
      requests.add(jsonDecode(env.body) as Map<String, dynamic>);
      if (requests.length == expectedRequests) completed!.complete();
    }
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
  Future<void> dispose() => _incoming.close();
}

class _ReadCountingStorage extends HiddenVolumeStorage {
  _ReadCountingStorage.fake() : super.fromStore(FakeKvLogStore());
  _ReadCountingStorage.native(super.opener) : super.async();
  int displayRows = 0, rawRows = 0;

  @override
  Future<List<Message>> loadMessages(
    String conversationId, {
    int? limit,
  }) async {
    final rows = await super.loadMessages(conversationId, limit: limit);
    displayRows += rows.length;
    return rows;
  }

  @override
  Future<List<Message>> loadMessageRows(String conversationId) async {
    final rows = await super.loadMessageRows(conversationId);
    rawRows += rows.length;
    return rows;
  }
}

void main() {
  test(
    'older conversations visit every older page across restarts at 100000 rows',
    () async {
      final native = Platform.environment['XVEIL_ERASURE_NATIVE'] == '1';
      Directory? runtime;
      if (native) {
        expect(
          ensureHiddenVolumeLoaded(
            dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
          ),
          isTrue,
        );
        runtime = await Directory.systemTemp.createTemp(
          'xveil-erasure-rotation-',
        );
        final evidence = Platform.environment['XVEIL_ERASURE_EVIDENCE_DIR'];
        if (evidence != null) {
          await File(
            '$evidence/runtime-private.json',
          ).writeAsString(jsonEncode({'root': runtime.path, 'pid': pid}));
        }
        addTearDown(() => runtime!.delete(recursive: true));
      }
      Future<_ReadCountingStorage> open(String label) async {
        if (!native) return _ReadCountingStorage.fake();
        final path = '${runtime!.path}/$label.hv';
        HvKvLogStore(
          hv.HvSpace.create(
            path: path,
            password: Uint8List.fromList(utf8.encode(label)),
            argon: hv.ArgonPreset.light,
          ),
        ).close();
        final store = _ReadCountingStorage.native(workerSpaceOpener(path));
        expect(await store.open(password: label), isTrue);
        return store;
      }

      final store = await open('receiver');
      final source = await open('source');
      addTearDown(store.close);
      addTearDown(source.close);
      final peer = _id(1),
          sibling = _id(201),
          identity = _id(202),
          me = _id(203);
      final base = DateTime.utc(2020);
      Message row(int c, int i, int day) => Message(
        id: 'c$c-m$i',
        conversationId: _id(c).hex,
        direction: MessageDirection.incoming,
        body: 'body-$c-$i',
        timestamp: base.add(Duration(days: day, milliseconds: i)),
        status: MessageStatus.delivered,
        author: _id(c).hex,
        seq: i + 1,
        positionVerified: true,
      );
      final expected = <String, Message>{};
      Future<void> seed(int c, int count, int day) async {
        final p = _id(c);
        await store.upsertContact(
          Contact(nodeId: p, status: ContactStatus.accepted),
        );
        for (
          var start = 0;
          start < count;
          start += preparedMessageBatchMaxRows
        ) {
          final end = (start + preparedMessageBatchMaxRows).clamp(0, count);
          final batch = [for (var i = start; i < end; i++) row(c, i, day)];
          expected.addAll({for (final m in batch) m.id: m});
          expect(
            await store.appendMissingMessageBatch(
              batch,
              beforeCommit: () async {},
            ),
            List.filled(batch.length, PreparedMessageWrite.appended),
          );
        }
      }

      await seed(1, 1000, 0);
      await seed(2, 1, 1);
      for (var c = 3; c <= 31; c++) {
        await seed(c, 1, c);
      }
      await seed(32, 98970, 32);
      expect(expected.length, 100000);
      const erased = ['c1-m750', 'c1-m550', 'c1-m350', 'c1-m150'];
      for (final id in erased) {
        await source.appendMessage(expected[id]!);
        await source.deleteMessage(peer.hex, id);
      }
      var now = DateTime.utc(2021);
      final transport = _Capture(me);
      final pages = <Set<String>>[];
      final queryObservations = <Map<String, Object>>[];
      for (var round = 1; round <= 8; round++) {
        // Recreate the messaging layer every pass: progress is durable, not RAM.
        final service = MessagingService(transport, store, now: () => now)
          ..start();
        service.selfIdentityHex = () async => identity.hex;
        service.isOwnDevice = (p) async => p == identity || p == sibling;
        service.myOtherDevices = () async => [sibling];
        try {
          transport.requests.clear();
          transport.expectedRequests = round.isOdd ? 32 : 33;
          transport.completed = Completer<void>();
          final beforeDisplay = store.displayRows, beforeRaw = store.rawRows;
          final queryTimer = Stopwatch()..start();
          await service.deliverInbound(
            InboundMessage(
              src: identity,
              srcDevice: sibling,
              payload: WireEnvelope.presence(sibling.hex, reply: true).encode(),
              provenance: SenderProvenance.signed,
            ),
          );
          await transport.completed!.future;
          await Future<void>.delayed(Duration.zero);
          queryTimer.stop();
          queryObservations.add({
            'round': round,
            'elapsedMicros': queryTimer.elapsedMicroseconds,
            'displayRows': store.displayRows - beforeDisplay,
            'rawRows': store.rawRows - beforeRaw,
            'requests': transport.requests.length,
            'requestJsonBytes': transport.requests.fold<int>(
              0,
              (total, request) =>
                  total + utf8.encode(jsonEncode(request)).length,
            ),
            'requestDigest': crypto.sha256
                .convert(utf8.encode(jsonEncode(transport.requests)))
                .toString(),
          });
          final asked = <String>{};
          for (final request in transport.requests) {
            expect((request['k'] as List).length, lessThanOrEqualTo(200));
            if (request['q'] != peer.hex) continue;
            final keys = (request['k'] as List).cast<String>().toSet();
            asked.addAll(keys);
            final ids = [
              for (final id in await source.deletedMessageIds(peer.hex))
                if (keys.contains(ownEchoKey(id))) id,
            ];
            if (ids.isNotEmpty) {
              await service.deliverInbound(
                InboundMessage(
                  src: identity,
                  srcDevice: sibling,
                  payload: WireEnvelope.deviceGone(
                    jsonEncode({'d': sibling.hex, 'a': peer.hex, 'ids': ids}),
                  ).encode(),
                  provenance: SenderProvenance.signed,
                ),
              );
            }
          }
          if (round.isEven) pages.add(asked);
          expect(
            await store.getSetting('device.erasure.round.v1:${sibling.hex}'),
            '$round',
          );
        } finally {
          await service.dispose();
        }
        now = now.add(const Duration(minutes: 11));
      }
      if (native) {
        await store.close();
        expect(await store.open(password: 'receiver'), isTrue);
      }
      final remaining = await store.loadMessageRows(peer.hex);
      final retainedTargets = [
        for (final id in erased)
          if (remaining.any((m) => m.id == id)) id,
      ];
      var count = 0, exact = 0;
      final unique = <String>{};
      for (var c = 1; c <= 32; c++) {
        for (final actual in await store.loadMessageRows(_id(c).hex)) {
          count++;
          unique.add(actual.id);
          final e = expected[actual.id];
          if (e != null &&
              !erased.contains(actual.id) &&
              actual.conversationId == e.conversationId &&
              actual.body == e.body &&
              actual.author == e.author &&
              actual.seq == e.seq &&
              actual.status == e.status &&
              actual.timestamp.millisecondsSinceEpoch ==
                  e.timestamp.millisecondsSinceEpoch &&
              actual.orderAuthor == e.orderAuthor &&
              actual.orderSeq == e.orderSeq) {
            exact++;
          }
        }
      }
      final evidence = Platform.environment['XVEIL_ERASURE_EVIDENCE_DIR'];
      if (evidence != null) {
        await File('$evidence/result-private.json').writeAsString(
          jsonEncode({
            'native': native,
            'coldReopened': native,
            'initialRows': expected.length,
            'rounds': 8,
            'expectedRows': 99996,
            'actualRows': count,
            'uniqueRows': unique.length,
            'exactRows': exact,
            'retainedDeleted': retainedTargets.length,
            'targetPasses': pages.length,
            'queryObservations': queryObservations,
          }),
        );
      }
      expect(
        retainedTargets,
        isEmpty,
        reason:
            'lockstep conversation/page rotations must not omit half the older pages forever',
      );
      expect(count, 99996);
      expect(unique.length, count);
      expect(exact, count);
    },
  );
}
