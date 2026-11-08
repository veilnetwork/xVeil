import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/data/transport/wire_envelope.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

NodeId _id(int n) => NodeId(Uint8List(32)..fillRange(0, 32, n));

class _Store extends FakeKvLogStore {
  int enqueues = 0;
  bool refuseOutbox = false;
  int refused = 0;
  @override
  int commit(List<KvLogOp> ops) {
    if (ops.whereType<PutOp>().any((op) => op.namespace == Ns.outboxIndex)) {
      enqueues++;
      if (refuseOutbox) {
        refused++;
        throw StateError('injected transfer commit failure');
      }
    }
    return super.commit(ops);
  }
}

class _Link extends LoopbackTransport {
  _Link(this.raw) : super(localNodeId: _id(1));
  final _Store raw;
  final entered = Completer<void>(), release = Completer<void>();
  int groupStarts = 0, firstDurableCount = 0;
  @override
  Future<void> send(
    NodeId dst,
    Uint8List payload, {
    bool anonymous = false,
  }) async {
    final env = WireEnvelope.decode(payload);
    if (env.kind != WireKind.groupEntryChunk) return;
    groupStarts++;
    if (!entered.isCompleted) {
      firstDurableCount = raw.kvKeys(Ns.outboxIndex).length;
      entered.complete();
      await release.future;
    }
  }
}

Future<
  ({
    _Store raw,
    HiddenVolumeStorage store,
    _Link link,
    MessagingService service,
  })
>
_rig({bool failPersistence = false}) async {
  final raw = _Store();
  final store = HiddenVolumeStorage(
    ({required password, required create}) => raw,
  );
  await store.open(password: 'fixture');
  await store.upsertContact(
    Contact(nodeId: _id(2), status: ContactStatus.accepted),
  );
  raw.refuseOutbox = failPersistence;
  final link = _Link(raw);
  final service = MessagingService(link, store);
  addTearDown(() async {
    if (!link.release.isCompleted) link.release.complete();
    await service.dispose();
    await link.dispose();
    await store.close();
  });
  return (raw: raw, store: store, link: link, service: service);
}

void main() {
  for (final length in [7000, 25000]) {
    test(
      'sync response persists bounded batches with held first send ($length)',
      () async {
        final r = await _rig();
        await r.service.sendGroupSnapshot(
          _id(2),
          'ab' * 32,
          jsonEncode({'body': 'x' * length}),
          awaitInitialSend: false,
        );
        await r.link.entered.future;
        final frames = await r.store.pendingOutboxFrames();
        expect(frames.length, greaterThan(1));
        expect(
          frames.every(
            (f) => WireEnvelope.decode(f.wire).kind == WireKind.groupEntryChunk,
          ),
          isTrue,
        );
        // The encoded-byte budget can split an eight-frame call into more
        // than one commit. Qualify caller batching without bypassing that cap.
        expect(r.raw.enqueues, lessThan(frames.length));
        expect(
          r.link.firstDurableCount,
          greaterThanOrEqualTo(frames.length < 8 ? frames.length : 8),
        );
        expect(
          r.link.groupStarts,
          1,
          reason: 'per-peer source lane still serial',
        );
      },
    );
  }

  test('ordinary chunked snapshot retains initial-attempt pacing', () async {
    final r = await _rig();
    var done = false;
    final sending = r.service
        .sendGroupSnapshot(_id(2), 'ab' * 32, jsonEncode({'body': 'x' * 7000}))
        .then((_) => done = true);
    await r.link.entered.future;
    expect(done, isFalse);
    final prepared = await r.store.pendingOutboxFrames();
    expect(prepared.length, greaterThan(1));
    expect(r.link.firstDurableCount, prepared.length);
    expect(r.link.groupStarts, 1, reason: 'initial sends remain serialized');
    r.link.release.complete();
    await sending;
    final frames = await r.store.pendingOutboxFrames();
    expect(frames.length, greaterThan(1));
    expect(r.raw.enqueues, lessThan(frames.length));
  });

  test('refused transfer commit starts no source work and can retry', () async {
    final r = await _rig(failPersistence: true);
    await expectLater(
      r.service.sendGroupSnapshot(
        _id(2),
        'ab' * 32,
        jsonEncode({'body': 'x' * 7000}),
        awaitInitialSend: false,
      ),
      throwsStateError,
    );
    expect(r.link.groupStarts, 0);
    expect(r.raw.refused, 1);
    expect(await r.store.pendingOutboxFrames(), isEmpty);
    r.raw.refuseOutbox = false;
    await r.service.sendGroupSnapshot(
      _id(2),
      'ab' * 32,
      jsonEncode({'body': 'x' * 7000}),
      awaitInitialSend: false,
    );
    await r.link.entered.future;
    expect(r.link.groupStarts, 1);
    expect(await r.store.pendingOutboxFrames(), isNotEmpty);
  });
}
