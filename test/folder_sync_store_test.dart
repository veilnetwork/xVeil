import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/folder_sync_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/folder_sync.dart';

import 'support/fake_hv_container.dart';

void main() {
  late HiddenVolumeStorage storage;
  late FolderSyncStore store;

  setUp(() async {
    storage = FakeHvContainer().storage();
    await storage.open(password: 'pw', createIfMissing: true);
    store = FolderSyncStore(storage);
  });
  tearDown(() => storage.close());

  test('pairs round-trip, including the root-folder mapping', () async {
    await store.savePairs(const [
      FolderSyncPair(id: 'p1', localPath: '/home/a', cloudFolderId: 'f1'),
      FolderSyncPair(id: 'p2', localPath: '/home/b', deletePropagates: false),
    ]);

    final read = await store.pairs();

    expect(read.map((p) => p.id), ['p1', 'p2']);
    expect(read[0].cloudFolderId, 'f1');
    expect(read[1].cloudFolderId, isNull, reason: 'null means the cloud root');
    expect(read[1].deletePropagates, isFalse);
  });

  test('state round-trips base rows and unanswered conflicts', () async {
    await store.saveState(
      'p1',
      const FolderSyncState(
        base: [
          SyncedFile(
            path: 'a.txt',
            contentId: 'cid-a',
            size: 3,
            localModifiedAtMs: 111,
          ),
        ],
        pendingConflicts: {'b.txt'},
        lastPassAtMs: 999,
        lastRefusal: 'folder looked unavailable',
      ),
    );

    final read = await store.state('p1');

    expect(read.base.single.path, 'a.txt');
    expect(read.base.single.contentId, 'cid-a');
    expect(read.base.single.localModifiedAtMs, 111);
    expect(read.pendingConflicts, {'b.txt'});
    expect(read.lastPassAtMs, 999);
    expect(read.lastRefusal, 'folder looked unavailable');
  });

  test('a large base lands in the CHUNKED file store, not in a setting',
      () async {
    // Three times this project has shipped a deferred PayloadTooLarge by
    // putting an unbounded blob in a setting record (~2-3 KiB). The in-memory
    // fake enforces no cap, so asserting "5000 rows round-trip" proves
    // nothing — it passes just as happily on putSetting, which is how the
    // previous three got shipped. The observable that actually distinguishes
    // the two is WHERE the record lives.
    final base = [
      for (var i = 0; i < 5000; i++)
        SyncedFile(
          path: 'folder/sub/file-$i.bin',
          contentId: 'c' * 64,
          size: i,
          localModifiedAtMs: i,
        ),
    ];
    await store.saveState(
      'big',
      FolderSyncState(base: base, pendingConflicts: const {}),
    );

    expect(
      await storage.hasFile('foldersync.state.v1:big'),
      isTrue,
      reason: 'a setting record could not hold ~250 KB on a real container',
    );
    final read = await store.state('big');
    expect(read.base, hasLength(5000));
    expect(read.base.last.path, 'folder/sub/file-4999.bin');
  });

  test('an unknown pair reads as empty, not as an error', () async {
    final read = await store.state('never-seen');
    expect(read.base, isEmpty);
    expect(read.pendingConflicts, isEmpty);
  });

  test('a corrupt record degrades to empty — the SAFE direction', () async {
    // With no base every file reads as new, so the next pass uploads and
    // downloads but can never infer a deletion. Throwing here, or guessing,
    // would be the dangerous alternative.
    await storage.storeFile(
      'foldersync.state.v1:p1',
      Uint8List.fromList(utf8.encode('{not json at all')),
    );
    final read = await store.state('p1');
    expect(read.base, isEmpty);
    expect(read.pendingConflicts, isEmpty);

    await storage.storeFile(
      'foldersync.pairs.v1',
      Uint8List.fromList(utf8.encode('[[[')),
    );
    expect(await store.pairs(), isEmpty);
  });

  test('rows that do not describe a file are dropped, the rest survive',
      () async {
    await storage.storeFile(
      'foldersync.state.v1:p1',
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'base': [
              {'p': 'good.txt', 'c': 'cid', 's': 1, 'm': 2},
              {'p': 'no-size.txt', 'c': 'cid'},
              {'c': 'cid', 's': 1, 'm': 2},
              'not even a map',
            ],
            'conflicts': ['x.txt', 42],
          }),
        ),
      ),
    );

    final read = await store.state('p1');

    expect(read.base.map((f) => f.path), ['good.txt']);
    expect(read.pendingConflicts, {'x.txt'});
  });

  test('forget clears a pair without touching its neighbour', () async {
    const file = SyncedFile(
      path: 'a',
      contentId: 'c',
      size: 1,
      localModifiedAtMs: 1,
    );
    await store.saveState(
      'p1',
      const FolderSyncState(base: [file], pendingConflicts: {}),
    );
    await store.saveState(
      'p2',
      const FolderSyncState(base: [file], pendingConflicts: {}),
    );

    await store.forget('p1');

    expect((await store.state('p1')).base, isEmpty);
    expect((await store.state('p2')).base, hasLength(1));
  });
}
