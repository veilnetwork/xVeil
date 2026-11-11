import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/data_transfer.dart';
import 'package:xveil/state/data_export.dart';
import 'package:xveil/state/data_import.dart';
import 'package:xveil/state/device_sync_appliers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['XVEIL_NATIVE_ARCHIVE_FILES'] == '1';
  final self = List.filled(64, '1').join();
  late Directory dir;
  final stores = <HiddenVolumeStorage>[];

  Future<HiddenVolumeStorage> create(String name) async {
    final path = '${dir.path}/$name.hv';
    HvKvLogStore(hv.HvSpace.create(
      path: path,
      password: Uint8List.fromList(utf8.encode('fixture-password')),
      argon: hv.ArgonPreset.min,
    )).close();
    final storage = HiddenVolumeStorage.async(workerSpaceOpener(path));
    stores.add(storage);
    expect(await storage.open(password: 'fixture-password'), isTrue);
    return storage;
  }

  setUp(() async {
    if (!enabled) return;
    expect(ensureHiddenVolumeLoaded(), isTrue);
    dir = await Directory.systemTemp.createTemp('xveil-archive-files-');
  });
  tearDown(() async {
    if (!enabled) return;
    for (final storage in stores) {
      await storage.close();
    }
    stores.clear();
    await dir.delete(recursive: true);
  });

  DeviceSyncAppliers appliers() => DeviceSyncAppliers()
    ..register((_, {attachmentThumb}) async {});

  test('UUID attachment bytes survive archive import and cold reopen', () async {
    final source = await create('source');
    final target = await create('target');
    const id = 'e1a1bbf7-670f-4d10-83af-596fce28ba38';
    final peer = NodeId.fromHex(List.filled(64, '2').join());
    final bytes = Uint8List.fromList(List.generate(70000, (i) => i % 251));
    await source.upsertContact(Contact(nodeId: peer, status: ContactStatus.accepted));
    await source.appendMessage(Message(
      id: 'fixture-message', conversationId: peer.hex,
      direction: MessageDirection.outgoing, body: 'fixture attachment',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1), fileId: id,
    ));
    await source.storeFile(id, bytes);
    expect((await source.sharedContentReferenceSnapshot()).storedContentIds,
        isNot(contains(id)), reason: 'exercise the real CID-only GC inventory');
    final out = BytesBuilder();
    final report = await DataExporter(storage: source, nodeIdHex: self,
        syncedSettingKeys: {}).run(sink: (b) async => out.add(b));
    expect(report.files, 1);
    expect(report.skippedFiles, isEmpty);
    await DataImporter(storage: target, appliers: appliers(), selfNodeIdHex: self)
        .run(bytes: Stream.value(out.takeBytes()));
    await target.close();
    expect(await target.open(password: 'fixture-password'), isTrue);
    expect(await target.loadFile(id), bytes);
    expect(await source.loadFile(id), bytes);
  }, skip: !enabled);

  test('untrusted file record cannot turn a normal space into a master', () async {
    final target = await create('roster-target');
    final out = BytesBuilder();
    final writer = await DataTransferWriter.open(sink: (b) async => out.add(b),
      header: TransferHeader(createdMs: 1, nodeIdHex: self,
        includesIdentity: false, includesFiles: true, counts: {}, fileBytes: 0));
    await writer.add(TransferRecord(kind: TransferRecordKind.file,
      meta: {'id': 'master:roster.v2'}, payload: Uint8List.fromList(utf8.encode(
        jsonEncode([{'l': 'injected', 'k': base64Encode(Uint8List(64))}])))));
    await writer.close();
    await expectLater(DataImporter(storage: target, appliers: appliers(),
      selfNodeIdHex: self).run(bytes: Stream.value(out.takeBytes())),
      throwsA(isA<ImportInterrupted>()));
    await target.close();
    expect(await target.open(password: 'fixture-password'), isTrue);
    expect(await target.loadRoster(), isNull);
    expect(await target.hasFile('master:roster.v2'), isFalse);
  }, skip: !enabled);
}
