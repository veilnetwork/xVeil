import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/folder_scan.dart';
import 'package:xveil/data/storage/folder_sync_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/folder_sync.dart';
import 'package:xveil/state/folder_sync_engine.dart';

import 'support/fake_hv_container.dart';

class _FakeCloud implements FolderSyncCloud {
  final Map<String, RemoteFile> files = {};
  final Map<String, Uint8List> content = {};
  final List<String> calls = [];
  Object? failNextUpload;

  @override
  Future<List<RemoteFile>> list(String? folderId) async => files.values.toList();

  @override
  Future<RemoteFile> upload({
    required String path,
    required String? folderId,
    required String? existingItemId,
    required Uint8List bytes,
  }) async {
    calls.add('upload:$path:${existingItemId ?? "new"}');
    final failure = failNextUpload;
    if (failure != null) {
      failNextUpload = null;
      throw failure;
    }
    final id = existingItemId ?? 'item-$path';
    final stored = RemoteFile(
      path: path,
      itemId: id,
      contentId: 'cid-${utf8.decode(bytes)}',
      size: bytes.length,
      modifiedAtMs: 1,
    );
    files[path] = stored;
    content[id] = bytes;
    return stored;
  }

  @override
  Future<Uint8List?> download(String itemId) async {
    calls.add('download:$itemId');
    return content[itemId];
  }

  @override
  Future<void> delete(String itemId) async {
    calls.add('delete:$itemId');
    files.removeWhere((_, f) => f.itemId == itemId);
    content.remove(itemId);
  }

  @override
  Future<void> rename(String itemId, String path) async {
    calls.add('rename:$itemId:$path');
    final old = files.entries.firstWhere((e) => e.value.itemId == itemId);
    files.remove(old.key);
    files[path] = RemoteFile(
      path: path,
      itemId: itemId,
      contentId: old.value.contentId,
      size: old.value.size,
      modifiedAtMs: old.value.modifiedAtMs,
    );
  }

  void seed(String path, String body) {
    final id = 'item-$path';
    files[path] = RemoteFile(
      path: path,
      itemId: id,
      contentId: 'cid-$body',
      size: body.length,
      modifiedAtMs: 1,
    );
    content[id] = Uint8List.fromList(utf8.encode(body));
  }
}

class _FakeDisk implements FolderSyncDisk {
  final Map<String, String> files = {};
  final List<String> calls = [];
  bool truncated = false;
  List<String> unreadable = const [];

  @override
  Future<FolderScan> scan(String root) async => FolderScan(
    files: [
      for (final entry in files.entries)
        LocalFile(
          path: entry.key,
          size: entry.value.length,
          modifiedAtMs: 100 + entry.value.length,
        ),
    ],
    unreadable: unreadable,
    truncated: truncated,
  );

  @override
  Future<Uint8List?> read(String root, String path) async {
    final body = files[path];
    return body == null ? null : Uint8List.fromList(utf8.encode(body));
  }

  @override
  Future<void> write(String root, String path, Uint8List bytes) async {
    calls.add('write:$path');
    files[path] = utf8.decode(bytes);
  }

  @override
  Future<void> remove(String root, String path) async {
    calls.add('remove:$path');
    files.remove(path);
  }

  @override
  Future<LocalFile?> stat(String root, String path) async {
    final body = files[path];
    return body == null
        ? null
        : LocalFile(
            path: path,
            size: body.length,
            modifiedAtMs: 100 + body.length,
          );
  }
}

void main() {
  late HiddenVolumeStorage storage;
  late FolderSyncStore store;
  late _FakeCloud cloud;
  late _FakeDisk disk;
  late FolderSyncEngine engine;
  const pair = FolderSyncPair(id: 'p1', localPath: '/local');

  setUp(() async {
    storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    store = FolderSyncStore(storage);
    cloud = _FakeCloud();
    disk = _FakeDisk();
    engine = FolderSyncEngine(cloud, disk, store, () => 7);
  });
  tearDown(() => storage.close());

  test('a first pass moves files both ways and records what it did', () async {
    disk.files['mine.txt'] = 'local';
    cloud.seed('theirs.txt', 'remote');

    final report = await engine.runOnce(pair);

    expect(report.isRefused, isFalse);
    expect(cloud.files.keys, containsAll(['mine.txt', 'theirs.txt']));
    expect(disk.files.keys, containsAll(['mine.txt', 'theirs.txt']));
    final base = (await store.state('p1')).base.map((f) => f.path).toSet();
    expect(base, {'mine.txt', 'theirs.txt'});
  });

  test('a second pass with nothing changed does nothing at all', () async {
    disk.files['a.txt'] = 'x';
    await engine.runOnce(pair);
    cloud.calls.clear();
    disk.calls.clear();

    final report = await engine.runOnce(pair);

    expect(report.applied, isEmpty);
    expect(cloud.calls, isEmpty);
    expect(disk.calls, isEmpty);
  });

  test('an edit replaces the SAME cloud item, it does not mint a new one', () async {
    disk.files['a.txt'] = 'one';
    await engine.runOnce(pair);
    final originalId = cloud.files['a.txt']!.itemId;
    cloud.calls.clear();

    disk.files['a.txt'] = 'two-longer';
    await engine.runOnce(pair);

    expect(cloud.calls, ['upload:a.txt:$originalId']);
    expect(
      cloud.files['a.txt']!.itemId,
      originalId,
      reason: 'a fresh item per edit would break claims, history and shares',
    );
  });

  test('a conflict is recorded and applied to NEITHER side', () async {
    disk.files['a.txt'] = 'same';
    await engine.runOnce(pair);
    // Both sides move, differently.
    disk.files['a.txt'] = 'local-edit';
    cloud.seed('a.txt', 'remote-edit');
    cloud.calls.clear();
    disk.calls.clear();

    final report = await engine.runOnce(pair);

    expect(report.conflicts, {'a.txt'});
    expect(cloud.calls, isEmpty, reason: 'the cloud copy must not be replaced');
    expect(disk.calls, isEmpty, reason: 'the local copy must not be replaced');
    expect(disk.files['a.txt'], 'local-edit');
    expect((await store.state('p1')).pendingConflicts, {'a.txt'});
  });

  test('a pending conflict does not stop its neighbours, and clears when '
      'answered', () async {
    disk.files['a.txt'] = 'same';
    await engine.runOnce(pair);
    disk.files['a.txt'] = 'local-edit';
    cloud.seed('a.txt', 'remote-edit');
    await engine.runOnce(pair);

    disk.files['b.txt'] = 'new';
    final second = await engine.runOnce(pair);
    expect(
      second.applied.map((a) => a.path),
      ['b.txt'],
      reason: 'one undecided file must not freeze the folder',
    );

    await engine.resolveConflict('p1', 'a.txt');
    expect((await store.state('p1')).pendingConflicts, isEmpty);
  });

  test('a local delete removes the cloud copy', () async {
    for (var i = 0; i < 6; i++) {
      disk.files['f$i.txt'] = 'body$i';
    }
    await engine.runOnce(pair);
    disk.files.remove('f0.txt');
    cloud.calls.clear();

    await engine.runOnce(pair);

    expect(cloud.calls, ['delete:item-f0.txt']);
    expect(cloud.files.containsKey('f0.txt'), isFalse);
  });

  test('a truncated scan can never delete anything', () async {
    // A truncated scan looks exactly like mass deletion. The engine has the
    // information to tell them apart; the differ does not, so the decision is
    // taken before it is asked.
    for (var i = 0; i < 6; i++) {
      disk.files['f$i.txt'] = 'body$i';
    }
    await engine.runOnce(pair);
    disk.files.remove('f0.txt');
    disk.truncated = true;
    cloud.calls.clear();

    await engine.runOnce(pair);

    expect(cloud.calls.where((c) => c.startsWith('delete')), isEmpty);
    expect(cloud.files.containsKey('f0.txt'), isTrue);
  });

  test('an unreadable directory can never delete anything either', () async {
    for (var i = 0; i < 6; i++) {
      disk.files['f$i.txt'] = 'body$i';
    }
    await engine.runOnce(pair);
    disk.files.remove('f0.txt');
    disk.unreadable = const ['some/dir'];
    cloud.calls.clear();

    await engine.runOnce(pair);

    expect(cloud.calls.where((c) => c.startsWith('delete')), isEmpty);
  });

  test('the mass-deletion brake stops the pass and says why', () async {
    for (var i = 0; i < 6; i++) {
      disk.files['f$i.txt'] = 'body$i';
    }
    await engine.runOnce(pair);
    disk.files.clear();
    cloud.calls.clear();

    final report = await engine.runOnce(pair);

    expect(report.isRefused, isTrue);
    expect(report.refusedReason, contains('6 of 6'));
    expect(cloud.calls, isEmpty);
    final state = await store.state('p1');
    expect(state.base, hasLength(6), reason: 'the base must survive a refusal');
    expect(state.lastRefusal, isNotNull);
  });

  test('one failing file does not fail the pass, and is not recorded as '
      'synced', () async {
    disk.files['good.txt'] = 'g';
    disk.files['bad.txt'] = 'b';
    cloud.failNextUpload = StateError('transport down');

    final report = await engine.runOnce(pair);

    expect(report.failed, hasLength(1));
    expect(report.applied, hasLength(1));
    final base = (await store.state('p1')).base.map((f) => f.path).toSet();
    expect(
      base,
      hasLength(1),
      reason: 'a failed upload recorded as synced would read as a cloud '
          'deletion on the next pass',
    );
  });
}
