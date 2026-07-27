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
      await disk.write(root.path, 'nested/a.txt', _bytes('hello'));

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
      await disk.write(root.path, 'a.txt', _bytes('original'));
      File('${root.path}/a.txt$kPartialSuffix').writeAsStringSync('trunc');

      expect(File('${root.path}/a.txt').readAsStringSync(), 'original');
      final scan = await disk.scan(root.path);
      expect(scan.files.map((f) => f.path), ['a.txt']);
    });

    test('debris does not defeat the next write of the same file', () async {
      File('${root.path}/a.txt$kPartialSuffix').writeAsStringSync('stale');

      await disk.write(root.path, 'a.txt', _bytes('fresh'));

      expect(File('${root.path}/a.txt').readAsStringSync(), 'fresh');
      expect(File('${root.path}/a.txt$kPartialSuffix').existsSync(), isFalse);
    });

    test('removing the last file prunes its folders but never the root',
        () async {
      await disk.write(root.path, 'a/b/c.txt', _bytes('x'));

      await disk.remove(root.path, 'a/b/c.txt');

      expect(Directory('${root.path}/a').existsSync(), isFalse);
      expect(
        root.existsSync(),
        isTrue,
        reason: 'removing the folder the user chose looks like an uninstall',
      );
    });

    test('a folder with other files in it is kept', () async {
      await disk.write(root.path, 'a/one.txt', _bytes('1'));
      await disk.write(root.path, 'a/two.txt', _bytes('2'));

      await disk.remove(root.path, 'a/one.txt');

      expect(Directory('${root.path}/a').existsSync(), isTrue);
    });

    test('stat reports what is on disk, and null for what is not', () async {
      await disk.write(root.path, 'a.txt', _bytes('abcd'));
      expect((await disk.stat(root.path, 'a.txt'))!.size, 4);
      expect(await disk.stat(root.path, 'nope.txt'), isNull);
      expect(await disk.read(root.path, 'nope.txt'), isNull);
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
      await adapter.upload(
        path: 'docs/2026/notes.txt',
        folderId: null,
        existingItemId: null,
        bytes: _bytes('body'),
      );
      await adapter.upload(
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
      await adapter.upload(
        path: 'in.txt',
        folderId: inside.id,
        existingItemId: null,
        bytes: _bytes('a'),
      );
      await adapter.upload(
        path: 'out.txt',
        folderId: null,
        existingItemId: null,
        bytes: _bytes('b'),
      );

      final listed = await adapter.list(inside.id);

      expect(listed.map((f) => f.path), ['in.txt']);
    });

    test('re-uploading an existing path advances the SAME item', () async {
      final first = await adapter.upload(
        path: 'a.txt',
        folderId: null,
        existingItemId: null,
        bytes: _bytes('one'),
      );
      final second = await adapter.upload(
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
      await adapter.upload(
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
      final file = await adapter.upload(
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
      final file = await adapter.upload(
        path: 'a.txt',
        folderId: null,
        existingItemId: null,
        bytes: _bytes('a'),
      );

      await adapter.delete(file.itemId);

      expect(await adapter.list(null), isEmpty);
      expect(await adapter.download(file.itemId), isNull);
    });
  });
}
