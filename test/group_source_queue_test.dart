import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/veil_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Link extends LoopbackTransport {
  _Link() : super(localNodeId: _id(1));
  final entered = Completer<void>(), release = Completer<void>();
  final input = StreamController<InboundMessage>.broadcast();
  final sent = <WireEnvelope>[];
  final acknowledgements = <String>[];
  int active = 0, maxActive = 0;
  bool hold = true;
  bool failGroups = false;
  Future<void> Function(WireEnvelope)? afterGroupSend;

  @override
  Stream<InboundMessage> messages() => input.stream;

  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final wire = WireEnvelope.decode(payload);
    if (wire.kind == WireKind.groupEntry ||
        wire.kind == WireKind.groupEntryChunk) {
      active++;
      if (active > maxActive) maxActive = active;
      try {
        if (failGroups) throw StateError('fixture transport refusal');
        if (hold && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        sent.add(wire);
        await afterGroupSend?.call(wire);
      } finally {
        active--;
      }
    }
    if (wire.kind == WireKind.ack) acknowledgements.add(wire.id!);
  }

  void inject(WireEnvelope frame) => input.add(
    InboundMessage(
      src: _id(2),
      provenance: SenderProvenance.sessionPeer,
      payload: frame.encode(),
    ),
  );

  @override
  Future<void> dispose() async {
    await input.close();
    await super.dispose();
  }
}

Future<void> _until(Future<bool> Function() check) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!await check() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _FailedOutbox extends HiddenVolumeStorage {
  _FailedOutbox(super.opener);
  @override
  Future<void> enqueueOutboxFrame(
    String id,
    String peer,
    Uint8List wire,
  ) async => throw StateError('fixture persistence refusal');
}

class _DeferredBatchRetirement extends HiddenVolumeStorage {
  _DeferredBatchRetirement(super.opener);
  final entered = Completer<void>(), release = Completer<void>();

  @override
  Future<List<String>> ackOutboxFrames(
    Iterable<String> frameIds, {
    required String fromPeerHex,
  }) async {
    entered.complete();
    await release.future;
    return super.ackOutboxFrames(frameIds, fromPeerHex: fromPeerHex);
  }
}

Future<({HiddenVolumeStorage store, _Link link, MessagingService service})>
_rig({HiddenVolumeStorage? supplied, DateTime Function()? now}) async {
  final store =
      supplied ?? HiddenVolumeStorage(FakeHvContainer().passwordOpener);
  await store.open(password: 'fixture', createIfMissing: true);
  await store.upsertContact(
    Contact(nodeId: _id(2), status: ContactStatus.accepted),
  );
  final link = _Link();
  final service = MessagingService(link, store, now: now);
  addTearDown(() async {
    if (!link.release.isCompleted) link.release.complete();
    await service.dispose();
    await link.dispose();
    await store.close();
  });
  return (store: store, link: link, service: service);
}

void main() {
  test('ordinary snapshots retain their initial transport wait', () async {
    final r = await _rig();
    var completed = false;
    final send = r.service
        .sendGroupSnapshot(_id(2), 'ab' * 32, '{}')
        .then((_) => completed = true);
    await r.link.entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    r.link.release.complete();
    await send;
    expect(completed, isTrue);
    expect(await r.store.pendingOutboxFrames(), hasLength(1));
  });

  for (final chunked in [false, true]) {
    test(
      'a held group sync response does not hold later chat (chunked=$chunked)',
      () async {
        final store = HiddenVolumeStorage(FakeHvContainer().passwordOpener);
        await store.open(password: 'fixture', createIfMissing: true);
        final peer = _id(2);
        await store.upsertContact(
          Contact(nodeId: peer, status: ContactStatus.accepted),
        );
        final link = _Link();
        final service = MessagingService(link, store)..start();
        service.onGroupEntry = (_, _) async {
          await service.sendGroupSnapshot(
            peer,
            'ab' * 32,
            jsonEncode({'fixture': 'x' * (chunked ? 7000 : 10)}),
            awaitInitialSend: false,
          );
          return true;
        };
        try {
          link.inject(
            WireEnvelope.groupEntry('{"sreq":1}').withFrameId('sync-ask'),
          );
          await link.entered.future.timeout(const Duration(seconds: 2));
          link.inject(WireEnvelope.message('independent chat', id: 'post'));
          await _until(
            () async => (await store.loadMessages(peer.hex)).isNotEmpty,
          );
          expect((await store.loadMessages(peer.hex)).map((m) => m.body), [
            'independent chat',
          ]);
          final pending = await store.pendingOutboxFrames();
          expect(
            pending.length,
            chunked ? greaterThan(1) : 1,
            reason:
                'the entire response must be durable before ingress proceeds',
          );
        } finally {
          link.release.complete();
          await service.dispose();
          await link.dispose();
          await store.close();
        }
      },
    );
  }

  for (final chunked in [false, true]) {
    test(
      'confirmed queued sync work is not sent after lane release (chunked=$chunked)',
      () async {
        final r = await _rig();
        await r.service.sendGroupSnapshot(
          _id(2),
          'ab' * 32,
          '{"held":true}',
          awaitInitialSend: false,
        );
        await r.link.entered.future;
        await r.service.sendGroupSnapshot(
          _id(2),
          'ab' * 32,
          jsonEncode({'queued': 'x' * (chunked ? 7000 : 10)}),
          awaitInitialSend: false,
        );
        final rows = await r.store.pendingOutboxFrames();
        final queued = rows.where((row) {
          final env = WireEnvelope.decode(row.wire);
          return chunked
              ? env.kind == WireKind.groupEntryChunk
              : env.body.contains('queued');
        }).toList();
        expect(queued.length, chunked ? greaterThan(1) : 1);
        final ackId = chunked
            ? 'grpa:${parseGroupEntryChunk(WireEnvelope.decode(queued.first.wire).body).transferId}'
            : queued.single.frameId;
        await r.service.deliverInbound(
          InboundMessage(
            src: _id(2),
            provenance: SenderProvenance.sessionPeer,
            payload: WireEnvelope.ack(ackId).encode(),
          ),
        );
        await _until(
          () async => (await r.store.pendingOutboxFrames()).length == 1,
        );
        expect(await r.store.pendingOutboxFrames(), hasLength(1));
        final drained = Completer<void>();
        r.link.afterGroupSend = (env) async {
          if (env.body == '{"barrier":true}') drained.complete();
        };
        await r.service.sendGroupSnapshot(
          _id(2),
          'ab' * 32,
          '{"barrier":true}',
          awaitInitialSend: false,
        );
        r.link.release.complete();
        await drained.future.timeout(const Duration(seconds: 2));
        expect(r.link.sent.map((env) => env.body), [
          '{"held":true}',
          '{"barrier":true}',
        ]);
      },
    );
  }

  test('an Outbox retry ACK cancels its waiting first sync attempt', () async {
    var now = DateTime.now();
    final r = await _rig(now: () => now);
    await r.service.sendGroupSnapshot(
      _id(2),
      'ab' * 32,
      '{"held":true}',
      awaitInitialSend: false,
    );
    await r.link.entered.future;
    await r.service.sendGroupSnapshot(
      _id(2),
      'ab' * 32,
      '{"retry":true}',
      awaitInitialSend: false,
    );
    r.link.afterGroupSend = (env) async {
      if (env.body != '{"retry":true}') return;
      await r.service.deliverInbound(
        InboundMessage(
          src: _id(2),
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.ack(env.frameId!).encode(),
        ),
      );
    };
    now = now.add(const Duration(seconds: 21));
    await r.service.debugFlushOutboxFrames();
    await _until(() async => (await r.store.pendingOutboxFrames()).length == 1);
    expect(await r.store.pendingOutboxFrames(), hasLength(1));
    expect(
      r.link.sent.where((env) => env.body == '{"retry":true}'),
      hasLength(1),
    );
    final drained = Completer<void>();
    r.link.afterGroupSend = (env) async {
      if (env.body == '{"barrier":true}') drained.complete();
    };
    await r.service.sendGroupSnapshot(
      _id(2),
      'ab' * 32,
      '{"barrier":true}',
      awaitInitialSend: false,
    );
    r.link.release.complete();
    await drained.future.timeout(const Duration(seconds: 2));
    expect(
      r.link.sent.where((env) => env.body == '{"retry":true}'),
      hasLength(1),
    );
  });

  for (final chunked in [false, true]) {
    test(
      'another accepted peer cannot cancel queued work (chunked=$chunked)',
      () async {
        final r = await _rig();
        await r.store.upsertContact(
          Contact(nodeId: _id(3), status: ContactStatus.accepted),
        );
        await r.service.sendGroupSnapshot(
          _id(2),
          'ab' * 32,
          '{"held":true}',
          awaitInitialSend: false,
        );
        await r.link.entered.future;
        await r.service.sendGroupSnapshot(
          _id(2),
          'ab' * 32,
          jsonEncode({'queued': 'x' * (chunked ? 7000 : 10)}),
          awaitInitialSend: false,
        );
        final rows = await r.store.pendingOutboxFrames();
        final queued = rows
            .where((row) => row.frameId != rows.first.frameId)
            .toList();
        final ackId = chunked
            ? 'grpa:${parseGroupEntryChunk(WireEnvelope.decode(queued.first.wire).body).transferId}'
            : queued.single.frameId;
        await r.service.deliverInbound(
          InboundMessage(
            src: _id(3),
            provenance: SenderProvenance.sessionPeer,
            payload: WireEnvelope.ack(ackId).encode(),
          ),
        );
        expect(await r.store.pendingOutboxFrames(), hasLength(rows.length));
        final drained = Completer<void>();
        r.link.afterGroupSend = (env) async {
          if (env.frameId == queued.last.frameId) drained.complete();
        };
        r.link.release.complete();
        await drained.future.timeout(const Duration(seconds: 2));
        expect(
          r.link.sent.map((env) => env.frameId).toSet(),
          rows.map((row) => row.frameId).toSet(),
        );
      },
    );
  }

  test(
    'slice ACK skips only its waiting attempt and retains the full durable copy',
    () async {
      var now = DateTime.now();
      final r = await _rig(now: () => now);
      await r.service.sendGroupSnapshot(
        _id(2),
        'ab' * 32,
        '{"held":true}',
        awaitInitialSend: false,
      );
      await r.link.entered.future;
      await r.service.sendGroupSnapshot(
        _id(2),
        'ab' * 32,
        jsonEncode({'queued': 'x' * 7000}),
        awaitInitialSend: false,
      );
      final rows = await r.store.pendingOutboxFrames();
      final chunks = rows
          .where((row) => row.frameId.startsWith('grpc:'))
          .toList();
      await r.service.deliverInbound(
        InboundMessage(
          src: _id(2),
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.ack(chunks.first.frameId).encode(),
        ),
      );
      // A legacy slice ACK does not prove durable apply of the whole bundle.
      expect(await r.store.pendingOutboxFrames(), hasLength(rows.length));
      final drained = Completer<void>();
      r.link.afterGroupSend = (env) async {
        if (env.frameId == chunks.last.frameId) drained.complete();
      };
      r.link.release.complete();
      await drained.future.timeout(const Duration(seconds: 2));
      expect(
        r.link.sent.any((env) => env.frameId == chunks.first.frameId),
        isFalse,
      );
      r.link.afterGroupSend = null;
      now = now.add(const Duration(seconds: 21));
      await r.service.debugFlushOutboxFrames();
      expect(
        r.link.sent.any((env) => env.frameId == chunks.first.frameId),
        isTrue,
      );
      expect(await r.store.pendingOutboxFrames(), hasLength(rows.length));
    },
  );

  test('transfer cancellation waits for durable atomic retirement', () async {
    final store = _DeferredBatchRetirement(FakeHvContainer().passwordOpener);
    final r = await _rig(supplied: store);
    addTearDown(() {
      if (!store.release.isCompleted) store.release.complete();
    });
    await r.service.sendGroupSnapshot(
      _id(2),
      'ab' * 32,
      '{"held":true}',
      awaitInitialSend: false,
    );
    await r.link.entered.future;
    await r.service.sendGroupSnapshot(
      _id(2),
      'ab' * 32,
      jsonEncode({'queued': 'x' * 7000}),
      awaitInitialSend: false,
    );
    final rows = await store.pendingOutboxFrames();
    final chunks = rows
        .where((row) => row.frameId.startsWith('grpc:'))
        .toList();
    final tid = parseGroupEntryChunk(
      WireEnvelope.decode(chunks.first.wire).body,
    ).transferId;
    final ack = r.service.deliverInbound(
      InboundMessage(
        src: _id(2),
        provenance: SenderProvenance.sessionPeer,
        payload: WireEnvelope.ack('grpa:$tid').encode(),
      ),
    );
    await store.entered.future;
    expect(await store.pendingOutboxFrames(), hasLength(rows.length));
    final drained = Completer<void>();
    r.link.afterGroupSend = (env) async {
      if (env.frameId == chunks.last.frameId) drained.complete();
    };
    r.link.release.complete();
    await drained.future.timeout(const Duration(seconds: 2));
    expect(r.link.sent, hasLength(rows.length));
    store.release.complete();
    await ack;
    expect(await store.pendingOutboxFrames(), hasLength(1));
  });

  test('repeated pending snapshots share one initial attempt', () async {
    final r = await _rig();
    for (var i = 0; i < 10; i++) {
      await r.service.sendGroupSnapshot(
        _id(2),
        'ab' * 32,
        '{"same":true}',
        awaitInitialSend: false,
      );
    }
    await r.link.entered.future;
    expect(await r.store.pendingOutboxFrames(), hasLength(1));
    expect(r.link.maxActive, 1);
    r.link.release.complete();
    await _until(() async => r.link.sent.isNotEmpty);
    expect(r.link.sent, hasLength(1));
  });

  test(
    'count pressure retains every response and bounded retry recovers overflow',
    () async {
      var now = DateTime.now();
      final r = await _rig(now: () => now);
      for (var i = 0; i < 150; i++) {
        await r.service.sendGroupSnapshot(
          _id(2),
          'ab' * 32,
          '{"fixture":$i}',
          awaitInitialSend: false,
        );
      }
      expect(await r.store.pendingOutboxFrames(), hasLength(150));
      expect(r.link.maxActive, 1);
      r.link.release.complete();
      await _until(() async => r.link.sent.length >= 128);
      expect(r.link.sent, hasLength(128));
      now = now.add(const Duration(seconds: 21));
      for (var i = 0; i < 10; i++) {
        await r.service.debugFlushOutboxFrames();
      }
      expect(r.link.sent.map((w) => w.frameId).toSet(), hasLength(150));
      expect(
        await r.store.pendingOutboxFrames(),
        hasLength(150),
        reason: 'transport admission alone is not a receiver ACK',
      );
    },
  );

  test(
    'shutdown joins the active send and restart recovers waiting responses',
    () async {
      final backing = FakeHvContainer();
      final r = await _rig(
        supplied: HiddenVolumeStorage(backing.passwordOpener),
      );
      for (var i = 0; i < 6; i++) {
        await r.service.sendGroupSnapshot(
          _id(2),
          'ab' * 32,
          '{"fixture":$i}',
          awaitInitialSend: false,
        );
      }
      await r.link.entered.future;
      var closed = false;
      final close = r.service.dispose().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      r.link.release.complete();
      await close;
      expect(r.link.sent, hasLength(1));
      await r.store.close();
      final recovered = HiddenVolumeStorage(backing.passwordOpener);
      await recovered.open(password: 'fixture', createIfMissing: false);
      final link = _Link()..hold = false;
      final service = MessagingService(link, recovered);
      try {
        expect(await recovered.pendingOutboxFrames(), hasLength(6));
        await service.debugFlushOutboxFrames();
        expect(link.sent.map((e) => e.frameId).toSet(), hasLength(6));
      } finally {
        await service.dispose();
        await link.dispose();
        await recovered.close();
      }
    },
  );

  test(
    'a failed durable response never starts a live send or retires its request',
    () async {
      final r = await _rig(
        supplied: _FailedOutbox(FakeHvContainer().passwordOpener),
      );
      r.service.onGroupEntry = (_, _) async {
        await r.service.sendGroupSnapshot(
          _id(2),
          'ab' * 32,
          '{}',
          awaitInitialSend: false,
        );
        return true;
      };
      await r.service.deliverInbound(
        InboundMessage(
          src: _id(2),
          provenance: SenderProvenance.sessionPeer,
          payload: WireEnvelope.groupEntry(
            '{"sreq":1}',
          ).withFrameId('request').encode(),
        ),
      );
      expect(r.link.entered.isCompleted, isFalse);
      expect(r.link.acknowledgements, isEmpty);
    },
  );

  test(
    'queued source work cannot run in a replacement group context',
    () async {
      final r = await _rig();
      await r.service.sendGroupSnapshot(
        _id(2),
        'ab' * 32,
        '{"fixture":"active"}',
        awaitInitialSend: false,
      );
      await r.link.entered.future;
      await r.service.sendGroupSnapshot(
        _id(2),
        'ab' * 32,
        '{"fixture":"obsolete"}',
        awaitInitialSend: false,
      );
      r.service.onGroupEntry = (_, _) async => true;
      await r.service.sendGroupSnapshot(
        _id(2),
        'ab' * 32,
        '{"fixture":"replacement"}',
        awaitInitialSend: false,
      );
      r.link.release.complete();
      await _until(
        () async => r.link.sent.any((w) => w.body.contains('replacement')),
      );
      expect(r.link.sent.map((w) => jsonDecode(w.body)['fixture']), [
        'active',
        'replacement',
      ]);
      expect(await r.store.pendingOutboxFrames(), hasLength(3));
    },
  );

  test(
    'payload byte pressure bounds initial work without dropping durable rows',
    () async {
      final r = await _rig();
      for (var i = 0; i < 100; i++) {
        await r.service.sendGroupSnapshot(
          _id(2),
          'ab' * 32,
          jsonEncode({'fixture': i, 'padding': 'x' * 1800}),
          awaitInitialSend: false,
        );
      }
      expect(await r.store.pendingOutboxFrames(), hasLength(200));
      expect(r.link.maxActive, 1);
      r.link.release.complete();
      // This fake's sends complete with microtasks; let their drain finish.
      await Future<void>.delayed(Duration.zero);
      expect(
        r.link.sent.length,
        allOf(greaterThan(1), lessThan(128)),
        reason: 'the byte budget must bind before the 128-job count ceiling',
      );
      expect(await r.store.pendingOutboxFrames(), hasLength(200));
    },
  );

  test('initial transport failure leaves a complete durable retry', () async {
    var now = DateTime.now();
    final r = await _rig(now: () => now);
    r.link
      ..hold = false
      ..failGroups = true;
    await r.service.sendGroupSnapshot(
      _id(2),
      'ab' * 32,
      '{}',
      awaitInitialSend: false,
    );
    await Future<void>.delayed(Duration.zero);
    expect(await r.store.pendingOutboxFrames(), hasLength(1));
    expect(r.link.sent, isEmpty);
    r.link.failGroups = false;
    now = now.add(const Duration(seconds: 21));
    await r.service.debugFlushOutboxFrames();
    expect(r.link.sent, hasLength(1));
  });

  test(
    'a stalled destination does not park another groups recipient',
    () async {
      final r = await _rig();
      final other = _id(3);
      await r.store.upsertContact(
        Contact(nodeId: other, status: ContactStatus.accepted),
      );
      await r.service.sendGroupSnapshot(
        _id(2),
        'ab' * 32,
        '{"fixture":"held"}',
        awaitInitialSend: false,
      );
      await r.link.entered.future;
      await r.service.sendGroupSnapshot(
        _id(2),
        'ab' * 32,
        '{"fixture":"same lane"}',
        awaitInitialSend: false,
      );
      await r.service.sendGroupSnapshot(
        other,
        'ab' * 32,
        '{"fixture":"healthy"}',
        awaitInitialSend: false,
      );
      await _until(
        () async => r.link.sent.any((w) => w.body.contains('healthy')),
      );
      expect(r.link.sent.map((w) => jsonDecode(w.body)['fixture']), [
        'healthy',
      ]);
      expect(r.link.maxActive, 2);
    },
  );
}
