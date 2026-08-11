@TestOn('!windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/posix_file_facts.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/state/folder_sync_controller.dart';
import 'package:xveil/state/providers.dart';

/// A Storage that only remembers files — everything else a caller reaches for
/// hits noSuchMethod and fails loudly rather than returning a quiet default.
class _FileOnlyStorage implements Storage {
  final files = <String, Uint8List>{};

  @override
  Future<void> storeFile(String fileId, Uint8List bytes, {String? name}) async {
    files[fileId] = bytes;
  }

  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) async =>
      files[fileId];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _mode0777 = 0x1FF;
const _mode0755 = 0x1ED;

void _chmod(Directory dir, int mode) {
  expect(
    posixChmod(dir.path, mode),
    0,
    reason: 'the fixture could not set the mode this test is about',
  );
}

void main() {
  late ProviderContainer container;
  late FolderSyncController controller;

  setUp(() {
    container = ProviderContainer(
      overrides: [storageProvider.overrideWith((ref) => _FileOnlyStorage())],
    );
    addTearDown(container.dispose);
    controller = container.read(folderSyncControllerProvider.notifier);
  });

  Directory tempRoot(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return dir;
  }

  // A sync root is a folder this app writes into on behalf of whatever the
  // cloud account admits. If somebody else on the machine can swap that folder
  // — or any folder ABOVE it — for a link, the app carries their redirection
  // out with the user's authority: the confused deputy the mirror must not be.
  group('a folder another account can reach is not accepted as a sync root',
      () {
    test('a private folder inside a world-writable PARENT is refused',
        () async {
      // The case a leaf-only check misses, and the reason the whole chain is
      // walked: the folder itself is 0755 and blameless, while anyone can
      // rename it out of the way and leave a link with the same name behind.
      final tmp = tempRoot('xveil_gate_parent');
      final parent = Directory('${tmp.path}/open')..createSync();
      final root = Directory('${parent.path}/mirror')..createSync();
      _chmod(root, _mode0755);
      _chmod(parent, _mode0777);

      final refusal = await controller.addPair(
        localPath: root.path,
        id: 'pair-parent',
      );

      expect(refusal, isNotNull, reason: 'a reachable chain must be refused');
      expect(
        refusal!.code,
        FolderSyncRefusalCode.writableByOtherAccounts,
        reason: 'the refusal must say WHICH rule turned the folder down',
      );
      // `endsWith`, not equality: the walk starts from the RESOLVED chain, so
      // on macOS the step is `/private/var/…` where the fixture built
      // `/var/…`. Both name the same directory and the resolved one is the
      // more useful of the two to show.
      expect(
        refusal.path,
        endsWith(parent.path),
        reason: 'the refusal must name the step that is actually open',
      );
      expect(
        container.read(folderSyncControllerProvider),
        isEmpty,
        reason: 'a refused folder must not end up configured anyway',
      );
    });

    test('the folder itself being world-writable is refused too', () async {
      final tmp = tempRoot('xveil_gate_leaf');
      final root = Directory('${tmp.path}/mirror')..createSync();
      _chmod(root, _mode0777);

      final refusal = await controller.addPair(
        localPath: root.path,
        id: 'pair-leaf',
      );

      expect(refusal?.code, FolderSyncRefusalCode.writableByOtherAccounts);
      expect(refusal?.path, endsWith(root.path));
      expect(container.read(folderSyncControllerProvider), isEmpty);
    });
  });

  test('an ordinary private folder is accepted', () async {
    // The gate has to refuse reachability, not depth: a mirror that turned
    // down normal folders would be broken rather than safe. `Directory
    // .systemTemp` is 0700 on macOS and sticky 1777 on Linux, and both are
    // private enough — nobody else may rename what is inside them.
    final tmp = tempRoot('xveil_gate_ok');
    final parent = Directory('${tmp.path}/quiet')..createSync();
    final root = Directory('${parent.path}/mirror')..createSync();
    _chmod(root, _mode0755);
    _chmod(parent, _mode0755);

    final refusal = await controller.addPair(
      localPath: root.path,
      id: 'pair-ok',
    );

    expect(refusal, isNull, reason: 'nothing about this folder is reachable');
    final views = container.read(folderSyncControllerProvider);
    expect(views.single.pair.id, 'pair-ok');
    expect(views.single.pair.localPath, root.path);
  });
}
