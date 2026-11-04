@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import '../support/outbox_replacement_cases.dart';
import '../support/queued_snapshot_probe.dart';
import 'package:xveil/data/storage/storage.dart';

void main() {
  final native = Platform.environment['XVEIL_HV_DYLIB'];
  final paths = <HiddenVolumeStorage, String>{};
  Future<HiddenVolumeStorage> open(ReplacementFaults faults) async {
    expect(ensureHiddenVolumeLoaded(dylibPath: native), isTrue);
    final dir = await Directory.systemTemp.createTemp(
      'xveil-outbox-replacement-native-',
    );
    final path = '${dir.path}/store.hv';
    HvKvLogStore(
      hv.HvSpace.create(
        path: path,
        password: Uint8List.fromList(utf8.encode('fixture')),
        argon: hv.ArgonPreset.light,
      ),
    ).close();
    final storage = HiddenVolumeStorage.async(
      ({required password, required create}) async => ReplacementStore(
        (await workerSpaceOpener(path)(password: password, create: false))!,
        faults,
      ),
    );
    addTearDown(() async {
      await storage.close();
      await dir.delete(recursive: true);
    });
    paths[storage] = path;
    expect(await storage.open(password: 'fixture'), isTrue);
    return storage;
  }

  final skip = native == null
      ? 'set XVEIL_HV_DYLIB to a qualified native library'
      : false;
  group(
    'native replacement contract',
    () => outboxReplacementCases(open: open, skip: skip),
  );
  test(
    'raw-root probe sees orphan payloads before cleanup and none after',
    () async {
      final storage = await open(ReplacementFaults());
      final old = <OutboxFrame>[];
      for (var i = 0; i < 20; i++) {
        final row = OutboxFrame(
          frameId: 'large-old-$i',
          peerHex: 'peer',
          wire: Uint8List.fromList(
            List.generate(70000, (j) => (j * 17 + i) % 251),
          ),
        );
        old.add(row);
        await storage.enqueueOutboxFrame(row.frameId, row.peerHex, row.wire);
      }
      final fresh = [
        OutboxFrame(
          frameId: 'safe',
          peerHex: 'peer',
          wire: Uint8List.fromList([1]),
        ),
      ];
      expect(await storage.replaceOutboxFrames(old, fresh), isTrue);
      await storage.close();
      Future<Map<String, int>> inspect() async {
        final raw = (await workerSpaceOpener(paths[storage]!)(
          password: Uint8List.fromList(utf8.encode('fixture')),
          create: false,
        ))!;
        try {
          return await stoppedOutboxStats(
            raw,
            'ab' * 32,
            {},
            keepKey: 'unused',
          );
        } finally {
          await raw.close();
        }
      }

      final dirty = await inspect();
      expect(dirty['orphanPayloadRows'], greaterThan(1024));
      expect(dirty['cleanupPending'], 1);
      expect(await storage.open(password: 'fixture'), isTrue);
      await storage.finishOutboxCleanup();
      await storage.close();
      final clean = await inspect();
      expect(clean['orphanPayloadRows'], 0);
      expect(clean['cleanupPending'], 0);
    },
    skip: skip,
  );
}
