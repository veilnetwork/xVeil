import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

import '../support/timed_native_store.dart';

class _Counted extends TimedNativeStore {
  _Counted(AsyncKvLogStore inner) : super(inner, Stopwatch()..start(), (_) {});
  int groups = 0, batches = 0;
  @override
  Future<List<Uint8List>?> readLogGroups(int ns, List<LogReadGroup> request) {
    groups++;
    return super.readLogGroups(ns, request);
  }

  @override
  Future<List<Uint8List>?> readLogBatch(int ns, List<int> ids) {
    batches++;
    return super.readLogBatch(ns, ids);
  }
}

// Same worker and bytes; only the optional grouped-read capability is masked.
class _Ungrouped
    implements AsyncKvLogStore, AsyncLogBatchReader, AsyncKvBatchReader {
  _Ungrouped(this.inner);
  final _Counted inner;
  @override
  Future<Uint8List?> get(int ns, Uint8List key) => inner.get(ns, key);
  @override
  Future<List<Uint8List?>> getBatch(int ns, List<Uint8List> keys) =>
      inner.getBatch(ns, keys);
  @override
  Future<Uint8List?> readLog(int ns, int id) => inner.readLog(ns, id);
  @override
  Future<List<Uint8List>?> readLogBatch(int ns, List<int> ids) =>
      inner.readLogBatch(ns, ids);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test(
    'real worker groups fresh file payloads and refuses missing or oversized records',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final dir = await Directory.systemTemp.createTemp('xv-grouped-reads-');
      addTearDown(() => dir.delete(recursive: true));
      final password = Uint8List.fromList(utf8.encode('synthetic-file-groups'));
      final path = '${dir.path}/fixture.hv';
      final space = hv.HvSpace.create(
        path: path,
        password: password,
        argon: hv.ArgonPreset.light,
      );
      HvKvLogStore(space).close();
      final store = _Counted(
        (await workerSpaceOpener(path)(password: password, create: false))!,
      );
      addTearDown(store.close);
      final files = AsyncFileStore(store);
      final expected = [
        for (var file = 0; file < 3; file++)
          Uint8List.fromList(List.generate(60000, (i) => (i + file) % 251)),
      ];
      for (var i = 0; i < 3; i++) {
        await files.storeFile('f$i', expected[i]);
      }
      store.groups = store.batches = 0;
      for (var i = 0; i < 10; i++) {
        expect(
          await files.loadFiles(['f0', 'f1', 'f2'], maxBytesPerFile: 65536),
          expected,
        );
      }
      expect(
        store.groups,
        10,
        reason: 'each 48-record cohort crosses the isolate once',
      );
      expect(store.batches, 0);
      final samples = <Map<String, int>>[];
      for (final reader in [
        AsyncFileStore(_Ungrouped(store)),
        files,
        AsyncFileStore(_Ungrouped(store)),
      ]) {
        store.groups = store.batches = 0;
        var us = 0;
        for (var i = 0; i < 50; i++) {
          final clock = Stopwatch()..start();
          final actual = await reader.loadFiles([
            'f0',
            'f1',
            'f2',
          ], maxBytesPerFile: 65536);
          us += clock.elapsedMicroseconds;
          expect(actual, expected);
        }
        samples.add({
          'reads': 50,
          'us': us,
          'group_rpcs': store.groups,
          'plain_rpcs': store.batches,
        });
      }
      expect(samples.map((s) => s['plain_rpcs']), [150, 0, 150]);
      expect(samples.map((s) => s['group_rpcs']), [0, 50, 0]);
      final evidence = Platform.environment['FILE_GROUP_READ_EVIDENCE'];
      if (evidence != null) {
        await File(evidence).writeAsString(
          jsonEncode({
            'schema': 'xveil-test-file-groups/1',
            'samples': samples,
          }),
        );
      }
      expected[1] = Uint8List.fromList([9, 8, 7]);
      await files.storeFile('f1', expected[1]);
      expect(
        await files.loadFiles(['f0', 'f1', 'f2'], maxBytesPerFile: 65536),
        expected,
      );
      final metadata =
          jsonDecode(
                utf8.decode(
                  (await store.get(
                    Ns.settings,
                    Uint8List.fromList(utf8.encode('file:f1')),
                  ))!,
                ),
              )
              as Map;
      final id = metadata['segments'] is List
          ? (metadata['segments'] as List).first[0] as int
          : metadata['base'] as int;
      expect(
        await store.readLogGroups(Ns.fileChunks, [
          (ids: [id], maxBytes: 2),
        ]),
        isNull,
      );
      await store.commit([DeleteLogOp(Ns.fileChunks, id)]);
      expect(
        await files.loadFiles(['f0', 'f1', 'f2'], maxBytesPerFile: 65536),
        isNull,
      );
      expect(
        await files.loadFile('f2'),
        expected[2],
        reason: 'a refusal never poisons a later independent read',
      );
    },
    skip: (Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false)
        ? false
        : 'set XVEIL_HV_DYLIB',
  );
}
