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

class _CountedWorker extends TimedNativeStore {
  _CountedWorker(AsyncKvLogStore store)
    : super(store, Stopwatch()..start(), (_) {});
  int manifests = 0, batches = 0, commits = 0;

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) {
    if (namespace == Ns.settings && utf8.decode(key).startsWith('file:')) {
      manifests++;
    }
    return super.get(namespace, key);
  }

  @override
  Future<List<Uint8List>?> readLogBatch(int namespace, List<int> ids) {
    batches++;
    return super.readLogBatch(namespace, ids);
  }

  @override
  Future<int> commit(List<KvLogOp> ops) {
    commits++;
    return super.commit(ops);
  }
}

void main() {
  test(
    'worker-backed no-op stores read fresh manifests once and verify bytes',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final directory = await Directory.systemTemp.createTemp(
        'xv-file-metadata-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/fixture.hv';
      final password = Uint8List.fromList(
        utf8.encode('native-metadata-fixture'),
      );
      final space = hv.HvSpace.create(
        path: path,
        password: password,
        argon: hv.ArgonPreset.light,
      );
      HvKvLogStore(space).close();
      final inner = (await workerSpaceOpener(path)(
        password: password,
        create: false,
      ))!;
      final store = _CountedWorker(inner);
      addTearDown(store.close);
      const repeats = 100;
      final samples = <Map<String, Object>>[];
      for (final length in [2, 6000, 64000]) {
        final id = 'journal-$length';
        final bytes = Uint8List.fromList(
          List.generate(length, (i) => (i * 31) % 251),
        );
        await AsyncFileStore(store).storeFile(id, bytes);
        store.manifests = store.batches = store.commits = 0;
        final clock = Stopwatch()..start();
        for (var repeat = 0; repeat < repeats; repeat++) {
          // Production creates a facade per call too. No instance cache may
          // explain the reduced read count.
          await AsyncFileStore(store).storeFile(id, bytes);
        }
        samples.add({
          'bytes': length,
          'repeats': repeats,
          'manifest_rpcs': store.manifests,
          'body_batch_rpcs': store.batches,
          'commits': store.commits,
          'us': clock.elapsedMicroseconds,
        });
      }
      store.manifests = store.batches = store.commits = 0;
      await AsyncFileStore(
        store,
      ).storeFile('journal-2', Uint8List.fromList([1, 2, 3]));
      final resize = {
        'manifest_rpcs': store.manifests,
        'body_batch_rpcs': store.batches,
        'commits': store.commits,
      };
      final evidence = Platform.environment['FILE_METADATA_EVIDENCE'];
      if (evidence != null) {
        await File(evidence).writeAsString(
          jsonEncode({
            'samples': samples,
            'worker_backed': true,
            'resize': resize,
          }),
        );
      }
      expect(resize['manifest_rpcs'], 1);
      expect(resize['body_batch_rpcs'], 0);
      expect(resize['commits'], greaterThan(0));
      for (final sample in samples) {
        expect(sample['manifest_rpcs'], repeats);
        expect(
          sample['body_batch_rpcs'],
          repeats,
          reason: 'durable bytes are read on every comparison',
        );
        expect(sample['commits'], 0);
      }
    },
    skip: (Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false)
        ? false
        : 'set XVEIL_HV_DYLIB to the production hidden-volume library',
  );
}
