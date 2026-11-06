import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'support/storage_commit_classification.dart';
import 'support/message_apply_census.dart';
import 'support/timed_native_store.dart';

Uint8List b(String text) => Uint8List.fromList(utf8.encode(text));
PutOp setting(String key) => PutOp(Ns.settings, b(key), b('PRIVATE_PAYLOAD'));

void main() {
  test('fixed key shapes classify commits without values or suffixes', () {
    final cases = <String, List<KvLogOp>>{
      'historyCursor': [setting('set:device.history.cursor.v2:PRIVATE_NODE')],
      'ratchetReservation': [setting('set:ratchet_reserve:PRIVATE_KEY')],
      'messageAllocator': [setting('msg_next_id')],
      'messageSequence': [setting('conv_seq:PRIVATE_NODE')],
      'syncFloor': [setting('set:sync_floor:PRIVATE_NODE')],
      'groupSettings': [setting('set:groups.index')],
      'deviceSettings': [setting('set:devices.gid')],
      'contactSettings': [setting('contact.status.floor.v1:PRIVATE_NODE')],
      'settingsOther': [setting('PRIVATE_PATH_OR_ID')],
      'files': [setting('file:PRIVATE_PATH')],
      'messages': [
        AppendLogOp(Ns.messageLogShardFirst, 1, b('PRIVATE_BODY')),
        setting('msg_next_id'),
      ],
      'outbox': [AppendLogOp(Ns.outbox, 1, b('PRIVATE_BODY'))],
      'ratchet': [PutOp(Ns.ratchet, Uint8List(66), b('PRIVATE_KEY'))],
      'peerAuthorization': [
        PutOp(Ns.ratchet, Uint8List(35)..[0] = 0x50, b('PRIVATE_CERT')),
      ],
      'other': [PutOp(999, b('PRIVATE_KEY'), b('PRIVATE_BODY'))],
      'empty': [],
    };
    for (final entry in cases.entries) {
      final result = classifyStorageCommit(entry.value);
      expect(result.primary, entry.key);
      expect(result.components.every(storageCommitLabels.contains), isTrue);
      expect(
        jsonEncode({'class': result.primary, 'components': result.components}),
        isNot(contains('PRIVATE')),
      );
    }
    expect(
      classifyStorageCommit([
        setting('PRIVATE'),
      ], storageOperation: 'PRIVATE_CONTEXT').primary,
      'settingsOther',
    );
    expect(
      classifyStorageCommit([
        setting('file:PRIVATE'),
      ], storageOperation: 'file.store.segment').primary,
      'groupSegment',
    );
    expect(
      classifyStorageCommit([
        setting('file:PRIVATE'),
      ], storageOperation: 'file.store.header').primary,
      'groupHeader',
    );
    expect(
      classifyStorageCommit([
        setting('file:PRIVATE'),
      ], storageOperation: 'file.storePair.header').primary,
      'groupPair',
    );
  });

  test('mixed domains are not attributed entirely to one major namespace', () {
    final ratchet = PutOp(Ns.ratchet, Uint8List(66), b('PRIVATE_KEY'));
    final message = AppendLogOp(Ns.messageLogShardFirst, 1, b('PRIVATE_BODY'));
    expect(classifyStorageCommit([ratchet, message]).primary, 'mixed');
    expect(
      classifyStorageCommit([ratchet, setting('file:PRIVATE')]).primary,
      'mixed',
    );
    expect(
      classifyStorageCommit([
        PutOp(Ns.ratchet, Uint8List.fromList([0x50]), b('PRIVATE')),
      ]).primary,
      'peerAuthorization',
    );
    expect(
      classifyStorageCommit([
        PutOp(Ns.ratchet, Uint8List(1), b('PRIVATE')),
      ]).primary,
      'ratchet',
    );
  });

  test(
    'adapter forwards original data and census reports only fixed categories',
    () async {
      final raw = FakeKvLogStore();
      final census = MessageApplyCensus();
      final events = <Map<String, Object?>>[];
      final store = TimedNativeStore(
        SyncWrappedAsyncKvLogStore(raw),
        census.clock,
        (event) {
          events.add(event);
          census.observeRpc(event);
        },
      );
      addTearDown(store.close);
      final op = setting('set:device.history.cursor.v2:PRIVATE_NODE');
      await store.commit([op]);
      expect(raw.get(Ns.settings, op.key), op.value);
      expect(events.single['commit_class'], 'historyCursor');
      expect(events.single['commit_components'], ['historyCursor']);
      expect(events.single['ok'], isTrue);
      final classes = census.snapshot()['commitClassesCompleted'] as Map;
      expect((classes['historyCursor'] as Map)['count'], 1);
      census.observeRpc({
        'operation': 'kv.commit',
        'start_us': census.nowUs,
        'duration_us': 0,
        'commit_class': 'PRIVATE_CLASS',
        'commit_components': ['PRIVATE_KEY', 'files', 'files'],
        'ok': false,
      });
      final result = census.snapshot();
      expect(
        ((result['commitClassesCompleted'] as Map)['unclassified']
            as Map)['failed'],
        1,
      );
      expect(
        ((result['commitComponentsCompleted'] as Map)['files'] as Map)['count'],
        1,
      );
      expect(jsonEncode(events), isNot(contains('PRIVATE')));
      expect(jsonEncode(result), isNot(contains('PRIVATE')));
      census.reset();
      expect(census.snapshot()['commitClassesCompleted'], isEmpty);
      expect(census.snapshot()['commitComponentsCompleted'], isEmpty);
    },
  );
}
