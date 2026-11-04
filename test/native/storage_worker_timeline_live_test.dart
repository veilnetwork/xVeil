import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

import '../support/stand_storage_timeline.dart';
import '../support/storage_timeline_analysis.dart';
import '../support/timed_native_store.dart';

void main() {
  test(
    'VM trace accounts for every real worker request in FIFO order',
    () async {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final dir = await Directory.systemTemp.createTemp('xv-storage-timeline-');
      addTearDown(() => dir.delete(recursive: true));
      final password = Uint8List.fromList(
        utf8.encode('synthetic-timeline-only'),
      );
      final path = '${dir.path}/test.hv';
      hv.HvSpace.create(
        path: path,
        password: password,
        argon: hv.ArgonPreset.light,
      ).close();
      final raw = (await workerSpaceOpener(path)(
        password: password,
        create: false,
      ))!;
      await raw.commit([
        for (var i = 0; i < 32; i++)
          AppendLogOp(Ns.fileChunks, i, Uint8List.fromList([i])),
      ]);
      final store = TimedNativeStore(
        raw,
        Stopwatch()..start(),
        (_) {},
        traceRpc: true,
      );
      addTearDown(store.close);
      final file = File('${dir.path}/timeline.jsonl');
      final timeline = await StandStorageTimeline.open(file);
      try {
        for (var pass = 0; pass < 4; pass++) {
          await store.commit([
            PutOp(Ns.settings, Uint8List.fromList([1]), Uint8List(1024)),
          ]);
          await Future.wait([
            for (var i = 0; i < 8; i++)
              () async {
                expect(
                  await store.get(Ns.settings, Uint8List.fromList([1])),
                  hasLength(1024),
                );
              }(),
          ]);
          expect(await store.getBatch(Ns.settings, []), isEmpty);
          expect(await store.readLogBatch(Ns.fileChunks, []), isEmpty);
          expect(await store.readLogGroups(Ns.fileChunks, []), isEmpty);
          expect(
            await store.readLogGroups(Ns.fileChunks, [
              (ids: [for (var i = 0; i < 16; i++) i], maxBytes: 16),
              (ids: [for (var i = 16; i < 32; i++) i], maxBytes: 16),
            ]),
            [List.generate(16, (i) => i), List.generate(16, (i) => i + 16)],
          );
          await timeline.capture();
        }
      } finally {
        await timeline.close();
      }
      final records = (await file.readAsLines())
          .map((s) => Map<String, dynamic>.from(jsonDecode(s) as Map))
          .toList();
      final output = Platform.environment['XVEIL_E2E_STORAGE_TIMELINE_RESULT'];
      if (output != null) {
        await File(
          '$output.trace.jsonl',
        ).writeAsString(await file.readAsString());
      }
      final result = analyzeStorageTimeline(records);
      expect(result['rpcCount'], 40);
      expect(result['workerCount'], 40);
      final operations = result['operations'] as Map;
      expect((operations['kv.commit'] as Map)['count'], 4);
      expect((operations['kv.get'] as Map)['count'], 32);
      expect((operations['kv.readLogGroups'] as Map)['count'], 4);
      if (output != null) await File(output).writeAsString(jsonEncode(result));
    },
    skip: Platform.environment['XVEIL_E2E_STORAGE_TIMELINE'] != '1',
  );
}
