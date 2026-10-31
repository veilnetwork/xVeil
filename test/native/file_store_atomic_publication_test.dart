import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

Uint8List _key(String value) => Uint8List.fromList(utf8.encode(value));
Uint8List _bytes(int size) {
  final random = Random(size);
  return Uint8List.fromList(List.generate(size, (_) => random.nextInt(256)));
}

class _CountingNativeStore extends HvKvLogStore {
  _CountingNativeStore(super.space);
  final sizes = <int>[];
  bool rejectHeader = false;

  @override
  int commit(List<KvLogOp> ops) {
    sizes.add(ops.length);
    if (rejectHeader &&
        ops.whereType<PutOp>().any(
          (op) => utf8.decode(op.key) == 'file:header',
        )) {
      // Real native transaction rejection, including already-staged deletes.
      return super.commit([
        ...ops,
        PutOp(Ns.settings, _key('invalid'), _bytes(8000)),
      ]);
    }
    return super.commit(ops);
  }
}

void main() {
  for (final asynchronous in [false, true]) {
    test(
      'native ${asynchronous ? 'async' : 'sync'} atomic creation, fallback and reopen',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'xveil-file-atomic-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final path = '${directory.path}/fixture.hv';
        final password = _key('fixture-password');
        var space = hv.HvSpace.create(
          path: path,
          password: password,
          argon: hv.ArgonPreset.light,
        );
        var raw = _CountingNativeStore(space);
        addTearDown(() => raw.close());
        Future<void> write(String id, Uint8List data) async {
          if (asynchronous) {
            await AsyncFileStore(
              SyncWrappedAsyncKvLogStore(raw),
            ).storeFile(id, data);
          } else {
            FileStore(raw).storeFile(id, data);
          }
        }

        Future<Uint8List?> read(String id) async => asynchronous
            ? await AsyncFileStore(SyncWrappedAsyncKvLogStore(raw)).loadFile(id)
            : FileStore(raw).loadFile(id);

        await write('segment', _bytes(64000));
        expect(raw.sizes, hasLength(1));
        expect(await read('segment'), _bytes(64000));
        raw.sizes.clear();
        await write('segment', _bytes(70000));
        expect(
          raw.sizes,
          hasLength(2),
          reason: 'append/delete-log cannot share a Tx',
        );
        expect(await read('segment'), _bytes(70000));
        raw.sizes.clear();
        await write('boundary', _bytes(61 * 3800));
        expect(raw.sizes, [64]);
        expect(await read('boundary'), _bytes(61 * 3800));
        raw.sizes.clear();
        await write('fallback', _bytes(62 * 3800));
        expect(raw.sizes, hasLength(2));
        expect(await read('fallback'), _bytes(62 * 3800));

        // Exercise native rejection/rollback of a mixed data+metadata batch.
        // The second log record cannot fit one encrypted container chunk.
        final before = raw.count(Ns.fileChunks);
        expect(
          () => raw.commit([
            AppendLogOp(Ns.fileChunks, 10000, _bytes(100)),
            AppendLogOp(Ns.fileChunks, 10001, _bytes(8000)),
            PutOp(Ns.settings, _key('file:invalid'), _key('{}')),
          ]),
          throwsA(isA<hv.HvException>()),
        );
        expect(raw.count(Ns.fileChunks), before);
        expect(raw.readLog(Ns.fileChunks, 10000), isNull);
        expect(raw.get(Ns.settings, _key('file:invalid')), isNull);
        expect(await read('segment'), _bytes(70000));
        raw.close();
        space = hv.HvSpace.open(path: path, password: password);
        raw = _CountingNativeStore(space);
        expect(await read('segment'), _bytes(70000));
        expect(await read('boundary'), _bytes(61 * 3800));
        expect(await read('fallback'), _bytes(62 * 3800));
        expect(raw.count(Ns.fileChunks), before);
        expect(raw.get(Ns.settings, _key('file:invalid')), isNull);
        raw.sizes.clear();
        await write('after-reopen', _bytes(64000));
        expect(raw.sizes, hasLength(1));
        expect(await read('after-reopen'), _bytes(64000));
      },
      skip: (Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false)
          ? false
          : 'set XVEIL_HV_DYLIB to the production hidden-volume library',
    );
  }

  test(
    'native retirement is atomic through rejection, reopen and retry',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'xveil-file-retire-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/fixture.hv';
      final password = _key('fixture-password');
      var raw = _CountingNativeStore(
        hv.HvSpace.create(
          path: path,
          password: password,
          argon: hv.ArgonPreset.light,
        ),
      );
      addTearDown(() => raw.close());
      AsyncFileStore store() => AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      await store().storeFile('header', _bytes(100));
      await store().storeFile('old', _bytes(9000));
      await store().storeFile('next', _bytes(12000));
      raw.rejectHeader = true;
      await expectLater(
        store().storeFile('header', _bytes(200), retireHints: ['old']),
        throwsA(isA<hv.HvException>()),
      );
      raw.close();
      raw = _CountingNativeStore(
        hv.HvSpace.open(path: path, password: password),
      );
      expect(await store().loadFile('header'), _bytes(100));
      expect(await store().loadFile('old'), _bytes(9000));
      expect(await store().loadFile('next'), _bytes(12000));
      expect(raw.get(Ns.settings, _key('invalid')), isNull);
      raw.sizes.clear();
      await store().storeFile('header', _bytes(200), retireHints: ['old']);
      expect(raw.sizes, [2, 8]);
      expect(await store().deleteFileOps('old'), isEmpty);
      raw.close();
      raw = _CountingNativeStore(
        hv.HvSpace.open(path: path, password: password),
      );
      expect(await store().loadFile('header'), _bytes(200));
      expect(await store().loadFile('old'), isNull);
      expect(await store().loadFile('next'), _bytes(12000));
      final accounting =
          jsonDecode(utf8.decode(raw.get(Ns.settings, _key('file_chunk_gc'))!))
              as Map;
      expect(
        accounting['live'],
        raw.count(Ns.fileChunks) + 1,
        reason: 'existing failed-publication retries conservatively count '
            'the reused orphan id twice',
      );
    },
    skip: (Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false)
        ? false
        : 'set XVEIL_HV_DYLIB to the production hidden-volume library',
  );
}
