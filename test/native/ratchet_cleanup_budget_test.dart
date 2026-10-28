import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';

class _Store extends HvKvLogStore {
  _Store(super.space);
  int scrubs = 0;
  bool refuseScrub = false;

  @override
  void scrub() {
    if (refuseScrub) throw StateError('fixture vacuum refusal');
    super.scrub();
    scrubs++;
  }
}

void main() {
  final enabled = Platform.environment['XVEIL_HV_DYLIB']?.isNotEmpty ?? false;
  for (final mode in ['password', 'keys', 'async-view']) {
    for (final unfinished in [false, true]) {
      test(
        'native $mode reopen retains ${unfinished ? 'unfinished cleanup' : 'partial budget'}',
        () async {
          final dir = Directory.systemTemp.createTempSync('xveil-key-budget-');
          addTearDown(() => dir.deleteSync(recursive: true));
          final path = '${dir.path}/fixture.hv';
          final password = Uint8List.fromList(utf8.encode('fixture-password'));
          final originalRaw = _Store(
            hv.HvSpace.create(
              path: path,
              password: password,
              argon: hv.ArgonPreset.light,
            ),
          );
          final original = HiddenVolumeStorage.fromStore(originalRaw);
          addTearDown(original.close);
          final keys = originalRaw.exportKeys();
          final conversation = Uint8List(kRatchetKeyLen)..[0] = 1;
          Uint8List blob(int i) => Uint8List(1400)..[0] = i;
          Future<void> save(HiddenVolumeStorage storage, int i) => storage
              .saveRatchetStates([RatchetStateEntry(conversation, blob(i))]);
          final writes = unfinished ? 127 : 64;
          for (var i = 0; i < writes; i++) {
            await save(original, i);
          }
          if (unfinished) {
            originalRaw.refuseScrub = true;
            await expectLater(save(original, 127), throwsStateError);
          }
          await original.close();

          final raw = _Store(
            mode == 'keys'
                ? hv.HvSpace.openWithKeys(path: path, keys: keys)
                : hv.HvSpace.open(path: path, password: password),
          );
          final storage = mode == 'async-view'
              ? HiddenVolumeStorage.fromAsyncStore(
                  SyncWrappedAsyncKvLogStore(raw),
                )
              : HiddenVolumeStorage(
                  ({required password, required create}) => raw,
                  keysOpener: (_) => raw,
                );
          addTearDown(storage.close);
          if (mode == 'password') {
            await storage.open(password: 'fixture-password');
          }
          if (mode == 'keys') await storage.openWithKeys(keys);
          // This also triggers recovery for a hosted, already-open view.
          expect(
            await storage.loadRatchetState(conversation),
            blob(unfinished ? 127 : 63),
          );
          expect(raw.scrubs, unfinished ? 1 : 0);
          if (!unfinished) {
            for (var i = 64; i < 128; i++) {
              await save(storage, i);
            }
          }
          expect(raw.scrubs, 1);
          expect(await storage.loadRatchetState(conversation), blob(127));
          await storage.close();

          final cleanRaw = _Store(
            hv.HvSpace.open(path: path, password: password),
          );
          final clean = HiddenVolumeStorage.fromStore(cleanRaw);
          addTearDown(clean.close);
          expect(await clean.loadRatchetState(conversation), blob(127));
          expect(
            cleanRaw.scrubs,
            0,
            reason: 'completed cleanup must not repeat every boot',
          );
          keys.fillRange(0, keys.length, 0);
        },
        skip: enabled ? false : 'set XVEIL_HV_DYLIB to the production library',
      );
    }
  }
}
