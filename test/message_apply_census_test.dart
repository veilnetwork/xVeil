import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

import 'support/message_apply_census.dart';

void main() {
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
}
