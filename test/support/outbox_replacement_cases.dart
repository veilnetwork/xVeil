import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'timed_native_store.dart';

class ReplacementFaults {
  String? fault;
  int stage = 0, scrubs = 0;
  int? holdStage;
  Completer<void> entered = Completer<void>(), release = Completer<void>();
  void Function(int)? onStage;
}

class ReplacementStore extends TimedNativeStore {
  ReplacementStore(AsyncKvLogStore inner, this.faults)
    : super(inner, Stopwatch()..start(), (_) {});
  final ReplacementFaults faults;
  @override
  Future<int> commit(List<KvLogOp> ops) async {
    final stage = ops.whereType<PutOp>().any(
      (o) => o.namespace == Ns.outboxIndex,
    );
    final retire =
        ops.whereType<DeleteOp>().any((o) => o.namespace == Ns.outboxIndex) &&
        ops.whereType<PutOp>().any((o) => o.namespace == Ns.settings);
    final n = stage ? ++faults.stage : 0;
    if (stage) faults.onStage?.call(n);
    if (stage && faults.holdStage == n) {
      faults.entered.complete();
      await faults.release.future;
    }
    final fault = faults.fault;
    final refusal =
        (fault == 'stage-before' && n == 2) ||
        (fault == 'retire-before' && retire);
    final lost =
        (fault == 'stage-after' && n == 2) ||
        (fault == 'retire-after' && retire);
    if (refusal || lost) faults.fault = null;
    if (refusal) throw StateError('replacement commit refused');
    final result = await super.commit(ops);
    if (lost) throw StateError('replacement commit reply lost');
    return result;
  }

  @override
  Future<void> scrub() async {
    faults.scrubs++;
    if (faults.fault == 'scrub') {
      faults.fault = null;
      throw StateError('replacement vacuum refused');
    }
    return super.scrub();
  }
}

void outboxReplacementCases({
  required Future<HiddenVolumeStorage> Function(ReplacementFaults) open,
  Object skip = false,
}) {
  late HiddenVolumeStorage storage;
  late ReplacementFaults faults;
  final old = [
    for (var i = 0; i < 3; i++)
      OutboxFrame(
        frameId: 'old-$i',
        peerHex: 'peer',
        wire: Uint8List.fromList([11, i]),
      ),
  ];
  final fresh = [
    for (var i = 0; i < 17; i++)
      OutboxFrame(
        frameId: 'new-$i',
        peerHex: 'peer',
        wire: Uint8List.fromList([22, i]),
        enqueuedAtMs: 123456,
      ),
  ];
  Future<List<String>> ids() async =>
      (await storage.pendingOutboxFrames()).map((f) => f.frameId).toList();
  Future<void> seed() async {
    for (final f in old) {
      await storage.enqueueOutboxFrame(f.frameId, f.peerHex, f.wire);
    }
    await storage.enqueueOutboxFrame(
      'unrelated',
      'other-peer',
      Uint8List.fromList([33]),
    );
    faults.stage = 0;
  }

  setUp(() async {
    if (skip != false) return;
    faults = ReplacementFaults();
    storage = await open(faults);
    await seed();
  });
  tearDown(() async {
    if (skip != false) return;
    if (!faults.release.isCompleted) faults.release.complete();
    await storage.close();
  });

  test(
    'replacement keeps all new bytes, age and unrelated frames after reopen',
    () async {
      expect(await storage.replaceOutboxFrames(old, fresh), isTrue);
      await storage.finishOutboxCleanup();
      await storage.close();
      expect(await storage.open(password: 'fixture'), isTrue);
      expect(
        await ids(),
        unorderedEquals(['unrelated', ...fresh.map((f) => f.frameId)]),
      );
      for (final row in await storage.pendingOutboxFrames()) {
        if (!row.frameId.startsWith('new-')) continue;
        final intended = fresh.firstWhere((f) => f.frameId == row.frameId);
        expect(row.wire, intended.wire);
        expect(row.enqueuedAtMs, 123456);
      }
    },
    skip: skip,
  );

  for (final fault in [
    'stage-before',
    'stage-after',
    'retire-before',
    'retire-after',
  ]) {
    test(
      'replacement failure $fault has a recoverable durable image',
      () async {
        faults.fault = fault;
        await expectLater(
          storage.replaceOutboxFrames(old, fresh),
          throwsStateError,
        );
        final pending = await ids();
        if (fault == 'retire-after') {
          expect(
            pending,
            unorderedEquals(['unrelated', ...fresh.map((f) => f.frameId)]),
          );
        } else {
          expect(pending, containsAll(old.map((f) => f.frameId)));
          if (fault.startsWith('stage-')) {
            expect(
              pending.where((id) => id.startsWith('new-')).length,
              lessThan(fresh.length),
            );
          }
        }
        await storage.close();
        expect(await storage.open(password: 'fixture'), isTrue);
        final didReplace = await storage.replaceOutboxFrames(old, fresh);
        expect(didReplace, fault != 'retire-after');
        await storage.finishOutboxCleanup();
        expect(
          await ids(),
          unorderedEquals(['unrelated', ...fresh.map((f) => f.frameId)]),
        );
      },
      skip: skip,
    );
  }

  for (final fault in [null, 'retire-before', 'retire-after']) {
    test('empty local replacement is exact and durable ($fault)', () async {
      // A stale expected image must never be an unconditional delete.
      expect(
        await storage.replaceOutboxFrames([
          OutboxFrame(
            frameId: old.first.frameId,
            peerHex: 'wrong-peer',
            wire: old.first.wire,
          ),
        ], []),
        isFalse,
      );
      expect(await ids(), containsAll(old.map((f) => f.frameId)));
      faults.fault = fault;
      if (fault == null) {
        expect(await storage.replaceOutboxFrames(old, []), isTrue);
      } else {
        await expectLater(
          storage.replaceOutboxFrames(old, []),
          throwsStateError,
        );
        expect(
          await ids(),
          fault == 'retire-before'
              ? containsAll(old.map((f) => f.frameId))
              : ['unrelated'],
        );
      }
      await storage.close();
      expect(await storage.open(password: 'fixture'), isTrue);
      if (fault == 'retire-before') {
        expect(await storage.replaceOutboxFrames(old, []), isTrue);
      }
      faults.fault = 'scrub';
      await expectLater(storage.finishOutboxCleanup(), throwsStateError);
      await storage.close();
      expect(await storage.open(password: 'fixture'), isTrue);
      await storage.finishOutboxCleanup();
      expect(await ids(), ['unrelated']);
      expect(faults.stage, 0);
    }, skip: skip);
  }

  test(
    'vacuum obligation survives replacement and reopen without old rows',
    () async {
      expect(await storage.replaceOutboxFrames(old, fresh), isTrue);
      faults.fault = 'scrub';
      await expectLater(storage.finishOutboxCleanup(), throwsStateError);
      final before = faults.scrubs;
      await storage.close();
      expect(await storage.open(password: 'fixture'), isTrue);
      await storage.finishOutboxCleanup();
      expect(faults.scrubs, greaterThan(before));
      final done = faults.scrubs;
      await storage.finishOutboxCleanup();
      expect(faults.scrubs, done);
      expect(
        await ids(),
        unorderedEquals(['unrelated', ...fresh.map((f) => f.frameId)]),
      );
    },
    skip: skip,
  );

  test(
    'stale expected wire and conflicting new IDs cannot retire data',
    () async {
      final stale = [
        OutboxFrame(
          frameId: old.first.frameId,
          peerHex: 'peer',
          wire: Uint8List.fromList([99]),
        ),
        ...old.skip(1),
      ];
      expect(await storage.replaceOutboxFrames(stale, fresh), isFalse);
      await storage.enqueueOutboxFrame(
        fresh.first.frameId,
        'peer',
        Uint8List.fromList([99]),
      );
      expect(await storage.replaceOutboxFrames(old, fresh), isFalse);
      expect(
        await ids(),
        unorderedEquals([
          'unrelated',
          ...old.map((f) => f.frameId),
          fresh.first.frameId,
        ]),
      );
    },
    skip: skip,
  );

  test(
    'cohorts let an unrelated queued ACK complete before the next stage',
    () async {
      faults.holdStage = 1;
      final replace = storage.replaceOutboxFrames(old, fresh);
      await faults.entered.future;
      final acked = Completer<void>();
      final ack = storage
          .ackOutboxFrame('unrelated', fromPeerHex: 'other-peer')
          .then((_) => acked.complete());
      faults.onStage = (n) {
        if (n == 2) expect(acked.isCompleted, isTrue);
      };
      faults.release.complete();
      expect(await replace, isTrue);
      await ack;
      expect(await ids(), unorderedEquals(fresh.map((f) => f.frameId)));
    },
    skip: skip,
  );

  test(
    'replacement owns bytes and close drains an admitted operation',
    () async {
      faults.holdStage = 1;
      final mutableOld = [
        for (final f in old)
          OutboxFrame(
            frameId: f.frameId,
            peerHex: f.peerHex,
            wire: Uint8List.fromList(f.wire),
          ),
      ];
      final mutableFresh = [
        for (final f in fresh)
          OutboxFrame(
            frameId: f.frameId,
            peerHex: f.peerHex,
            wire: Uint8List.fromList(f.wire),
            enqueuedAtMs: f.enqueuedAtMs,
          ),
      ];
      final replace = storage.replaceOutboxFrames(mutableOld, mutableFresh);
      await faults.entered.future;
      mutableOld.first.wire[0] = 99;
      mutableFresh.first.wire[0] = 99;
      var closed = false;
      final closing = storage.close().then((_) => closed = true);
      expect(closed, isFalse);
      await expectLater(
        storage.enqueueOutboxFrame('too-late', 'peer', Uint8List(1)),
        throwsStateError,
      );
      faults.release.complete();
      expect(await replace, isTrue);
      await closing;
      expect(await storage.open(password: 'fixture'), isTrue);
      final row = (await storage.pendingOutboxFrames()).firstWhere(
        (f) => f.frameId == fresh.first.frameId,
      );
      expect(row.wire, fresh.first.wire);
    },
    skip: skip,
  );
}
