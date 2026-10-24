import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/call_log.dart';
import 'package:xveil/domain/call.dart';
import 'package:xveil/domain/call_signal.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/call_service.dart';
import 'package:xveil/state/messaging.dart';
import 'package:xveil/state/providers.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/state/call_log.dart';

CallLogEntry _entry({
  int time = 1000,
  int duration = 75,
  String outcome = 'completed',
  bool provisional = false,
}) => CallLogEntry.fromJson({
  'id': 'shared-call',
  'peer': 'aa',
  'out': false,
  'vid': false,
  'o': outcome,
  'at': time,
  if (duration > 0) 'dur': duration,
  if (provisional) 'provisional': true,
})!;

Future<HiddenVolumeStorage> _open([FakeKvLogStore? backing]) async {
  final kv = backing ?? FakeKvLogStore();
  final storage = HiddenVolumeStorage(
    ({required password, required bool create}) => kv,
  );
  await storage.open(password: 'fixture', createIfMissing: true);
  return storage;
}

class _RefusingStore extends FakeKvLogStore {
  bool refuseAppend = false, refuseCleanup = false;
  int appendCount = 0;
  int? failAtAppend;
  @override
  int commit(List<KvLogOp> ops) {
    if (ops.any((op) => op is AppendLogOp && op.namespace == Ns.callLog)) {
      appendCount++;
      if (refuseAppend || appendCount == failAtAppend) {
        throw StateError('fixture call append refused');
      }
    }
    if (refuseCleanup &&
        ops.any((op) => op is DeleteLogOp && op.namespace == Ns.callLog)) {
      throw StateError('fixture old revision cleanup refused');
    }
    return super.commit(ops);
  }
}

class _Wire implements MessagingService {
  @override
  bool backgroundStashPaused = false;
  @override
  bool get isAnonymousIdentity => false;
  @override
  void Function(NodeId, CallSignal)? onCallSignal;
  @override
  bool Function(NodeId, CallSignal)? acceptsCallDeviceSignal;
  @override
  Future<NodeId> localDeviceId() async => NodeId.fromHex('f' * 64);
  @override
  void pinCallReplyDevice(String callId, NodeId identity, NodeId device) {}
  @override
  Future<void> sendCallSignal(NodeId peer, CallSignal signal) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StartingMedia extends CallMediaController {
  final result = Completer<bool>();
  @override
  Future<bool> start(Call call) => result.future;
  @override
  Future<void> stop() async {}
}

class _CallFeed implements CallService {
  final feed = StreamController<Call?>.broadcast();
  @override
  Stream<Call?> get changes => feed.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'the recorder marks answered-elsewhere snapshots as provisional',
    () async {
      final storage = await _open();
      final service = _CallFeed();
      final container = ProviderContainer(
        overrides: [
          storageProvider.overrideWithValue(storage),
          callServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await service.feed.close();
        await storage.close();
      });
      container.read(callLogRecorderProvider);
      final store = container.read(callLogStoreProvider);
      final stored = Completer<void>();
      store.changes.addListener(() {
        if (!stored.isCompleted) stored.complete();
      });
      service.feed.add(
        Call(
          callId: 'answered-on-sibling',
          peer: NodeId.fromHex('a' * 64),
          direction: CallDirection.incoming,
          media: const CallMedia(audio: true),
          status: CallStatus.ended,
          localPosture: CallPosture.direct,
          startedAt: DateTime.fromMillisecondsSinceEpoch(1000),
          endedAt: DateTime.fromMillisecondsSinceEpoch(2000),
          endReason: CallEndReason.answeredElsewhere,
        ),
      );
      await stored.future.timeout(const Duration(seconds: 5));
      expect((await store.list()).single.toJson()['provisional'], true);
    },
  );

  test('opposite first writers converge on the final call duration', () async {
    final a = await _open(), b = await _open();
    addTearDown(a.close);
    addTearDown(b.close);
    final sa = CallLogStore(a), sb = CallLogStore(b);
    final early = _entry(time: 2000, duration: 0, provisional: true);
    final finalRecord = _entry();
    await sa.add(early);
    await sb.add(finalRecord);
    await sa.addMirrored(finalRecord);
    await sb.addMirrored(early);
    expect((await sa.list()).single.durationSec, 75);
    expect(
      (await sa.list()).single.toJson(),
      (await sb.list()).single.toJson(),
    );
  });

  test(
    'final call evidence wins the device fold and live gate before time',
    () async {
      DeviceSyncEvent event(CallLogEntry e) => DeviceSyncEvent(
        kind: DeviceSyncKind.callLog,
        key: e.id,
        tsMs: e.atMs,
        payload: e.toJson(),
      );
      final early = event(_entry(time: 2000, duration: 0, provisional: true));
      final finalRecord = event(_entry());
      for (final order in [
        [early, finalRecord],
        [finalRecord, early],
      ]) {
        expect(foldDeviceSync(order).values.single.payload['dur'], 75);
      }
      final gate = DeviceSyncApplyGate(nowMs: () => 3000);
      final applied = <DeviceSyncEvent>[];
      gate.offer(
        early,
        () => () async {
          applied.add(early);
        },
      );
      gate.offer(
        finalRecord,
        () => () async {
          applied.add(finalRecord);
        },
      );
      await gate.settle();
      expect(applied.last.payload['dur'], 75);
    },
  );

  test(
    'a final setup failure replaces an answered-elsewhere placeholder',
    () async {
      final storage = await _open();
      addTearDown(storage.close);
      await storage.appendCallLogEntry(
        _entry(time: 2000, duration: 0, provisional: true),
        cap: 5,
      );
      await storage.appendCallLogEntry(
        _entry(duration: 0, outcome: 'failed'),
        cap: 5,
      );
      final rows = await storage.callLogEntries();
      expect(rows.length, 1);
      expect(rows.single.outcome, CallLogOutcome.failed);
    },
  );
  test('a refused final append keeps the earlier record recoverable', () async {
    final kv = _RefusingStore();
    final storage = await _open(kv);
    addTearDown(storage.close);
    final early = _entry(duration: 0, provisional: true);
    await storage.appendCallLogEntry(early, cap: 5);
    kv.refuseAppend = true;
    await expectLater(
      storage.appendCallLogEntry(_entry(), cap: 5),
      throwsStateError,
    );
    expect((await storage.callLogEntries()).single.toJson(), early.toJson());
    expect(kv.count(Ns.callLog), 1);
    kv.refuseAppend = false;
    expect(await storage.appendCallLogEntry(_entry(), cap: 5), true);
    expect((await storage.callLogEntries()).single.durationSec, 75);
    expect(kv.count(Ns.callLog), 1);
  });

  test(
    'interrupted cleanup exposes one winner across restart and heals on replay',
    () async {
      final kv = _RefusingStore();
      var storage = await _open(kv);
      final early = _entry(duration: 0, provisional: true);
      await storage.appendCallLogEntry(early, cap: 5);
      kv.refuseCleanup = true;
      expect(await storage.appendCallLogEntry(_entry(), cap: 5), true);
      expect(kv.count(Ns.callLog), 2);
      expect((await storage.callLogEntries()).single.durationSec, 75);
      await storage.close();
      storage = await _open(kv);
      addTearDown(storage.close);
      expect((await storage.callLogEntries()).single.durationSec, 75);
      kv.refuseCleanup = false;
      await CallLogStore(storage).reconcileMirrored([_entry()]);
      expect(kv.count(Ns.callLog), 1);
    },
  );

  test(
    'caps retain the same calls despite opposite arrival at equal timestamps',
    () async {
      CallLogEntry call(String id) =>
          CallLogEntry.fromJson({..._entry().toJson(), 'id': id})!;
      final a = await _open(), b = await _open();
      addTearDown(a.close);
      addTearDown(b.close);
      for (final id in ['a', 'b', 'c']) {
        await a.appendCallLogEntry(call(id), cap: 2);
      }
      for (final id in ['c', 'b', 'a']) {
        await b.appendCallLogEntry(call(id), cap: 2);
      }
      expect((await a.callLogEntries()).map((e) => e.id).toList(), ['c', 'b']);
      expect((await b.callLogEntries()).map((e) => e.id).toList(), ['c', 'b']);
    },
  );

  test(
    'late local placeholders cannot re-emit over a mirrored final result',
    () async {
      final storage = await _open();
      addTearDown(storage.close);
      final store = CallLogStore(storage);
      var emitted = 0;
      store.onAdded = (_) {
        emitted++;
      };
      expect(await store.add(_entry(duration: 0, provisional: true)), true);
      expect(await store.addMirrored(_entry()), true);
      expect(
        await store.add(_entry(time: 2000, duration: 0, provisional: true)),
        false,
      );
      expect(emitted, 1);
      expect((await store.list()).single.durationSec, 75);
    },
  );

  test('valid final evidence survives malformed later device rows', () {
    final finalRecord = DeviceSyncEvent(
      kind: DeviceSyncKind.callLog,
      key: 'shared-call',
      tsMs: 1000,
      payload: _entry().toJson(),
    );
    for (final payload in [
      {..._entry().toJson(), 'provisional': 'yes'},
      {..._entry().toJson(), 'dur': -1},
      {..._entry().toJson(), 'id': 'a-different-call'},
    ]) {
      final bad = DeviceSyncEvent(
        kind: DeviceSyncKind.callLog,
        key: 'shared-call',
        tsMs: 2000,
        payload: payload,
      );
      for (final order in [
        [bad, finalRecord],
        [finalRecord, bad],
      ]) {
        expect(
          foldDeviceSync(order).values.single.payload,
          finalRecord.payload,
        );
      }
    }
    expect(CallLogEntry.fromJson(_entry().toJson())!.provisional, false);
    expect(
      CallLogEntry.fromJson(_entry(provisional: true).toJson())!.provisional,
      true,
    );
  });
  for (final interrupted in [false, true]) {
    test(
      'the retained window recovers displaced history after an earlier final time interrupted=$interrupted',
      () async {
        final kv = _RefusingStore();
        final storage = await _open(kv);
        addTearDown(storage.close);
        final store = CallLogStore(storage);
        CallLogEntry call(String id, int time, {bool provisional = false}) =>
            CallLogEntry.fromJson({
              ..._entry(
                time: time,
                provisional: provisional,
                duration: provisional ? 0 : 75,
              ).toJson(),
              'id': id,
            })!;
        final oldest = call('displaced-call', 1000);
        final fillers = [
          for (var i = 0; i < kCallLogCap - 1; i++) call('filler-$i', 2000 + i),
        ];
        final early = call('corrected-call', 10000, provisional: true);
        final finalRow = call('corrected-call', 500);
        for (final row in [oldest, ...fillers, early]) {
          await store.addMirrored(row);
        }
        expect((await store.list()).any((e) => e.id == oldest.id), false);
        final completeHistory = foldDeviceSync([
          for (final row in [oldest, ...fillers, early, finalRow])
            DeviceSyncEvent(
              kind: DeviceSyncKind.callLog,
              key: row.id,
              tsMs: row.atMs,
              payload: row.toJson(),
            ),
        ]).values.map((e) => CallLogEntry.fromJson(e.payload)!).toList();
        var emitted = 0;
        store.onAdded = (_) {
          emitted++;
        };
        if (interrupted) {
          kv.failAtAppend = kv.appendCount + 2;
          await expectLater(
            store.reconcileMirrored(completeHistory),
            throwsStateError,
          );
          expect(
            (await store.list()).singleWhere((e) => e.id == finalRow.id).atMs,
            500,
          );
          kv.failAtAppend = null;
        }
        await store.reconcileMirrored(completeHistory);
        final rows = await store.list();
        expect(rows.length, kCallLogCap);
        expect(rows.last.id, oldest.id);
        expect(rows.any((e) => e.id == finalRow.id), false);
        expect(emitted, 0, reason: 'repair must not publish a mirror echo');
        expect(kv.count(Ns.callLog), kCallLogCap);
      },
    );
  }
  for (final succeeds in [false, true]) {
    test(
      'the real call FSM records only successful media startup as connected succeeds=$succeeds',
      () async {
        final storage = await _open();
        final wire = _Wire(), media = _StartingMedia();
        final start = DateTime.utc(2026, 10, 24, 12);
        var now = start;
        final service = CallService(wire, media: media, now: () => now)
          ..start();
        final container = ProviderContainer(
          overrides: [
            storageProvider.overrideWithValue(storage),
            callServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(() async {
          service.dispose();
          container.dispose();
          await storage.close();
        });
        container.read(callLogRecorderProvider);
        final store = container.read(callLogStoreProvider);
        final recorded = Completer<void>();
        store.changes.addListener(() {
          if (!recorded.isCompleted) recorded.complete();
        });
        final peer = NodeId.fromHex('a' * 64);
        wire.onCallSignal!(
          peer,
          CallSignal(
            callId: 'startup-result',
            type: CallSignalType.offer,
            media: const CallMedia(audio: true),
            posture: CallPosture.direct,
            mediaKey: generateCallMediaKeyContribution(),
          ),
        );
        await pumpEventQueue();
        await service.accept();
        await pumpEventQueue();
        expect(service.current!.status, CallStatus.connecting);
        expect(service.current!.connectedAt, start);
        expect(service.current!.mediaStartedAt, isNull);
        now = start.add(const Duration(seconds: 10));
        final settled = service.changes.firstWhere(
          (c) => c?.status == (succeeds ? CallStatus.active : CallStatus.ended),
        );
        media.result.complete(succeeds);
        final terminal = (await settled)!;
        if (succeeds) {
          expect(terminal.mediaStartedAt, now);
          now = start.add(const Duration(seconds: 15));
          await service.hangup();
        } else {
          expect(terminal.mediaStartedAt, isNull);
        }
        await recorded.future.timeout(const Duration(seconds: 5));
        final row = (await store.list()).single;
        expect(
          row.outcome,
          succeeds ? CallLogOutcome.completed : CallLogOutcome.failed,
        );
        expect(
          row.durationSec,
          succeeds ? 5 : 0,
          reason: 'waiting for media initialization is not talk time',
        );
      },
    );
  }
}
