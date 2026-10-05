import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

void main() {
  test(
    'real encrypted outbox persists incompressible frames across reopen',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'xveil-outbox-native-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = '${directory.path}/store.hv';
      final password = Uint8List.fromList(utf8.encode('fixture-password'));
      final random = Random(317);
      final wire = Uint8List.fromList(
        List.generate(16 * 1024, (_) => random.nextInt(256)),
      );
      var space = hv.HvSpace.create(
        path: path,
        password: password,
        argon: hv.ArgonPreset.light,
      );
      var backing = HvKvLogStore(space);
      // Negative control: the old one-record encoding fails in the real store.
      expect(
        () => backing.commit([
          AppendLogOp(
            Ns.outbox,
            999999,
            Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'id': 'control',
                  'p': 'peer',
                  'w': base64.encode(wire.sublist(0, 4500)),
                }),
              ),
            ),
          ),
        ]),
        throwsA(isA<hv.HvException>()),
      );
      var storage = HiddenVolumeStorage(
        ({required password, required bool create}) => backing,
      );
      await storage.open(password: 'fixture-password', createIfMissing: false);
      await storage.enqueueOutboxFrame('frame', 'peer', wire);
      final rows = backing.count(Ns.outbox);
      expect(rows, greaterThan(2));
      await storage.close();
      space = hv.HvSpace.open(path: path, password: password);
      backing = HvKvLogStore(space);
      storage = HiddenVolumeStorage(
        ({required password, required bool create}) => backing,
      );
      addTearDown(storage.close);
      await storage.open(password: 'fixture-password', createIfMissing: false);
      expect((await storage.pendingOutboxFrames()).single.wire, wire);
      expect(backing.count(Ns.outbox), rows);
      await storage.ackOutboxFrame('frame', fromPeerHex: 'wrong');
      expect(await storage.pendingOutboxFrames(), hasLength(1));
      await storage.ackOutboxFrame('frame', fromPeerHex: 'peer');
      expect(await storage.pendingOutboxFrames(), isEmpty);
      expect(backing.count(Ns.outbox), 0);
    },
    skip: (Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false)
        ? false
        : 'set XVEIL_HV_DYLIB to the current hidden-volume library',
  );
}
