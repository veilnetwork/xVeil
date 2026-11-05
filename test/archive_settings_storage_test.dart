import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/data_transfer.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/state/data_export.dart';
import 'package:xveil/state/data_import.dart';
import 'package:xveil/state/device_settings_sync.dart';
import 'package:xveil/state/device_sync_appliers.dart';

const _password = 'archive-settings-fixture';
final _owner = '01' * 32;
Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

class _Fixture {
  _Fixture(this.store, this.raw, this.open);
  HiddenVolumeStorage store;
  final AsyncKvLogStore raw;
  final AsyncSpaceOpener open;

  Future<void> reopen() async {
    await store.close();
    store = HiddenVolumeStorage.async(open);
    expect(await store.open(password: _password), true);
  }
}

Future<_Fixture> _fixture(bool native) async {
  late AsyncSpaceOpener open;
  Directory? dir;
  if (native) {
    expect(
      ensureHiddenVolumeLoaded(
        dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
      ),
      true,
    );
    dir = await Directory.systemTemp.createTemp('xveil-archive-settings-');
    final path = '${dir.path}/store.hv';
    HvKvLogStore(
      hv.HvSpace.create(
        path: path,
        password: _bytes(_password),
        argon: hv.ArgonPreset.min,
      ),
    ).close();
    open = workerSpaceOpener(path);
  } else {
    final raw = FakeKvLogStore();
    open = ({required password, required bool create}) async =>
        SyncWrappedAsyncKvLogStore(raw);
  }
  final raw = (await open(password: _bytes(_password), create: false))!;
  final store = HiddenVolumeStorage.async(
    ({required password, required bool create}) async => raw,
  );
  expect(await store.open(password: _password), true);
  final fixture = _Fixture(store, raw, open);
  addTearDown(() async {
    await fixture.store.close();
    await dir?.delete(recursive: true);
  });
  return fixture;
}

Future<_Fixture> _source(bool native) async {
  final fixture = await _fixture(native);
  await fixture.store.putSetting('nickname:claimed', 'public-claim-fixture');
  await fixture.store.putSetting('locale', 'ru');
  await fixture.store.putSetting('window_width', '900');
  await fixture.store.putSetting('node.master_key.v1', 'PRIVATE_KEY_CANARY');
  await fixture.store.putSetting('ratchet.local_instance.v1', 'RATCHET_CANARY');
  // Remove exactly the storage prefix; a logical key starting with set: is
  // different from the ordinary nickname key and is not transferable.
  await fixture.store.putSetting(
    'set:nickname:claimed',
    'DOUBLE_PREFIX_CANARY',
  );
  await fixture.raw.commit([
    PutOp(Ns.settings, _bytes('file:nickname:claimed'), _bytes('FILE_CANARY')),
    PutOp(Ns.settings, _bytes('conv_seq:fixture'), _bytes('CURSOR_CANARY')),
  ]);
  return fixture;
}

void main() {
  for (final native in [false, true]) {
    final skip =
        native && (Platform.environment['XVEIL_HV_DYLIB'] ?? '').isEmpty
        ? 'set XVEIL_HV_DYLIB to the qualified native library'
        : false;
    test(
      'archive preview counts actual transferable settings native=$native',
      () async {
        final source = await _source(native);
        final plan = await DataExporter(
          storage: source.store,
          nodeIdHex: _owner,
          syncedSettingKeys: {'locale'},
        ).plan();
        expect(plan.settings, 2);
      },
      skip: skip,
    );

    test(
      'settings survive export and cold import without raw storage keys native=$native',
      () async {
        final source = await _source(native);
        await source.reopen();
        final output = BytesBuilder();
        await DataExporter(
          storage: source.store,
          nodeIdHex: _owner,
          syncedSettingKeys: {'locale'},
        ).run(sink: (chunk) async => output.add(chunk), includeFiles: false);
        final encoded = output.takeBytes();
        final reader = await DataTransferReader.open(Stream.value(encoded));
        final settings = <String>[], synced = <String>[];
        try {
          await for (final row in reader.records()) {
            if (row.kind == TransferRecordKind.setting) {
              settings.add(row.meta['key'] as String);
            } else if (row.kind == TransferRecordKind.sync) {
              final event = DeviceSyncEvent.fromBody(row.meta['b'] as String)!;
            if (event.kind == DeviceSyncKind.settingSet) {
                synced.add(event.key);
            }
            }
          }
        } finally {
          await reader.close();
        }
        expect(settings, ['nickname:claimed']);
        expect(synced, ['locale']);
        final text = utf8.decode(encoded);
        for (final canary in [
          'PRIVATE_KEY_CANARY',
          'RATCHET_CANARY',
          'DOUBLE_PREFIX_CANARY',
          'FILE_CANARY',
          'CURSOR_CANARY',
          'window_width',
        ]) {
          expect(text, isNot(contains(canary)));
        }

        final target = await _fixture(native);
        final hub = DeviceSettingsSyncHub();
        hub.register(
          'locale',
          (value) => target.store.putSetting('locale', value),
        );
        final appliers = DeviceSyncAppliers()
          ..register(
            (event) async {
              if (event.kind == DeviceSyncKind.settingSet) {
                await hub.applyIncoming(
                  event.key,
                  event.payload['v'] as String,
                );
              }
            },
            settle: () async {},
            failures: () => 0,
          );
        final importer = DataImporter(
          storage: target.store,
          appliers: appliers,
          selfNodeIdHex: _owner,
        );
        final report = await importer.run(bytes: Stream.value(encoded));
        expect(report.settingsFilled, 1);
        expect(report.failedApplies, 0);
        await target.reopen();
        expect(
          await target.store.getSetting('nickname:claimed'),
          'public-claim-fixture',
        );
        expect(await target.store.getSetting('locale'), 'ru');
        for (final key in [
          'window_width',
          'node.master_key.v1',
          'ratchet.local_instance.v1',
          'set:nickname:claimed',
        ]) {
          expect(await target.store.getSetting(key), isNull);
        }
        await target.store.putSetting(
          'nickname:claimed',
          'current-claim-fixture',
        );
        final repeated = await DataImporter(
          storage: target.store,
          appliers: appliers,
          selfNodeIdHex: _owner,
        ).run(bytes: Stream.value(encoded));
        expect(repeated.settingsKept, 1);
        expect(
          await target.store.getSetting('nickname:claimed'),
          'current-claim-fixture',
        );
      },
      skip: skip,
    );
  }
}
