import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/rollback_anchor.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

class _Store extends FakeKvLogStore {
  int scrubs = 0;
  bool failScrub = false;
  bool failCheckpoint = false;
  bool failProbe = false;
  int maintenanceCommits = 0;

  @override
  int commit(List<KvLogOp> ops) {
    if (failCheckpoint &&
        ops.any(
          (op) =>
              op is PutOp &&
              utf8.decode(op.key) == 'storage.message_delete_scrub.legacy.v1',
        )) {
      throw StateError('fixture completion checkpoint refusal');
    }
    return super.commit(ops);
  }

  @override
  int count(int namespace) {
    if (failProbe && namespace == Ns.messageLogShardFirst) {
      throw StateError('fixture metadata probe refusal');
    }
    return super.count(namespace);
  }

  @override
  void scrub() {
    scrubs++;
    if (failScrub) throw StateError('fixture scrub refusal');
    for (var i = 0; i < maintenanceCommits; i++) {
      super.commit([
        PutOp(Ns.settings, _bytes('maintenance-fixture'), _bytes('$i')),
      ]);
    }
    super.scrub();
  }
}

class _Anchor implements RollbackAnchorStore {
  _Anchor(this.record);
  AnchorRecord record;
  bool refuse = false;
  @override
  Future<AnchorRecord?> read() async => record;
  @override
  Future<bool> write(AnchorRecord next) async {
    if (refuse) return false;
    record = next;
    return true;
  }
}

// The pre-recovery writer replaces the original log row atomically, with no
// pending scrub flag. Keep the fixture independent of the new storage writer.
void _legacyDelete(KvLogStore raw, {int ns = Ns.messageLogShardFirst}) {
  raw.commit([
    AppendLogOp(
      ns,
      1,
      _bytes(
        jsonEncode({
          'id': 'old-target',
          'c': 'fixture-peer',
          'd': 0,
          'b': 'old fixture body',
          't': 1000,
          's': 0,
          'au': 'fixture-peer',
          'sq': 1,
        }),
      ),
    ),
    PutOp(Ns.settings, _bytes('msg_next_id'), _bytes('2')),
    PutOp(Ns.settings, _bytes('msglog_ns:v1:$ns'), _bytes('$ns')),
  ]);
  raw.commit([
    AppendLogOp(
      ns,
      1,
      _bytes(
        jsonEncode({
          'op': 'del',
          'id': 'old-target',
          'c': 'fixture-peer',
          'au': 'fixture-peer',
          'sq': 1,
        }),
      ),
    ),
  ]);
}

HiddenVolumeStorage _handle(_Store raw) => HiddenVolumeStorage(
  ({required Uint8List password, required bool create}) => raw,
  keysOpener: (_) => raw,
);

void main() {
  for (final mode in ['password', 'keys', 'sync-view', 'async-view']) {
    test('legacy deletion is scrubbed once through $mode', () async {
      final raw = _Store();
      _legacyDelete(raw);
      final storage = switch (mode) {
        'sync-view' => HiddenVolumeStorage.fromStore(raw),
        'async-view' => HiddenVolumeStorage.fromAsyncStore(
          SyncWrappedAsyncKvLogStore(raw),
        ),
        _ => _handle(raw),
      };
      addTearDown(storage.close);
      if (mode == 'password') await storage.open(password: 'fixture');
      if (mode == 'keys') await storage.openWithKeys(Uint8List(64));
      expect(
        await storage.isMessageDeleted('fixture-peer', 'old-target'),
        isTrue,
      );
      expect(raw.scrubs, 1);
      expect(await storage.loadMessages('fixture-peer'), isEmpty);
      await storage.close();
      final reopened = _handle(raw);
      await reopened.open(password: 'fixture');
      expect(
        raw.scrubs,
        1,
        reason: 'a completed migration must not vacuum every boot',
      );
      await reopened.close();
    });
  }

  test(
    'failed migration retries before a lazy view can return history',
    () async {
      final raw = _Store();
      _legacyDelete(raw);
      final storage = HiddenVolumeStorage.fromStore(raw);
      raw.failScrub = true;
      await expectLater(storage.loadMessages('fixture-peer'), throwsStateError);
      raw.failScrub = false;
      expect(await storage.loadMessages('fixture-peer'), isEmpty);
      expect(raw.scrubs, 2);
      await storage.close();
    },
  );

  test('fresh empty space does not need a legacy vacuum', () async {
    final raw = _Store();
    final storage = _handle(raw);
    await storage.open(password: 'fixture');
    expect(raw.scrubs, 0);
    await storage.close();
    await storage.open(password: 'fixture');
    expect(raw.scrubs, 0);
    await storage.close();
  });

  for (final ns in [Ns.messageLog, Ns.messageLogShardRetiredLast]) {
    test(
      'legacy metadata probe includes namespace $ns without a next-id hint',
      () async {
        final raw = _Store();
        _legacyDelete(raw, ns: ns);
        raw.commit([DeleteOp(Ns.settings, _bytes('msg_next_id'))]);
        final storage = _handle(raw);
        await storage.open(password: 'fixture');
        expect(raw.scrubs, 1);
        expect(jsonDecode(utf8.decode(raw.readLog(ns, 1)!))['op'], 'del');
        await storage.close();
      },
    );
  }

  test('failed checkpoint cannot mark a migration complete', () async {
    final raw = _Store();
    _legacyDelete(raw);
    raw.failCheckpoint = true;
    final storage = _handle(raw);
    await expectLater(storage.open(password: 'fixture'), throwsStateError);
    expect(storage.isOpen, isFalse);
    raw.failCheckpoint = false;
    await storage.open(password: 'fixture');
    expect(raw.scrubs, 2);
    await storage.close();
    await storage.open(password: 'fixture');
    expect(raw.scrubs, 2);
    await storage.close();
  });

  test(
    'reusing an open handle cannot carry a maintenance snapshot to another identity',
    () async {
      final one = _Store(), two = _Store();
      _legacyDelete(one);
      _legacyDelete(two);
      final storage = HiddenVolumeStorage(
        ({required Uint8List password, required bool create}) =>
            utf8.decode(password) == 'one' ? one : two,
      );
      await storage.open(password: 'one');
      final first = storage.anchorBeforeMaintenance!;
      await storage.open(password: 'two');
      final second = storage.anchorBeforeMaintenance!;
      expect(second.generation, isNot(first.generation));
      final anchor = _Anchor(
        AnchorRecord(
          generation: second.generation,
          seq: second.seq,
          root: second.roots[second.seq],
        ),
      );
      final verdict = await checkContainerAgainstAnchor(
        storage: storage,
        anchor: anchor,
        reserveAhead: 32,
      );
      expect(verdict.verdict, AnchorVerdict.clean);
      await storage.close();
    },
  );

  for (final condition in [
    'clean',
    'rollback',
    'fork',
    'anchor-write-refusal',
  ]) {
    test(
      'opening maintenance cannot launder $condition beyond the anchor horizon',
      () async {
        final raw = _Store();
        _legacyDelete(raw);
        final before = HiddenVolumeStorage.fromStore(raw);
        final reading = (await before.readCommitAnchor())!;
        final anchor = _Anchor(
          AnchorRecord(
            generation: reading.generation,
            seq: reading.seq,
            root: reading.roots[reading.seq],
          ),
        );
        await before.close();
        if (condition == 'rollback') raw.rollbackTo(reading.seq - 1);
        if (condition == 'fork') raw.branch++;
        raw.maintenanceCommits = anchorHorizon + 5;
        final opened = _handle(raw);
        addTearDown(opened.close);
        await opened.open(password: 'fixture');
        final after = (await opened.readCommitAnchor())!;
        expect(after.seq - reading.seq, greaterThan(anchorHorizon));
        if (condition == 'anchor-write-refusal') anchor.refuse = true;
        final expected = switch (condition) {
          'rollback' => AnchorVerdict.rolledBack,
          'fork' => AnchorVerdict.forked,
          _ => AnchorVerdict.clean,
        };
        final result = await checkContainerAgainstAnchor(
          storage: opened,
          anchor: anchor,
          reserveAhead: 32,
        );
        expect(result.verdict, expected);
        final suspicious = condition == 'rollback' || condition == 'fork';
        if (suspicious || anchor.refuse) {
          expect(anchor.record.seq, reading.seq);
          expect(opened.anchorBeforeMaintenance, isNotNull);
        } else {
          expect(anchor.record.seq, after.seq);
          expect(anchor.record.root, after.roots[after.seq]);
          expect(opened.anchorBeforeMaintenance, isNull);
        }
        if (anchor.refuse) {
          expect(result.anchorNotRecorded, isTrue);
          anchor.refuse = false;
        }
        final again = await checkContainerAgainstAnchor(
          storage: opened,
          anchor: anchor,
          reserveAhead: 32,
        );
        expect(again.verdict, expected);
        if (suspicious) expect(anchor.record.seq, reading.seq);
      },
    );
  }

  test(
    'failed namespace probe cannot classify legacy history as empty',
    () async {
      final raw = _Store();
      _legacyDelete(raw);
      raw.failProbe = true;
      final storage = HiddenVolumeStorage.fromStore(raw);
      await expectLater(storage.loadMessages('fixture-peer'), throwsStateError);
      expect(raw.scrubs, 0);
      raw.failProbe = false;
      expect(await storage.loadMessages('fixture-peer'), isEmpty);
      expect(raw.scrubs, 1);
      await storage.close();
    },
  );
}
