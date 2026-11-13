@Timeout(Duration(seconds: 20))
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_reclaim_budget.dart';
import 'package:xveil/data/storage/worker_death.dart';

final _key = Uint8List.fromList([7]);
final _value = Uint8List.fromList([9]);

class _Control {
  const _Control(this.reply, {this.release, this.state = false});
  final SendPort reply;
  final bool? release;
  final bool state;
}

class _BusyStore extends FakeKvLogStore {
  bool busy = false;
  int touchedWhileBusy = 0;
  int closes = 0;
  @override
  Uint8List? get(int namespace, Uint8List key) {
    if (busy) {
      touchedWhileBusy++;
      throw StateError('synthetic detached payload');
    }
    return super.get(namespace, key);
  }

  @override
  int commit(List<KvLogOp> operations) {
    if (busy) {
      touchedWhileBusy++;
      throw StateError('synthetic detached payload');
    }
    if (operations.any((op) => op is PutOp && op.key.single == 99)) {
      throw StateError('synthetic rejected transaction');
    }
    return super.commit(operations);
  }

  @override
  void close() {
    closes++;
    if (busy) throw StateError('closed during synthetic maintenance');
    super.close();
  }
}

void _fixtureWorker((SendPort, SendPort, bool) args) {
  final (boot, events, enabled) = args;
  final raw = _BusyStore()..commit([PutOp(1, _key, _value)]);
  final control = ReceivePort();
  Completer<bool>? gate;
  final forces = <bool>[];
  control.listen((dynamic request) {
    if (request is! _Control) return;
    if (request.release != null && gate != null) {
      gate!.complete(request.release!);
      gate = null;
    }
    request.reply.send({
      'calls': forces.length,
      'forces': List<bool>.of(forces),
      'busyReads': raw.touchedWhileBusy,
      'closes': raw.closes,
    });
  });
  Future<ManagedReclaimReport> reclaim(bool force) async {
    if (raw.busy) throw StateError('overlapping maintenance');
    raw.busy = true;
    forces.add(force);
    final wait = Completer<bool>();
    gate = wait;
    events.send(forces.length);
    try {
      if (await wait.future) {
        throw StateError(
          'synthetic private-owner/backend/path must not escape',
        );
      }
      return const ManagedReclaimReport(
        beforeBytes: 9,
        afterBytes: 4,
        contentRepacked: true,
        maintenanceRepacked: false,
      );
    } finally {
      raw.busy = false;
    }
  }

  final port = WorkerKvLogStore.debugServeStore(
    raw,
    reclaim: enabled ? reclaim : null,
  );
  boot.send((port, control.sendPort));
}

class _Handle {
  _Handle(
    this.isolate,
    this.watch,
    this.worker,
    this.control,
    this.events,
    this.iterator,
  );
  final Isolate isolate;
  final WorkerDeath watch;
  final WorkerKvLogStore worker;
  final SendPort control;
  final ReceivePort events;
  final StreamIterator<dynamic> iterator;
  Future<Map<String, Object?>> state({bool? release}) async {
    final reply = ReceivePort();
    try {
      control.send(_Control(reply.sendPort, release: release, state: true));
      return Map<String, Object?>.from(await watch.race(reply.first) as Map);
    } finally {
      reply.close();
    }
  }

  Future<void> started(int ordinal) async {
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, ordinal);
  }

  Future<void> dispose() async {
    try {
      if (watch.debugWatching) {
        await state(release: false);
      }
      await worker.close();
    } finally {
      watch.dispose();
      isolate.kill(priority: Isolate.immediate);
      await iterator.cancel();
      events.close();
    }
  }
}

Future<_Handle> _spawn({bool enabled = true}) async {
  final boot = ReceivePort(), events = ReceivePort();
  final iterator = StreamIterator(events);
  final watch = WorkerDeath();
  final isolate = await Isolate.spawn(
    _fixtureWorker,
    (boot.sendPort, events.sendPort, enabled),
    errorsAreFatal: true,
    onExit: watch.exitPort.sendPort,
    onError: watch.errorPort.sendPort,
  );
  final (port, control) = await boot.first as (SendPort, SendPort);
  boot.close();
  return _Handle(
    isolate,
    watch,
    WorkerKvLogStore.overWorker(isolate: isolate, toWorker: port, watch: watch),
    control,
    events,
    iterator,
  );
}

void main() {
  late _Handle h;
  setUp(() async {
    h = await _spawn();
  });
  tearDown(() async {
    await h.dispose();
    WorkerKvLogStore.closeTimeout = const Duration(seconds: 5);
  });

  test('reads wait until owned maintenance reattaches payloads', () async {
    final maintenance = ManagedWorkerIdentity.reclaim(h.worker, force: true);
    await h.started(1);
    var settled = false;
    final read = h.worker
        .get(1, _key)
        .then<Object?>(
          (v) {
            settled = true;
            return v;
          },
          onError: (Object error) {
            settled = true;
            return error;
          },
        );
    final state = await h.state();
    expect(state['busyReads'], 0);
    expect(settled, isFalse);
    expect(state['forces'], [true]);
    await h.state(release: false);
    final report = await maintenance;
    expect(report.afterBytes, 4);
    expect(await read, _value);
  });

  test(
    'close timeout retains owner until maintenance and queued close finish',
    () async {
      final maintenance = ManagedWorkerIdentity.reclaim(h.worker, force: true);
      await h.started(1);
      WorkerKvLogStore.closeTimeout = Duration.zero;
      await expectLater(h.worker.close(), throwsA(isA<hv.HvException>()));
      expect((await h.state())['closes'], 0);
      expect(h.watch.debugWatching, isTrue);
      await h.state(release: false);
      await maintenance;
      await h.worker.debugLateClose;
      expect(h.watch.debugWatching, isFalse);
      expect(h.watch.debugWaitingCount, 0);
    },
  );

  test(
    'automatic check follows 128 successful mutations and preserves durable reply',
    () async {
      for (var i = 0; i < 127; i++) {
        await h.worker.commit([PutOp(1, _key, _value)]);
      }
      expect((await h.state())['calls'], 0);
      final committed = await h.worker.commit([PutOp(1, _key, _value)]);
      expect(committed, greaterThan(0));
      await h.started(1);
      expect((await h.state())['forces'], [false]);
      await h.state(release: false);
      expect(await h.worker.get(1, _key), _value);
    },
  );

  test('failed mutations do not pay the automatic mutation budget', () async {
    for (var i = 0; i < 127; i++) {
      await h.worker.commit([PutOp(1, _key, _value)]);
    }
    await expectLater(
      h.worker.commit([
        PutOp(1, Uint8List.fromList([99]), _value),
      ]),
      throwsA(isA<ManagedWorkerFailure>()),
    );
    expect((await h.state())['calls'], 0);
    await h.worker.commit([PutOp(1, _key, _value)]);
    await h.started(1);
    await h.state(release: false);
    expect(await h.worker.get(1, _key), _value);
  });

  test('one durable batch can cross the maintenance budget', () async {
    await h.worker.commit([
      for (var i = 0; i < 128; i++) PutOp(1, _key, _value),
    ]);
    await h.started(1);
    expect((await h.state())['forces'], [false]);
    await h.state(release: false);
    expect(await h.worker.get(1, _key), _value);
  });

  for (final erase in [true, false]) {
    test(
      '${erase ? 'erasure' : 'scrub'} schedules an eligibility check',
      () async {
        if (erase) {
          expect(await h.worker.eraseNamespace(1), greaterThan(0));
        } else {
          await h.worker.scrub();
        }
        await h.started(1);
        expect((await h.state())['forces'], [false]);
        await h.state(release: false);
        expect(await h.worker.get(1, _key), erase ? isNull : _value);
      },
    );
  }

  test(
    'explicit failure is bounded and releases the queue for read and ack',
    () async {
      final maintenance = ManagedWorkerIdentity.reclaim(h.worker, force: true);
      final rejected = expectLater(
        maintenance,
        throwsA(
          isA<ManagedWorkerFailure>().having(
            (e) => e.kind,
            'kind',
            ManagedWorkerFailureKind.backend,
          ),
        ),
      );
      await h.started(1);
      await h.state(release: true);
      await rejected;
      expect(await h.worker.get(1, _key), _value);
      expect(await h.worker.hardeningWarning(), contains('reclamation'));
      await h.worker.acknowledgeHardeningWarning();
      expect(await h.worker.hardeningWarning(), isNull);
    },
  );

  test(
    'automatic failure preserves the write and reports a bounded warning',
    () async {
      for (var i = 0; i < 128; i++) {
        await h.worker.commit([PutOp(1, _key, _value)]);
      }
      await h.started(1);
      await h.state(release: true);
      final warning = await h.worker.hardeningWarning();
      expect(warning, contains('reclamation'));
      expect(warning, isNot(contains('private-owner')));
      expect(await h.worker.get(1, _key), _value);
      final retry = ManagedWorkerIdentity.reclaim(h.worker, force: true);
      await h.started(2);
      await h.state(release: false);
      await retry;
      expect(await h.worker.hardeningWarning(), isNull);
    },
  );

  test(
    'legacy workers reject maintenance and never schedule it on mutation',
    () async {
      final legacy = await _spawn(enabled: false);
      try {
        await expectLater(
          ManagedWorkerIdentity.reclaim(legacy.worker, force: true),
          throwsA(
            isA<ManagedWorkerFailure>().having(
              (e) => e.kind,
              'kind',
              ManagedWorkerFailureKind.mode,
            ),
          ),
        );
        for (var i = 0; i < 128; i++) {
          await legacy.worker.commit([PutOp(1, _key, _value)]);
        }
        expect((await legacy.state())['calls'], 0);
        expect(await legacy.worker.get(1, _key), _value);
      } finally {
        await legacy.dispose();
      }
    },
  );
}
