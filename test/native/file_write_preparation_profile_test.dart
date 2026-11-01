import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_native.dart';

import '../support/timed_native_store.dart';

Uint8List _data(int length, int seed) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 19 + seed) % 251));

void main() {
  test(
    'fresh file-write metadata uses real worker and survives reopen',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final dir = await Directory.systemTemp.createTemp(
        'xveil-write-metadata-',
      );
      final opener = workerSpaceOpener('${dir.path}/fixture.hv');
      final password = Uint8List.fromList(utf8.encode('metadata-fixture'));
      final inner = (await opener(password: password, create: true))!;
      var recording = false;
      final counts = <String, int>{};
      final store = TimedNativeStore(inner, Stopwatch()..start(), (event) {
        if (!recording) return;
        final op = event['operation'] as String;
        counts.update(op, (n) => n + 1, ifAbsent: () => 1);
      });
      final storage = HiddenVolumeStorage.fromAsyncStore(store);
      var previous = 'seed';
      await storage.storeFile(previous, _data(64000, 0));
      await storage.storeFile('header', _data(6000, 0));
      final result = <String, Object?>{'schema': 'xveil-file-write-metadata/1'};
      try {
        var watch = Stopwatch()..start();
        recording = true;
        for (var i = 1; i <= 32; i++) {
          final tail = StoredFileWrite('tail-$i', _data(64000, i));
          final header = StoredFileWrite('header', _data(6000, i));
          expect(
            await storage.tryStoreFilePair(
              tail,
              header,
              retireHints: [previous],
            ),
            isTrue,
          );
          previous = tail.id;
        }
        watch.stop();
        recording = false;
        result['pair'] = {
          'writes': 32,
          'us': watch.elapsedMicroseconds,
          'rpc': Map.of(counts),
        };
        counts.clear();
        watch = Stopwatch()..start();
        recording = true;
        for (var i = 0; i < 8; i++) {
          await storage.storeFile('ordinary-$i', _data(6000, i));
        }
        watch.stop();
        recording = false;
        result['ordinary'] = {
          'writes': 8,
          'us': watch.elapsedMicroseconds,
          'rpc': Map.of(counts),
        };
        counts.clear();
        watch = Stopwatch()..start();
        recording = true;
        for (var i = 0; i < 8; i++) {
          await storage.storeFilePiece(
            'streamed',
            i,
            8,
            1024,
            8192,
            _data(1024, i),
          );
        }
        watch.stop();
        recording = false;
        result['pieces'] = {
          'writes': 8,
          'us': watch.elapsedMicroseconds,
          'rpc': Map.of(counts),
        };
        await storage.close();
        final reopened = HiddenVolumeStorage.fromAsyncStore(
          (await opener(password: password, create: false))!,
        );
        try {
          expect(await reopened.loadFile('header'), _data(6000, 32));
          expect(await reopened.loadFile('tail-32'), _data(64000, 32));
          expect(await reopened.loadFile('seed'), isNull);
          for (var i = 1; i < 32; i++) {
            expect(await reopened.loadFile('tail-$i'), isNull);
          }
          for (var i = 0; i < 8; i++) {
            expect(await reopened.loadFile('ordinary-$i'), _data(6000, i));
          }
          expect(
            await reopened.loadFile('streamed'),
            Uint8List.fromList([for (var i = 0; i < 8; i++) ..._data(1024, i)]),
          );
        } finally {
          await reopened.close();
        }
        result['reopenedBytesAndRetirementMatch'] = true;
        final evidence = Platform.environment['FILE_WRITE_METADATA_EVIDENCE'];
        if (evidence != null) {
          await File(evidence).writeAsString(jsonEncode(result));
        }
      } finally {
        recording = false;
        await storage.close();
        await dir.delete(recursive: true);
      }
    },
    skip: Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty == true
        ? false
        : 'set verified native library',
  );
}
