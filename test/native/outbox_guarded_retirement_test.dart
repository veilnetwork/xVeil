@Timeout(Duration(minutes: 2))
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

void main() {
  final native = Platform.environment['XVEIL_HV_DYLIB'];
  test(
    'guarded retirement survives native reopen without recreating ACKed witness',
    () async {
      expect(ensureHiddenVolumeLoaded(dylibPath: native), isTrue);
      final dir = await Directory.systemTemp.createTemp(
        'xveil-guarded-retire-',
      );
      final path = '${dir.path}/store.hv';
      HvKvLogStore(
        hv.HvSpace.create(
          path: path,
          password: Uint8List.fromList(utf8.encode('fixture')),
          argon: hv.ArgonPreset.light,
        ),
      ).close();
      final storage = HiddenVolumeStorage.async(workerSpaceOpener(path));
      addTearDown(() async {
        await storage.close();
        await dir.delete(recursive: true);
      });
      expect(await storage.open(password: 'fixture'), isTrue);
      for (var i = 0; i < 3; i++) {
        await storage.enqueueOutboxFrame(
          'frame-$i',
          'peer',
          Uint8List.fromList([i]),
        );
      }
      final rows = await storage.pendingOutboxFrames();
      final latest = rows.singleWhere((r) => r.frameId == 'frame-2');
      final old = rows.where((r) => r.frameId != latest.frameId).toList();
      expect(
        await storage.retireOutboxFramesIfCurrent(
          obsolete: old,
          retained: latest,
        ),
        isTrue,
      );
      await storage.close();
      expect(await storage.open(password: 'fixture'), isTrue);
      expect((await storage.pendingOutboxFrames()).map((r) => r.frameId), [
        latest.frameId,
      ]);
      await storage.enqueueOutboxFrame(
        old.first.frameId,
        'peer',
        old.first.wire,
      );
      await storage.ackOutboxFrame(latest.frameId, fromPeerHex: 'peer');
      expect(
        await storage.retireOutboxFramesIfCurrent(
          obsolete: [old.first],
          retained: latest,
        ),
        isFalse,
      );
      await storage.close();
      expect(await storage.open(password: 'fixture'), isTrue);
      expect((await storage.pendingOutboxFrames()).map((r) => r.frameId), [
        old.first.frameId,
      ]);
    },
    skip: native == null
        ? 'set XVEIL_HV_DYLIB to a qualified native library'
        : false,
  );
}
