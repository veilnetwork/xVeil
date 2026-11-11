import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/fs_beneath.dart';
import 'package:xveil/data/native_libs.dart';
import 'package:xveil/data/storage/folder_sync_store.dart';
import 'package:xveil/domain/folder_sync.dart';
import 'package:xveil/domain/range_source.dart';
import 'package:xveil/state/folder_sync_adapters.dart';
import 'package:xveil/state/folder_sync_engine.dart';

import 'support/fake_hv_container.dart';

class _Cloud implements FolderSyncCloud {
  final read = Completer<void>();
  final reply = Completer<void>();
  final uploads = <Uint8List>[];
  RemoteFile? current;
  @override
  Future<List<RemoteFile>> list(String? folderId) async => [?current];
  @override
  Future<RemoteFile> upload({required String path, required String? folderId,
      required String? existingItemId, required int size,
      required Future<Uint8List> Function(int, int) readRange}) async {
    final data = BytesBuilder();
    while (data.length < size) {
      final chunk = await readRange(data.length, size - data.length);
      if (chunk.isEmpty) throw StateError('fixture source ended early');
      data.add(chunk);
    }
    uploads.add(data.takeBytes());
    final row = RemoteFile(path: path, itemId: 'fixture-item',
      contentId: base64Encode(uploads.last), size: size, modifiedAtMs: 1);
    current = row;
    if (uploads.length == 1) { read.complete(); await reply.future; }
    return row;
  }
  @override
  Future<RangeSource?> openDownload(String itemId) async =>
      bytesRangeSource(uploads.last);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final replace in [false, true]) {
    test('upload keeps a pre-read version when local edit replaces=$replace', () async {
      final dir = await Directory.systemTemp.createTemp('xveil-upload-version-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/note.txt');
      await file.writeAsString('old bytes', flush: true);
      await file.setLastModified(DateTime.utc(2026, 1, 1));
      if (Platform.environment['XVEIL_REQUIRE_FS_BENEATH'] == '1') {
        expect(loadNativeLib('veilclient_ffi', envVar: 'VEIL_FFI_DYLIB'), isTrue);
        final probe = await veilOpenBeneath(dir.path, 'note.txt');
        expect(probe.supported, isTrue);
        expect(probe.source, isNotNull);
        await probe.source!.close();
      }
      final storage = FakeHvContainer().storage();
      expect(await storage.open(password: 'fixture', createIfMissing: true), isTrue);
      addTearDown(storage.close);
      final cloud = _Cloud();
      final store = FolderSyncStore(storage);
      final engine = FolderSyncEngine(cloud, LocalFolderSyncDisk(), store, () => 1);
      final pair = FolderSyncPair(id: 'fixture-pair', localPath: dir.path);
      final pass = engine.runOnce(pair);
      await cloud.read.future;
      final destination = replace ? File('${dir.path}/replacement') : file;
      await destination.writeAsString('new local bytes', flush: true);
      await destination.setLastModified(DateTime.utc(2026, 2, 1));
      if (replace) await destination.rename(file.path);
      cloud.reply.complete();
      await pass;
      expect(utf8.decode(cloud.uploads.single), 'old bytes');
      final next = await engine.runOnce(pair);
      expect(next.applied.map((a) => a.kind), [SyncActionKind.upload],
        reason: 'the later local version was never uploaded and must remain dirty');
      expect(cloud.uploads.map(utf8.decode), ['old bytes', 'new local bytes']);
      expect(await file.readAsString(), 'new local bytes');
    });
  }
}
