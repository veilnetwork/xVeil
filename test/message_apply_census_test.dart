import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'package:xveil/domain/chat.dart';

import 'support/message_apply_census.dart';
import 'support/timed_native_store.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';

void main() {
  test(
    'read census distinguishes display, row and point reads and resets its window',
    () async {
      final census = MessageApplyCensus();
      final backing = SyncWrappedAsyncKvLogStore(FakeKvLogStore());
      final storage = CountedMessageStorage(
        ({required password, required create}) async => backing,
        census,
      );
      await storage.open(password: 'fixture', createIfMissing: true);
      try {
        await storage.loadMessages('peer');
        expect(census.snapshot()['displayReadCalls'], 1);
        await storage.loadMessageRows('peer');
        expect(census.snapshot()['displayReadCalls'], 1);
        expect(census.snapshot()['historyRowsReadCalls'], 1);
        expect(await storage.loadMessageById('peer', 'missing'), isNull);
        expect(census.snapshot()['messagePointReadCalls'], 1);
        expect(census.snapshot()['historyRowsReadCalls'], 1);
        census.reset();
        expect(census.snapshot()['displayReadCalls'], 0);
        expect(census.snapshot()['historyRowsReadCalls'], 0);
        expect(census.snapshot()['messagePointReadCalls'], 0);
      } finally {
        await storage.close();
      }
    },
  );

  test(
    'prepared publications tag actual adapter commits without inventing per-row RPCs',
    () async {
      final census = MessageApplyCensus();
      final events = <Map<String, Object?>>[];
      final backing = TimedNativeStore(
        SyncWrappedAsyncKvLogStore(FakeKvLogStore()),
        census.clock,
        (event) {
          events.add(event);
          census.observeRpc(event);
        },
      );
      final storage = CountedMessageStorage(
        ({required password, required create}) async => backing,
        census,
      );
      await storage.open(password: 'fixture');
      final messages = [
        for (var i = 1; i <= 16; i++)
          Message(
            id: 'PRIVATE_ID_$i',
            conversationId: 'PRIVATE_CONVERSATION',
            author: 'PRIVATE_RAW',
            seq: i,
            direction: MessageDirection.outgoing,
            body: 'PRIVATE_BODY',
            timestamp: DateTime.utc(2026),
            status: MessageStatus.delivered,
          ),
      ];
      expect(
        await storage.appendMissingMessageBatch(
          messages,
          beforeCommit: () async {},
        ),
        List.filled(16, PreparedMessageWrite.appended),
      );
      expect(
        await storage.adoptMessageOrderingBatch([
          for (var i = 1; i <= 16; i++)
            MessageOrderingAdoption(
              conversationId: 'PRIVATE_CONVERSATION',
              messageId: 'PRIVATE_ID_$i',
              provisionalAuthor: 'PRIVATE_RAW',
              provisionalSeq: i,
              author: 'PRIVATE_CANONICAL',
              seq: 1000 + i,
            ),
        ], beforeCommit: () async {}),
        List.filled(16, true),
      );
      final dataCommits = events.where(
        (event) =>
            event['operation'] == 'kv.commit' &&
            (event['namespaces'] as List).any(
              (ns) =>
                  ns is int &&
                  ns >= Ns.messageLogShardFirst &&
                  ns <= Ns.messageLogShardLast,
            ),
      );
      expect(dataCommits, hasLength(2));
      expect(
        dataCommits.every(
          (event) => event['storage_context'] == 'historyPublish',
        ),
        isTrue,
      );
      final snapshot = census.snapshot();
      expect(
        (snapshot['contextsCompleted'] as Map)['historyPublish']['count'],
        2,
      );
      expect(
        (snapshot['rpcContextsCompleted'] as Map)['historyApply/kv.commit'],
        isNull,
      );
      expect(
        (snapshot['rpcContextsCompleted']
            as Map)['historyPublish/kv.commit']['count'],
        greaterThanOrEqualTo(2),
      );
      expect(jsonEncode(events), isNot(contains('PRIVATE_')));
      expect(jsonEncode(snapshot), isNot(contains('PRIVATE_')));
      await storage.close();
    },
  );

  for (final label in ['historyApply', 'historyEncode', 'historyPublish']) {
    test(
      '$label preserves callback identity, failures and reset boundaries',
      () async {
        var now = 0;
        final census = MessageApplyCensus(nowUs: () => now);
        final run = switch (label) {
          'historyApply' => census.historyApply<Object>,
          'historyEncode' => census.historyEncode<Object>,
          _ => census.historyPublish<Object>,
        };
        final result = Object(), error = StateError('PRIVATE_CALLBACK_ERROR');
        final entered = Completer<void>(), release = Completer<void>();
        final future = run(() async {
          expect(Zone.current[storageTimingContextKey], label);
          entered.complete();
          await release.future;
          return result;
        });
        await entered.future;
        now = 20;
        census.reset();
        now = 50;
        release.complete();
        expect(await future, same(result));
        await expectLater(run(() async => throw error), throwsA(same(error)));
        census.observeRpc({
          'operation': 'kv.commit',
          'storage_context': label,
          'start_us': 0,
          'duration_us': 50,
        });
        final snapshot = census.snapshot();
        expect((snapshot['contextsCompleted'] as Map)[label], {
          'count': 2,
          'awaitUs': 30,
          'maxAwaitUs': 30,
          'startedBeforeWindow': 1,
        });
        expect((snapshot['rpcContextsCompleted'] as Map)['$label/kv.commit'], {
          'count': 1,
          'awaitUs': 30,
          'maxAwaitUs': 30,
          'startedBeforeWindow': 1,
        });
        expect(jsonEncode(snapshot), isNot(contains('PRIVATE_')));
      },
    );
  }

  test(
    'own-device context preserves results, reset, errors and privacy',
    () async {
      var now = 0;
      final census = MessageApplyCensus(nowUs: () => now);
      final entered = Completer<void>(), release = Completer<void>();
      final result = Object();
      final pending = census.ownDevices(() async {
        expect(Zone.current[storageTimingContextKey], 'ownDevices');
        entered.complete();
        await release.future;
        return result;
      });
      await entered.future;
      now = 20;
      census.reset();
      now = 50;
      release.complete();
      expect(await pending, same(result));
      final error = StateError('PRIVATE_ERROR');
      await expectLater(
        census.ownDevices(() async => throw error),
        throwsA(same(error)),
      );
      census.observeRpc({
        'operation': 'kv.get',
        'storage_context': 'ownDevices',
        'start_us': 0,
        'duration_us': 50,
      });
      census.observeRpc({
        'operation': 'kv.get',
        'storage_context': 'PRIVATE_CONTEXT',
        'start_us': 30,
        'duration_us': 10,
      });
      final out = census.snapshot();
      expect((out['contextsCompleted'] as Map)['ownDevices'], {
        'count': 2,
        'awaitUs': 30,
        'maxAwaitUs': 30,
        'startedBeforeWindow': 1,
      });
      expect((out['rpcContextsCompleted'] as Map)['ownDevices/kv.get'], {
        'count': 1,
        'awaitUs': 30,
        'maxAwaitUs': 30,
        'startedBeforeWindow': 1,
      });
      expect(jsonEncode(out), isNot(contains('PRIVATE_')));
    },
  );
  test(
    'message methods preserve outcomes and clip reset without error data',
    () async {
      var now = 0;
      final census = MessageApplyCensus(nowUs: () => now);
      final entered = Completer<void>(), release = Completer<void>();
      final pending = census.messageOperation(
        MessageStorageOperation.adoptOrdering,
        () async {
          entered.complete();
          await release.future;
          return true;
        },
      );
      await entered.future;
      now = 50;
      census.reset();
      now = 80;
      release.complete();
      expect(await pending, isTrue);
      expect(
        await census.messageOperation(
          MessageStorageOperation.markStatus,
          () async => false,
        ),
        isFalse,
      );
      final error = StateError('PRIVATE_METHOD_ERROR');
      await expectLater(
        census.messageOperation(
          MessageStorageOperation.markStatus,
          () async => throw error,
        ),
        throwsA(same(error)),
      );
      final out = census.snapshot();
      final methods = out['messageOperationsCompleted'] as Map;
      expect(methods['adoptOrdering'], {
        'count': 1,
        'awaitUs': 30,
        'maxAwaitUs': 30,
        'startedBeforeWindow': 1,
        'changed': 1,
        'failed': 0,
      });
      expect(methods['markStatus'], {
        'count': 2,
        'awaitUs': 0,
        'maxAwaitUs': 0,
        'startedBeforeWindow': 0,
        'changed': 0,
        'failed': 1,
      });
      expect(jsonEncode(out), isNot(contains('PRIVATE_')));
    },
  );

  test(
    'census distinguishes successful scoped repeats from failed attempts',
    () {
      var now = 0;
      final census = MessageApplyCensus(nowUs: () => now);
      final a = census.beginAppend(), b = census.beginAppend();
      now = 10;
      census.endAppend(a, 'PRIVATE_CONVERSATION', 'PRIVATE_ID', success: false);
      census.endAppend(b, 'PRIVATE_CONVERSATION', 'PRIVATE_ID', success: true);
      final other = census.beginAppend();
      now = 20;
      census.endAppend(other, 'PRIVATE_OTHER', 'PRIVATE_ID', success: true);
      final repeated = census.beginAppend();
      now = 30;
      census.endAppend(
        repeated,
        'PRIVATE_CONVERSATION',
        'PRIVATE_ID',
        success: true,
      );
      final out = census.snapshot();
      expect(out['appendStarted'], 4);
      expect(out['appendCompleted'], 3);
      expect(out['appendFailed'], 1);
      expect(out['duplicateCompletedInWindow'], 1);
      expect(out['appendActive'], 0);
      expect(out['appendMaxActive'], 2);
      expect(out['appendAwaitUs'], 40);
      expect(jsonEncode(out), isNot(contains('PRIVATE_')));
    },
  );

  test(
    'reset retains outstanding work and clips its wait to the new window',
    () {
      var now = 0;
      final census = MessageApplyCensus(nowUs: () => now);
      final pending = census.beginAppend();
      now = 50;
      census.reset();
      expect(census.snapshot()['appendActive'], 1);
      now = 80;
      census.endAppend(pending, 'peer', 'id', success: true);
      final out = census.snapshot();
      expect(out['appendStarted'], 0);
      expect(out['appendCompleted'], 1);
      expect(out['appendCompletedFromEarlierStarts'], 1);
      expect(out['appendAwaitUs'], 30);
      expect(out['appendActive'], 0);
    },
  );

  test(
    'RPC categories keep only completed waits, not payload or error fields',
    () {
      var now = 50;
      final census = MessageApplyCensus(nowUs: () => now);
      census.observeRpc({
        'operation': 'kv.commit',
        'start_us': 0,
        'duration_us': 80,
        'namespaces': [Ns.messageLogShardFirst],
        'key': 'PRIVATE_KEY',
        'path': 'PRIVATE_PATH',
        'error': 'PRIVATE_ERROR',
      });
      census.observeRpc({
        'operation': 'kv.commit',
        'start_us': 60,
        'duration_us': 10,
        'namespaces': [Ns.settings],
      });
      census.observeRpc({
        'operation': 'PRIVATE_OPERATION',
        'start_us': 60,
        'duration_us': 10,
      });
      census.observeRpc({
        'operation': 'kv.get',
        'start_us': 0,
        'duration_us': 20,
      });
      now = 100;
      final rpc = census.snapshot()['rpcCompleted'] as Map;
      expect(rpc.keys, ['kv.commit.messageLog', 'kv.commit.other']);
      expect(rpc['kv.commit.messageLog'], {
        'count': 1,
        'awaitUs': 30,
        'maxAwaitUs': 30,
        'startedBeforeWindow': 1,
      });
      expect(rpc['kv.commit.other'], {
        'count': 1,
        'awaitUs': 10,
        'maxAwaitUs': 10,
        'startedBeforeWindow': 0,
      });
      expect(jsonEncode(census.snapshot()), isNot(contains('PRIVATE_')));
    },
  );

  test('bounded key tracking advertises incomplete duplicate coverage', () {
    final census = MessageApplyCensus(nowUs: () => 0);
    for (var i = 0; i <= MessageApplyCensus.maxKeys; i++) {
      census.endAppend(census.beginAppend(), 'peer', '$i', success: true);
    }
    expect(census.snapshot()['trackedKeys'], MessageApplyCensus.maxKeys);
    expect(census.snapshot()['keyLimitReached'], isTrue);
    census.reset();
    expect(census.snapshot()['trackedKeys'], 0);
    expect(census.snapshot()['keyLimitReached'], isFalse);
  });

  test('large archive census retains every one of 100001 distinct keys', () {
    final census = MessageApplyCensus(nowUs: () => 0, maxTrackedKeys: 100001);
    for (var i = 0; i < 100001; i++) {
      census.endAppend(census.beginAppend(), 'peer', '$i', success: true);
    }
    expect(census.snapshot()['trackedKeys'], 100001);
    expect(census.snapshot()['keyLimit'], 100001);
    expect(census.snapshot()['keyLimitReached'], isFalse);
    census.endAppend(census.beginAppend(), 'peer', '100000', success: true);
    expect(census.snapshot()['duplicateCompletedInWindow'], 1);
    expect(census.snapshot()['keyLimitReached'], isFalse);
  });

  for (final limit in [0, -1, 200001]) {
    test('invalid census limit is rejected ($limit)', () {
      expect(
        () => MessageApplyCensus(maxTrackedKeys: limit),
        throwsArgumentError,
      );
    });
  }

  test('namespace census is inclusive, deduplicated and uses fixed labels', () {
    final census = MessageApplyCensus(nowUs: () => 0);
    census.observeRpc({
      'operation': 'kv.commit',
      'start_us': 0,
      'duration_us': 10,
      'namespaces': [
        Ns.settings,
        Ns.outbox,
        Ns.outbox,
        Ns.messageLogShardFirst,
        Ns.messageLogShardLast,
        123456789,
        'PRIVATE_NAMESPACE',
      ],
    });
    final out = census.snapshot()['rpcNamespacesCompleted'] as Map;
    expect(out.keys, [
      'kv.commit.messageLog',
      'kv.commit.other',
      'kv.commit.outbox',
      'kv.commit.settings',
    ]);
    for (final value in out.values) {
      expect(value['count'], 1);
      expect(value['awaitUs'], 10);
    }
    expect(jsonEncode(out), isNot(contains('123456789')));
    expect(jsonEncode(out), isNot(contains('PRIVATE_')));
    census.reset();
    expect(census.snapshot()['rpcNamespacesCompleted'], isEmpty);
  });
  test(
    'file attribution keeps only fixed kinds and clips outstanding calls on reset',
    () async {
      var now = 0;
      final census = MessageApplyCensus(nowUs: () => now);
      final entered = Completer<void>(), release = Completer<void>();
      final pending = census.fileOperation(
        'load',
        'group:PRIVATE_ID',
        () async {
          expect(Zone.current[storageTimingOperationKey], 'file.load.header');
          entered.complete();
          await release.future;
          census.observeRpc({
            'operation': 'kv.get',
            'start_us': 0,
            'duration_us': 80,
            'storage_operation': Zone.current[storageTimingOperationKey],
          });
        },
      );
      await entered.future;
      now = 50;
      census.reset();
      now = 80;
      release.complete();
      await pending;
      final out = census.snapshot();
      expect((out['storageOperationsCompleted'] as Map)['file.load.header'], {
        'count': 1,
        'awaitUs': 30,
        'maxAwaitUs': 30,
        'startedBeforeWindow': 1,
      });
      expect(
        (out['rpcStorageOperationsCompleted']
            as Map)['file.load.header/kv.get']['awaitUs'],
        30,
      );
      census.observeRpc({
        'operation': 'kv.get',
        'start_us': 60,
        'duration_us': 10,
        'storage_operation': 'PRIVATE_ZONE',
      });
      expect(jsonEncode(census.snapshot()), isNot(contains('PRIVATE_')));
      census.reset();
      expect(census.snapshot()['storageOperationsCompleted'], isEmpty);
      expect(census.snapshot()['rpcStorageOperationsCompleted'], isEmpty);
    },
  );

  test(
    'worker adapter propagates allowed attribution without copying keys',
    () async {
      final census = MessageApplyCensus();
      final events = <Map<String, Object?>>[];
      final store = TimedNativeStore(
        SyncWrappedAsyncKvLogStore(FakeKvLogStore()),
        census.clock,
        (event) {
          events.add(event);
          census.observeRpc(event);
        },
      );
      await census.fileOperation(
        'hasBatch',
        'group:PRIVATE_ID:s:PRIVATE_SEGMENT',
        () async {
          await store.getBatch(Ns.settings, [
            Uint8List.fromList(utf8.encode('PRIVATE_KEY')),
          ]);
        },
      );
      expect(events.single['storage_operation'], 'file.hasBatch.segment');
      await census.ownDevices(() => store.get(Ns.settings, Uint8List(0)));
      expect(events.last['storage_context'], 'ownDevices');
      expect(
        (census.snapshot()['rpcContextsCompleted']
            as Map)['ownDevices/kv.get']['count'],
        1,
      );
      expect(
        (census.snapshot()['rpcStorageOperationsCompleted']
            as Map)['file.hasBatch.segment/kv.getBatch']['count'],
        1,
      );
      await runZoned(
        () => store.get(Ns.settings, Uint8List(0)),
        zoneValues: {
          storageTimingOperationKey: 'PRIVATE_ZONE',
          storageTimingContextKey: 'PRIVATE_CONTEXT',
        },
      );
      expect(events.last.containsKey('storage_operation'), isFalse);
      expect(events.last.containsKey('storage_context'), isFalse);
      expect(jsonEncode(events), isNot(contains('PRIVATE_')));
      expect(jsonEncode(census.snapshot()), isNot(contains('PRIVATE_')));
      await store.close();
    },
  );
}
