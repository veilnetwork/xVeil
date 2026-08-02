import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/folder_scan.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/domain/cloud.dart';
import 'package:xveil/domain/device_sync.dart';
import 'package:xveil/state/cloud_service.dart';
import 'package:xveil/state/folder_sync_adapters.dart';
import 'package:xveil/state/folder_sync_engine.dart';

import 'support/range_source_util.dart';

import 'support/fake_hv_container.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

/// The transport is irrelevant here: these tests exercise the mapping between
/// a folder tree and the cloud index, not delivery.
class _NullSync implements CloudSyncPort {
  final _changes = StreamController<void>.broadcast();
  @override
  NodeId get selfId => _id(1);
  @override
  Stream<void> get changes => _changes.stream;
  @override
  Future<List<DeviceSyncRecord>> records() async => const [];
  @override
  Future<bool> postItem(CloudItem item) async => true;
  @override
  Future<bool> postFolder(CloudFolder folder) async => true;
  @override
  Future<bool> postClaim(CloudReplicaClaim claim) async => true;
  @override
  Future<List<NodeId>> members() async => const [];
  @override
  void vouchForContent(Future<Set<String>> Function() ids) {}
  @override
  Future<bool> fetch(String contentId, NodeId holder) async => false;
  @override
  Future<void> close() => _changes.close();
}

Uint8List _bytes(String body) => Uint8List.fromList(body.codeUnits);

void main() {
  group('the disk adapter', () {
    late Directory root;
    const disk = LocalFolderSyncDisk();

    setUp(() => root = Directory.systemTemp.createTempSync('xveil-disk'));
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('a completed write leaves the file and no debris beside it', () async {
      await writeBytes(disk, root.path, 'nested/a.txt', _bytes('hello'));

      expect(File('${root.path}/nested/a.txt').readAsStringSync(), 'hello');
      expect(
        Directory('${root.path}/nested')
            .listSync()
            .map((e) => e.path.split('/').last),
        ['a.txt'],
      );
    });

    // NOTE ON WHAT IS AND IS NOT PROVEN HERE. The write goes through a sibling
    // and a rename, so a crash cannot leave a truncated file visible under the
    // real name. That property rests on rename(2) being atomic and cannot be
    // asserted from a unit test — verified by breaking it: replacing the
    // temp+rename with a direct write fails NOTHING below. What the two tests
    // do pin is the debris such a crash leaves behind, which is the part that
    // would otherwise be uploaded as if the user had created it.
    test('debris from a crashed write is invisible to the scan', () async {
      await writeBytes(disk, root.path, 'a.txt', _bytes('original'));
      File('${root.path}/a.txt$kPartialSuffix').writeAsStringSync('trunc');

      expect(File('${root.path}/a.txt').readAsStringSync(), 'original');
      final scan = await disk.scan(root.path);
      expect(scan.files.map((f) => f.path), ['a.txt']);
    });

    test('debris does not defeat the next write of the same file', () async {
      // Scratch names are randomised now (audit XV-13), so a leftover no
      // longer collides with the next attempt — which means it no longer gets
      // reused and cleaned up either. The write sweeps its own leftovers for
      // the target instead, or the directory would slowly fill with files the
      // scanner deliberately ignores.
      File('${root.path}/a.txt.deadbeef$kPartialSuffix')
          .writeAsStringSync('stale');

      await writeBytes(disk, root.path, 'a.txt', _bytes('fresh'));

      expect(File('${root.path}/a.txt').readAsStringSync(), 'fresh');
      expect(
        root.listSync().where((e) => e.path.endsWith(kPartialSuffix)),
        isEmpty,
        reason: 'stale scratch files must not accumulate',
      );
    });

    test('a user file that merely looks like scratch is left alone', () async {
      // The sweep is scoped to `<target>.<hex>.xveil-part`. A real file the
      // user happens to have must survive, or the fix would be deleting data.
      final bystander = File('${root.path}/b.txt.deadbeef$kPartialSuffix')
        ..writeAsStringSync('mine');

      await writeBytes(disk, root.path, 'a.txt', _bytes('fresh'));

      expect(bystander.existsSync(), isTrue);
      expect(bystander.readAsStringSync(), 'mine');
    });

    test('removing the last file prunes its folders but never the root',
        () async {
      await writeBytes(disk, root.path, 'a/b/c.txt', _bytes('x'));

      await disk.remove(root.path, 'a/b/c.txt');

      expect(Directory('${root.path}/a').existsSync(), isFalse);
      expect(
        root.existsSync(),
        isTrue,
        reason: 'removing the folder the user chose looks like an uninstall',
      );
    });

    test('a folder with other files in it is kept', () async {
      await writeBytes(disk, root.path, 'a/one.txt', _bytes('1'));
      await writeBytes(disk, root.path, 'a/two.txt', _bytes('2'));

      await disk.remove(root.path, 'a/one.txt');

      expect(Directory('${root.path}/a').existsSync(), isTrue);
    });

    test('stat reports what is on disk, and null for what is not', () async {
      await writeBytes(disk, root.path, 'a.txt', _bytes('abcd'));
      expect((await disk.stat(root.path, 'a.txt'))!.size, 4);
      expect(await disk.stat(root.path, 'nope.txt'), isNull);
      expect(await readAllFrom(disk, root.path, 'nope.txt'), isNull);
    });
  });

  group('the cloud adapter', () {
    late HiddenVolumeStorage storage;
    late CloudService cloud;
    late CloudServiceFolderSync adapter;

    setUp(() async {
      storage = FakeHvContainer().storage();
      await storage.open(password: 'pw', createIfMissing: true);
      var minted = 0;
      cloud = CloudService(
        storage,
        _NullSync(),
        contentReceived: const Stream.empty(),
        now: () => DateTime.fromMillisecondsSinceEpoch(100),
        newId: () => 'item-${minted++}',
        integrityChecks: false,
      );
      adapter = CloudServiceFolderSync(cloud);
    });
    tearDown(() async {
      await cloud.close();
      await storage.close();
    });

    test('a nested path creates the folder chain once and reads back', () async {
      await uploadBytes(adapter, 
        path: 'docs/2026/notes.txt',
        folderId: null,
        existingItemId: null,
        bytes: _bytes('body'),
      );
      await uploadBytes(adapter, 
        path: 'docs/2026/other.txt',
        folderId: null,
        existingItemId: null,
        bytes: _bytes('more'),
      );

      final listed = await adapter.list(null);
      expect(
        listed.map((f) => f.path).toSet(),
        {'docs/2026/notes.txt', 'docs/2026/other.txt'},
      );
      expect(
        cloud.listFolders().where((f) => f.name == '2026'),
        hasLength(1),
        reason: 'the second upload must reuse the folder, not duplicate it',
      );
    });

    test('listing a pair rooted at a folder excludes everything outside it',
        () async {
      final inside = await cloud.createFolder('mirror');
      await uploadBytes(adapter, 
        path: 'in.txt',
        folderId: inside.id,
        existingItemId: null,
        bytes: _bytes('a'),
      );
      await uploadBytes(adapter, 
        path: 'out.txt',
        folderId: null,
        existingItemId: null,
        bytes: _bytes('b'),
      );

      final listed = await adapter.list(inside.id);

      expect(listed.map((f) => f.path), ['in.txt']);
    });

    test('re-uploading an existing path advances the SAME item', () async {
      final first = await uploadBytes(adapter, 
        path: 'a.txt',
        folderId: null,
        existingItemId: null,
        bytes: _bytes('one'),
      );
      final second = await uploadBytes(adapter, 
        path: 'a.txt',
        folderId: null,
        existingItemId: first.itemId,
        bytes: _bytes('two'),
      );

      expect(second.itemId, first.itemId);
      expect(second.contentId, isNot(first.contentId));
      expect(await adapter.list(null), hasLength(1));
    });

    test('a note is not mirrored — its branches cannot survive a file',
        () async {
      await cloud.saveTextNote(title: 'N', body: 'b');
      await uploadBytes(adapter, 
        path: 'a.txt',
        folderId: null,
        existingItemId: null,
        bytes: _bytes('a'),
      );

      expect((await adapter.list(null)).map((f) => f.path), ['a.txt']);
    });

    test('rename moves the item inside the pair, not to the cloud root',
        () async {
      final pairRoot = await cloud.createFolder('mirror');
      final file = await uploadBytes(adapter, 
        path: 'old/name.txt',
        folderId: pairRoot.id,
        existingItemId: null,
        bytes: _bytes('x'),
      );

      await adapter.rename(file.itemId, 'new/renamed.txt');

      final listed = await adapter.list(pairRoot.id);
      expect(listed.map((f) => f.path), ['new/renamed.txt']);
      expect(
        listed.single.itemId,
        file.itemId,
        reason: 'a move must keep the item, not replace it',
      );
    });

    test('a deleted item disappears from the listing', () async {
      final file = await uploadBytes(adapter, 
        path: 'a.txt',
        folderId: null,
        existingItemId: null,
        bytes: _bytes('a'),
      );

      await adapter.delete(file.itemId);

      expect(await adapter.list(null), isEmpty);
      expect(await downloadBytes(adapter, file.itemId), isNull);
    });
  });

  group('folder sync moves files in ranges, not whole (P0-5)', () {
    late Directory root;

    setUp(() {
      final tmp = Directory.systemTemp.createTempSync('xveil_ranges');
      addTearDown(() => tmp.deleteSync(recursive: true));
      root = Directory('${tmp.path}/root')..createSync();
    });

    test('openRead serves slices without reading the file whole', () async {
      const disk = LocalFolderSyncDisk();
      await writeBytes(disk, root.path, 'a.bin', _bytes('abcdefghij'));

      final source = (await disk.openRead(root.path, 'a.bin'))!;
      try {
        expect(source.size, 10);
        expect(await source.read(0, 3), _bytes('abc'));
        expect(await source.read(4, 3), _bytes('efg'));
        // A read running past the end returns what exists, not an error.
        expect(await source.read(8, 100), _bytes('ij'));
      } finally {
        await source.dispose();
      }
    });

    test('openRead is null for a file that is not there', () async {
      const disk = LocalFolderSyncDisk();
      expect(await disk.openRead(root.path, 'nope.bin'), isNull);
    });

    test('writeFrom pulls in bounded hops, never the whole file', () async {
      const disk = LocalFolderSyncDisk();
      final asked = <int>[];
      final size = kFolderSyncChunkBytes * 2 + 17;
      final source = RangeSource(
        size: size,
        read: (offset, length) async {
          asked.add(length);
          return Uint8List(length);
        },
      );

      await disk.writeFrom(root.path, 'big.bin', source);

      expect(File('${root.path}/big.bin').lengthSync(), size);
      expect(
        asked.every((n) => n <= kFolderSyncChunkBytes),
        isTrue,
        reason: 'a hop larger than the chunk defeats the bound',
      );
      expect(asked.length, greaterThan(1));
    });

    test('a source that dies partway publishes nothing', () async {
      // The property that matters most here: renaming a short file into place
      // would make the next scan read the truncation as a deliberate user edit
      // and faithfully upload the damage over the good cloud copy.
      const disk = LocalFolderSyncDisk();
      var hops = 0;
      final source = RangeSource(
        size: kFolderSyncChunkBytes * 3,
        read: (offset, length) async {
          hops++;
          return hops > 1 ? null : Uint8List(length);
        },
      );

      await disk.writeFrom(root.path, 'half.bin', source);

      expect(
        File('${root.path}/half.bin').existsSync(),
        isFalse,
        reason: 'a truncated download must never reach the mirrored path',
      );
    });

    test('an existing file is replaced only once the write completes', () async {
      const disk = LocalFolderSyncDisk();
      await writeBytes(disk, root.path, 'keep.txt', _bytes('good'));

      var hops = 0;
      await disk.writeFrom(
        root.path,
        'keep.txt',
        RangeSource(
          size: kFolderSyncChunkBytes * 2,
          read: (offset, length) async {
            hops++;
            return hops > 1 ? null : Uint8List(length);
          },
        ),
      );

      expect(
        await readAllFrom(disk, root.path, 'keep.txt'),
        _bytes('good'),
        reason: 'the previous contents must survive a failed replacement',
      );
    });
  });
}
