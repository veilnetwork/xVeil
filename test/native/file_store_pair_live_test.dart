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
    'paired journal files reduce real worker commits and survive reopen',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final dir = await Directory.systemTemp.createTemp('xv-file-pair-native-');
      final opener = workerSpaceOpener('${dir.path}/fixture.hv');
      final password = Uint8List.fromList(utf8.encode('pair-fixture'));
      final inner = (await opener(password: password, create: true))!;
      var recording = false;
      final counters = <String, int>{};
      final store = TimedNativeStore(inner, Stopwatch()..start(), (event) {
        if (!recording) return;
        final op = event['operation'] as String;
        counters.update(op, (n) => n + 1, ifAbsent: () => 1);
      });
      final storage = HiddenVolumeStorage.fromAsyncStore(store);
      final samples = <Map<String, Object?>>[];
      var previous = 'seed-tail';
      var seed = 0;
      await storage.storeFile(previous, _data(64000, seed));
      await storage.storeFile('header', _data(6000, seed));
      Uint8List? lastTail, lastHeader;
      try {
        for (final phase in ['A1', 'B', 'A2']) {
          counters.clear();
          var elapsed = 0;
          const repeats = 5;
          for (var i = 0; i < repeats; i++) {
            seed++;
            final tail = StoredFileWrite('tail-$seed', _data(64000, seed));
            final header = StoredFileWrite('header', _data(6000, seed));
            recording = true;
            final clock = Stopwatch()..start();
            if (phase == 'B') {
              expect(
                await storage.tryStoreFilePair(
                  tail,
                  header,
                  retireHints: [previous],
                ),
                isTrue,
              );
            } else {
              await storage.storeFile(tail.id, tail.bytes);
              await storage.storeFile(
                header.id,
                header.bytes,
                retireHints: [previous],
              );
            }
            clock.stop();
            elapsed += clock.elapsedMicroseconds;
            recording = false;
            expect(await storage.loadFile(tail.id), tail.bytes);
            expect(await storage.loadFile(header.id), header.bytes);
            expect(await storage.loadFile(previous), isNull);
            previous = tail.id;
            lastTail = tail.bytes;
            lastHeader = header.bytes;
          }
          expect(counters['kv.commit'], phase == 'B' ? 10 : 15);
          samples.add({
            'phase': phase,
            'repeats': repeats,
            'rpc_counts': Map.of(counters),
            'us': elapsed,
          });
        }
        await storage.close();
        final reopened = HiddenVolumeStorage.fromAsyncStore(
          (await opener(password: password, create: false))!,
        );
        try {
          expect(await reopened.loadFile(previous), lastTail);
          expect(await reopened.loadFile('header'), lastHeader);
        } finally {
          await reopened.close();
        }
        final evidence = Platform.environment['GROUP_PAIR_EVIDENCE'];
        if (evidence != null) {
          await File(evidence).writeAsString(
            jsonEncode({
              'samples': samples,
              'real_worker': true,
              'reopened': true,
            }),
          );
        }
      } finally {
        recording = false;
        await storage.close();
        await dir.delete(recursive: true);
      }
    },
    skip: Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty == true
        ? false
        : 'set verified hidden-volume native library',
  );
}
