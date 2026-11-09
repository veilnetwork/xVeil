import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';

import 'support/message_apply_census.dart';
import 'support/private_history_work_probe.dart';

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('history-work-');
    file = File('${dir.path}/work.jsonl');
  });
  tearDown(() async => dir.delete(recursive: true));
  Future<List<Map>> read() async => [
    for (final line in await file.readAsLines()) jsonDecode(line) as Map,
  ];

  test(
    'overlapping callbacks form busy intervals with preserved results',
    () async {
      var now = 0;
      final probe = PrivateHistoryWorkProbe(file, nowUs: () => now);
      final census = MessageApplyCensus(observeStage: probe.observe);
      final release = Completer<void>();
      final first = census.historyApply(() async {
        await release.future;
        return 1;
      });
      now = 10;
      expect(await census.historyApply(() async => 2), 2);
      expect(await census.historyPublish(() async => 3), 3);
      now = 20;
      release.complete();
      expect(await first, 1);
      await probe.close();
      final rows = await read();
      expect(rows.where((r) => r['stage'] == 'historyApply').toList(), [
        {
          'kind': 'begin',
          'atUs': 0,
          'stage': 'historyApply',
          'calls': 1,
          'failures': 0,
        },
        {
          'kind': 'end',
          'atUs': 20,
          'stage': 'historyApply',
          'calls': 2,
          'failures': 0,
        },
      ]);
      expect((rows.last['active'] as Map).values.every((v) => v == 0), isTrue);
      expect(rows.last['dropped'], 0);
    },
  );

  test('error identity survives and a failed interval is closed', () async {
    final probe = PrivateHistoryWorkProbe(file);
    final census = MessageApplyCensus(observeStage: probe.observe);
    final error = StateError('PRIVATE_CALLBACK_TEXT');
    await expectLater(
      census.historyCheckpoint(() async => throw error),
      throwsA(same(error)),
    );
    await probe.close();
    final rows = await read();
    expect(rows.where((r) => r['kind'] == 'end').single['failures'], 1);
    expect(await file.readAsString(), isNot(contains('PRIVATE_')));
  });

  test('only fixed stage labels can be written', () async {
    final probe = PrivateHistoryWorkProbe(file);
    probe.observe('PRIVATE_ID_OR_PATH', true, false);
    probe.observe('PRIVATE_ID_OR_PATH', false, false);
    await probe.close();
    expect(await read(), hasLength(2));
    expect(await file.readAsString(), isNot(contains('PRIVATE_')));
  });

  test(
    'budget is bounded without losing final active or dropped counters',
    () async {
      final probe = PrivateHistoryWorkProbe(file, maxRecords: 1);
      probe.observe('historyApply', true, false);
      probe.observe('historyApply', false, true);
      await probe.close();
      final rows = await read();
      expect(rows, hasLength(3));
      expect(rows.last['recorded'], 1);
      expect(rows.last['dropped'], 1);
      expect(rows.last['active']['historyApply'], 0);
    },
  );

  test(
    'invalid budget creates no file and unpaired end fails explicitly',
    () async {
      expect(
        () => PrivateHistoryWorkProbe(file, maxRecords: 0),
        throwsArgumentError,
      );
      expect(await file.exists(), isFalse);
      final probe = PrivateHistoryWorkProbe(file);
      expect(
        () => probe.observe('historyApply', false, true),
        throwsStateError,
      );
      await probe.close();
    },
  );

  test(
    'close is idempotent and late callbacks do not write to a closed sink',
    () async {
      final probe = PrivateHistoryWorkProbe(file);
      final first = probe.close();
      expect(probe.close(), same(first));
      await first;
      probe.observe('historyApply', true, false);
      expect(await read(), hasLength(2));
    },
  );

  test(
    'cursor adapter measures only actual cursor writes and keeps stored values',
    () async {
      final census = MessageApplyCensus();
      final backing = SyncWrappedAsyncKvLogStore(FakeKvLogStore());
      final storage = CountedMessageStorage(
        ({required password, required create}) async => backing,
        census,
      );
      await storage.open(password: 'fixture', createIfMissing: true);
      try {
        await storage.putSetting('ordinary', 'PRIVATE_OTHER_VALUE');
        await storage.putSetting(
          'device.history.cursor.v2:PRIVATE_DEVICE',
          'PRIVATE_CURSOR',
        );
        expect(
          await storage.getSetting('device.history.cursor.v2:PRIVATE_DEVICE'),
          'PRIVATE_CURSOR',
        );
        final snapshot = census.snapshot();
        expect(
          (snapshot['contextsCompleted'] as Map)['historyCheckpoint']['count'],
          1,
        );
        expect(jsonEncode(snapshot), isNot(contains('PRIVATE_')));
      } finally {
        await storage.close();
      }
    },
  );
}
