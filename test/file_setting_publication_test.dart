import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

Uint8List _key(String value) => Uint8List.fromList(utf8.encode(value));
Uint8List _bytes(int size, int seed) =>
    Uint8List.fromList(List.generate(size, (i) => (i * 17 + seed) % 251));
bool _publishes(List<KvLogOp> ops) => ops.whereType<PutOp>().any(
  (op) => utf8.decode(op.key) == 'set:devices.gid',
);

class _Store extends FakeKvLogStore {
  final commits = <List<KvLogOp>>[];
  bool reject = false, losePublication = false, loseStage = false;
  @override
  int commit(List<KvLogOp> ops) {
    commits.add(List.of(ops));
    if (reject && _publishes(ops)) throw StateError('publication refused');
    final result = super.commit(ops);
    if (losePublication && _publishes(ops)) {
      losePublication = false;
      throw StateError('publication reply lost');
    }
    if (loseStage && !_publishes(ops) && ops.any((op) => op is AppendLogOp)) {
      loseStage = false;
      throw StateError('staging reply lost');
    }
    return result;
  }
}

class _Held extends SyncWrappedAsyncKvLogStore {
  _Held(super.inner);
  bool hold = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<int> commit(List<KvLogOp> ops) async {
    if (hold && _publishes(ops)) {
      hold = false;
      entered.complete();
      await release.future;
    }
    return super.commit(ops);
  }
}

String? _gid(_Store raw) {
  final value = raw.get(Ns.settings, _key('set:devices.gid'));
  return value == null ? null : utf8.decode(value);
}

void _accounting(_Store raw) {
  final state =
      jsonDecode(utf8.decode(raw.get(Ns.settings, _key('file_chunk_gc'))!))
          as Map;
  expect(state['live'], raw.count(Ns.fileChunks));
}

void main() {
  late _Store raw;
  late AsyncFileStore files;
  final old = _bytes(3600, 1), next = _bytes(7000, 2);
  const file = 'credential';
  Future<void> publish(Uint8List value, String gid) => files
      .storeFile(
        file,
        value,
        publicationSetting: (key: 'devices.gid', value: gid),
      )
      .then((_) {});
  setUp(() {
    raw = _Store();
    files = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
  });
  Future<void> seed() async {
    await publish(old, 'old');
    raw.commits.clear();
  }

  test('fresh file and setting publish in one complete commit', () async {
    await publish(next, 'new');
    expect(raw.commits, hasLength(1));
    expect(_publishes(raw.commits.single), isTrue);
    expect(
      raw.commits.single.whereType<PutOp>().any(
        (op) => utf8.decode(op.key) == 'file:$file',
      ),
      isTrue,
    );
    expect(await files.loadFile(file), next);
    expect(_gid(raw), 'new');
    _accounting(raw);
  });

  test(
    'staged replacement remains the old pair until final publication',
    () async {
      await seed();
      final gate = _Held(raw)..hold = true;
      files = AsyncFileStore(gate);
      final pending = publish(next, 'new');
      addTearDown(() async {
        if (!gate.release.isCompleted) gate.release.complete();
        await pending;
      });
      await gate.entered.future;
      expect(FileStore(raw).loadFile(file), old);
      expect(_gid(raw), 'old');
      gate.release.complete();
      await pending;
      expect(await files.loadFile(file), next);
      expect(_gid(raw), 'new');
      _accounting(raw);
    },
  );

  for (final failure in ['refused', 'lostStage', 'lostPublication']) {
    test('$failure preserves a whole pair and permits retry', () async {
      await seed();
      raw.reject = failure == 'refused';
      raw.loseStage = failure == 'lostStage';
      raw.losePublication = failure == 'lostPublication';
      await expectLater(publish(next, 'new'), throwsStateError);
      final committed = failure == 'lostPublication';
      expect(await files.loadFile(file), committed ? next : old);
      expect(_gid(raw), committed ? 'new' : 'old');
      _accounting(raw);
      raw.reject = false;
      await publish(next, 'new');
      expect(await files.loadFile(file), next);
      expect(_gid(raw), 'new');
      _accounting(raw);
    });
  }

  test(
    'identical file still publishes a changed setting, then no-ops',
    () async {
      await seed();
      await publish(old, 'new');
      expect(raw.commits, hasLength(1));
      expect(raw.commits.single, hasLength(1));
      expect(_gid(raw), 'new');
      await publish(old, 'new');
      expect(raw.commits, hasLength(1));
    },
  );

  test('oversize publication is refused without writes', () async {
    await seed();
    await expectLater(
      publish(_bytes(StoredFileSettingWriter.maxBytes + 1, 2), 'new'),
      throwsArgumentError,
    );
    expect(raw.commits, isEmpty);
    expect(await files.loadFile(file), old);
    expect(_gid(raw), 'old');
  });

  test(
    'storage pins bytes and drains accepted publication before close',
    () async {
      final gate = _Held(raw)..hold = true;
      final storage = HiddenVolumeStorage.async(
        ({required password, required create}) async => gate,
      );
      expect(await storage.open(password: 'pw'), isTrue);
      final input = Uint8List.fromList(next);
      final writing = storage.storeFileWithSetting(
        StoredFileWrite(file, input),
        settingKey: 'devices.gid',
        settingValue: 'new',
      );
      addTearDown(() async {
        if (!gate.release.isCompleted) gate.release.complete();
        await writing;
        await storage.close();
      });
      await gate.entered.future;
      input.fillRange(0, input.length, 0);
      final closing = storage.close();
      await expectLater(
        storage.storeFileWithSetting(
          StoredFileWrite('late', old),
          settingKey: 'devices.gid',
          settingValue: 'late',
        ),
        throwsStateError,
      );
      gate.release.complete();
      await writing;
      await closing;
      expect(FileStore(raw).loadFile(file), next);
      expect(_gid(raw), 'new');
    },
  );
}
