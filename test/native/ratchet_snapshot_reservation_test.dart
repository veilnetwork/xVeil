import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/node/ratchet_ffi.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';

Uint8List _bytes(int length, int tag) => Uint8List(length)..[0] = tag;
String _marks(int next) =>
    encodeRatchetReservations([RatchetSendPosition(_bytes(32, 7), next)]);

class _Store extends HvKvLogStore {
  _Store(super.space);
  bool reject = false, loseReply = false;
  final sizes = <int>[];
  @override
  int commit(List<KvLogOp> ops) {
    sizes.add(ops.length);
    if (reject) {
      // Reject in the real container AFTER staging snapshot, tail deletions
      // and marks. A Dart-side precheck would not prove native atomicity.
      return super.commit([
        ...ops,
        PutOp(Ns.settings, _bytes(7, 99), _bytes(8000, 9)),
      ]);
    }
    final sequence = super.commit(ops);
    if (loseReply) throw StateError('lost commit reply');
    return sequence;
  }
}

void main() {
  final skip = (Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false)
      ? false
      : 'set XVEIL_HV_DYLIB to the production hidden-volume library';
  for (final uncertain in [false, true]) {
    test(
      'native paired state survives rejection or lost reply ($uncertain)',
      () async {
        final dir = Directory.systemTemp.createTempSync(
          'xveil-paired-ratchet-',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = '${dir.path}/fixture.hv';
        final password = Uint8List.fromList(utf8.encode('fixture-password'));
        var raw = _Store(
          hv.HvSpace.create(
            path: path,
            password: password,
            argon: hv.ArgonPreset.light,
          ),
        );
        var storage = HiddenVolumeStorage.fromStore(raw);
        addTearDown(() => storage.close());
        final key = _bytes(kRatchetKeyLen, 1);
        await storage.saveRatchetStates([
          RatchetStateEntry(key, _bytes(60000, 1), sendReservation: _marks(32)),
        ]);
        expect(raw.sizes, hasLength(1));
        raw.reject = !uncertain;
        raw.loseReply = uncertain;
        await expectLater(
          storage.saveRatchetStates([
            RatchetStateEntry(key, _bytes(100, 2), sendReservation: _marks(64)),
          ]),
          throwsA(uncertain ? isA<StateError>() : isA<hv.HvException>()),
        );
        await storage.close();
        raw = _Store(hv.HvSpace.open(path: path, password: password));
        storage = HiddenVolumeStorage.fromStore(raw);
        expect(
          await storage.loadRatchetState(key),
          _bytes(uncertain ? 100 : 60000, uncertain ? 2 : 1),
        );
        expect(
          await storage.getSetting(ratchetReservationKey(key)),
          _marks(uncertain ? 64 : 32),
        );
        await storage.saveRatchetStates([
          RatchetStateEntry(key, _bytes(100, 2), sendReservation: _marks(64)),
        ]);
        expect(raw.sizes, hasLength(1));
        expect(await storage.loadRatchetState(key), _bytes(100, 2));
        expect(
          await storage.getSetting(ratchetReservationKey(key)),
          _marks(64),
        );
        expect(
          raw.kvKeys(Ns.ratchet).where((k) => k.length == kRatchetKeyLen + 2),
          hasLength(1),
        );
      },
      skip: skip,
    );
  }
  test(
    'native paired entry reaches the full bounded operation budget',
    () async {
      final dir = Directory.systemTemp.createTempSync('xveil-paired-budget-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final raw = _Store(
        hv.HvSpace.create(
          path: '${dir.path}/fixture.hv',
          password: Uint8List.fromList(utf8.encode('fixture-password')),
          argon: hv.ArgonPreset.light,
        ),
      );
      final storage = HiddenVolumeStorage.fromStore(raw);
      addTearDown(storage.close);
      final key = _bytes(kRatchetKeyLen, 1);
      // 126 data chunks + reservation + cleanup-budget marker = 128 ops.
      final blob = _bytes(126 * 1024 - 4, 5);
      await storage.saveRatchetStates([
        RatchetStateEntry(key, blob, sendReservation: _marks(32)),
      ]);
      expect(raw.sizes, [128]);
      expect(await storage.loadRatchetState(key), blob);
      expect(await storage.getSetting(ratchetReservationKey(key)), _marks(32));
    },
    skip: skip,
  );
}
