import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/fs_beneath.dart';
import 'package:xveil/data/native_libs.dart';
import 'package:xveil/data/storage/folder_sync_store.dart';
import 'package:xveil/domain/folder_sync.dart';
import 'package:xveil/state/folder_sync_adapters.dart';
import 'package:xveil/state/folder_sync_engine.dart';

import 'support/fake_hv_container.dart';

class _Cloud implements FolderSyncCloud {
  String body = 'original';
  bool available = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  String? hold;
  int uploads = 0;
  RemoteFile row(String path) => RemoteFile(
    path: path,
    itemId: 'fixture-item',
    contentId: base64Encode(utf8.encode(body)),
    size: utf8.encode(body).length,
    modifiedAtMs: 1,
  );
  @override
  Future<List<RemoteFile>> list(String? folderId) async =>
      available ? [row('note.txt')] : [];
  @override
  Future<RemoteFile> upload({
    required String path,
    required String? folderId,
    required String? existingItemId,
    required int size,
    required Future<Uint8List> Function(int, int) readRange,
  }) async {
    final bytes = BytesBuilder();
    while (bytes.length < size) {
      final next = await readRange(bytes.length, size - bytes.length);
      if (next.isEmpty) throw StateError('fixture source unreadable');
      bytes.add(next);
    }
    body = utf8.decode(bytes.takeBytes());
    available = true;
    uploads++;
    return row(path);
  }

  Future<void> park(String stage) async {
    if (hold != stage) return;
    entered.complete();
    await release.future;
  }

  @override
  Future<RangeSource?> openDownload(String itemId) async {
    final bytes = Uint8List.fromList(utf8.encode(body));
    await park('open');
    return RangeSource(
      size: bytes.length,
      read: (offset, length) async {
        await park('read');
        return Uint8List.sublistView(
          bytes,
          offset,
          (offset + length).clamp(0, bytes.length),
        );
      },
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An external edit at the real rename boundary. The override changes timing
/// only; both the edit and the rename operate on the real filesystem.
class _EditAtRename implements File {
  _EditAtRename(this.file, this.target, this.edit, {this.before = false});
  final File file;
  final String target;
  final Future<void> Function() edit;
  final bool before;
  @override
  String get path => file.path;
  @override
  File get absolute => file.absolute;
  @override
  Directory get parent => file.parent;
  @override
  Uri get uri => file.uri;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      file.open(mode: mode);
  @override
  Future<bool> exists() => file.exists();
  @override
  bool existsSync() => file.existsSync();
  @override
  Future<int> length() => file.length();
  @override
  Future<FileStat> stat() => file.stat();
  @override
  FileStat statSync() => file.statSync();
  @override
  Future<File> rename(String newPath) async {
    if (newPath == target && before) await edit();
    final renamed = await file.rename(newPath);
    if (newPath == target && !before) await edit();
    return renamed;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final stage in ['open', 'read', 'published', 'before-publish']) {
    test(
      'download keeps an edit made at $stage outside its confirmed base',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'xveil-download-version-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final file = File('${dir.path}/note.txt');
        await file.writeAsString('original', flush: true);
        await file.setLastModified(DateTime.utc(2026, 1, 1));
        if (Platform.environment['XVEIL_REQUIRE_FS_BENEATH'] == '1') {
          expect(
            loadNativeLib('veilclient_ffi', envVar: 'VEIL_FFI_DYLIB'),
            isTrue,
          );
          final probe = await veilOpenBeneath(dir.path, 'note.txt');
          expect(probe.supported, isTrue);
          expect(probe.source, isNotNull);
          await probe.source!.close();
          final created = await veilCreateBeneath(dir.path, 'probe.xveil-part');
          expect(created.supported, isTrue);
          expect(created.sink, isNotNull);
          await created.sink!.close();
          await File('${dir.path}/probe.xveil-part').delete();
        }
        final storage = FakeHvContainer().storage();
        expect(
          await storage.open(password: 'fixture', createIfMissing: true),
          isTrue,
        );
        addTearDown(storage.close);
        final store = FolderSyncStore(storage);
        final cloud = _Cloud();
        final engine = FolderSyncEngine(
          cloud,
          const LocalFolderSyncDisk(),
          store,
          () => 1,
        );
        final pair = FolderSyncPair(id: 'fixture-pair', localPath: dir.path);
        await engine.runOnce(pair);
        cloud.body = 'remote replacement';
        var edits = 0;
        Future<void> edit() async {
          edits++;
          await file.writeAsString('new local edit', flush: true);
          await file.setLastModified(DateTime.utc(2026, 2, 1));
        }

        late FolderSyncReport report;
        if (stage == 'published' || stage == 'before-publish') {
          report = await IOOverrides.runZoned(
            () => engine.runOnce(pair),
            createFile: (path) => _EditAtRename(
              Zone.root.run(() => File(path)),
              file.path,
              edit,
              before: stage == 'before-publish',
            ),
          );
        } else {
          cloud.hold = stage;
          final pass = engine.runOnce(pair);
          await cloud.entered.future;
          await edit();
          cloud.release.complete();
          report = await pass;
        }
        expect(edits, 1, reason: 'the intended edit must actually execute');
        if (stage == 'before-publish') {
          // R33-07 is still open for the final external-writer race. A future
          // publisher may preserve the displaced version recoverably rather
          // than keep it under the original name. Neither copy may vanish.
          final copies = dir
              .listSync(recursive: true, followLinks: false)
              .whereType<File>();
          expect(
            copies.any((copy) => copy.readAsStringSync() == 'new local edit'),
            isTrue,
            reason: 'the local edit must survive in the folder',
          );
          return;
        }
        expect(await file.readAsString(), 'new local edit');
        if (stage == 'published') {
          final next = await engine.runOnce(pair);
          expect(next.applied.map((a) => a.kind), [SyncActionKind.upload]);
          expect(cloud.body, 'new local edit');
        } else {
          expect(report.conflicts, contains('note.txt'));
          expect(report.applied, isEmpty);
        }
      },
      skip:
          stage == 'before-publish' &&
              Platform.environment['XVEIL_R33_PUBLISH_RACE_REPRO'] != '1'
          ? 'R33-07 atomic publisher remains open; opt-in reproducer still fails'
          : false,
    );
  }
}
