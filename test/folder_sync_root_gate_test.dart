@TestOn('!windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/posix_file_facts.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/folder_sync.dart';
import 'package:xveil/state/folder_sync_controller.dart';
import 'package:xveil/state/folder_sync_engine.dart';
import 'package:xveil/state/providers.dart';

/// A Storage that only remembers files — everything else a caller reaches for
/// hits noSuchMethod and fails loudly rather than returning a quiet default.
class _FileOnlyStorage implements Storage {
  final files = <String, Uint8List>{};

  @override
  Future<void> storeFile(
    String fileId,
    Uint8List bytes, {
    String? name,
    List<String> retireHints = const [],
  }) async {
    files[fileId] = bytes;
  }

  @override
  Future<Uint8List?> loadFile(String fileId, {int? maxBytes}) async =>
      files[fileId];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}


/// Counts passes and does nothing else: the question is whether the engine is
/// reached at all, not what it would have done.
class _CountingEngine extends FolderSyncEngine {
  _CountingEngine(super.cloud, super.disk, super.store, super.now);

  int runs = 0;

  @override
  Future<FolderSyncReport> runOnce(FolderSyncPair pair) async {
    runs++;
    return const FolderSyncReport(applied: [], failed: [], conflicts: {});
  }
}

class _UnusedCloud implements FolderSyncCloud {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedDisk implements FolderSyncDisk {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _mode0777 = 0x1FF;
const _mode0755 = 0x1ED;
const _mode0700 = 0x1C0;

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
    // MADE private, not assumed private.
    //
    // The gate walks every step above the root and refuses a group- or
    // other-writable one, so the fixture's own scratch directory is part of
    // what it measures. `createTempSync` is 0700 on macOS, but on a machine
    // whose umask is 002 it comes out 0775 — group-writable — and every case
    // in this file then refuses for a reason that belongs to the machine
    // rather than to the folder under test. Measured on an aarch64 Linux box
    // where `stat` and the gate agreed at 775: the gate was right and the
    // fixture was not.
    _chmod(dir, _mode0700);
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return dir;
  }

  // A sync root is a folder this app writes into on behalf of whatever the
  // cloud account admits. If somebody else on the machine can swap that folder
  // — or any folder ABOVE it — for a link, the app carries their redirection
  // out with the user's authority: the confused deputy the mirror must not be.

  // The gate above runs when the folder is CHOSEN. A root can stop being safe
  // afterwards, and every pass since had been trusting an answer from the day
  // the pair was added.
  test('a root that stops being safe is refused on the next pass', () async {
    final tmp = tempRoot('xveil_gate_later');
    final parent = Directory('${tmp.path}/holder')..createSync();
    final root = Directory('${parent.path}/mirror')..createSync();
    _chmod(root, _mode0700);
    _chmod(parent, _mode0755);

    late _CountingEngine engine;
    final c = ProviderContainer(
      overrides: [
        storageProvider.overrideWith((ref) => _FileOnlyStorage()),
        folderSyncEngineProvider.overrideWith((ref) {
          engine = _CountingEngine(
            _UnusedCloud(),
            _UnusedDisk(),
            ref.watch(folderSyncStoreProvider),
            () => 0,
          );
          return engine;
        }),
      ],
    );
    addTearDown(c.dispose);
    final ctrl = c.read(folderSyncControllerProvider.notifier);

    expect(
      await ctrl.addPair(localPath: root.path, id: 'later'),
      isNull,
      reason: 'the fixture must start from a root that IS acceptable',
    );
    final pair = c.read(folderSyncControllerProvider).single.pair;

    // A pass while it is still safe: the engine is reached.
    expect((await ctrl.runOnce(pair))?.isRefused, isFalse);
    expect(engine.runs, 1);

    // Now somebody opens the parent up — the folder itself is untouched.
    _chmod(parent, _mode0777);

    final report = await ctrl.runOnce(pair);
    expect(
      report?.isRefused,
      isTrue,
      reason: 'the pass has to re-ask, not trust the answer from setup',
    );
    expect(
      engine.runs,
      1,
      reason: 'a pass that cannot vouch for its root must not run a partial '
          'one',
    );
    expect(
      c.read(folderSyncControllerProvider).single.lastRefusal,
      isNotNull,
      reason: 'and the screen has to be able to say why nothing is sy'
          'ncing',
    );
  });

  for (final legacy in [false, true]) {
    test(
      'sync refuses a replacement of a private folder (legacy=$legacy)',
      () async {
        final parent = tempRoot('xveil_gate_object');
        final root = Directory('${parent.path}/mirror')..createSync();
        _chmod(root, _mode0700);
        late _CountingEngine engine;
        final c = ProviderContainer(
          overrides: [
            storageProvider.overrideWith((ref) => _FileOnlyStorage()),
            folderSyncEngineProvider.overrideWith((ref) {
              engine = _CountingEngine(
                _UnusedCloud(),
                _UnusedDisk(),
                ref.watch(folderSyncStoreProvider),
                () => 0,
              );
              return engine;
            }),
          ],
        );
        addTearDown(c.dispose);
        final ctrl = c.read(folderSyncControllerProvider.notifier);
        final store = c.read(folderSyncStoreProvider);
        if (legacy) {
          await store.savePairs([
            FolderSyncPair(id: 'private', localPath: root.path),
          ]);
          await ctrl.reload();
        } else {
          expect(
            await ctrl.addPair(localPath: root.path, id: 'private'),
            isNull,
          );
        }
        final pair = (await store.pairs()).single;
        expect(pair.rootApproval, isNull);
        if (legacy) {
          expect(pair.rootIdentity, isNull);
          expect((await ctrl.runOnce(pair))?.isRefused, isFalse);
        }
        final bound = (await store.pairs()).single;
        expect(bound.rootIdentity, isNotNull);
        root.renameSync('${parent.path}/previous');
        root.createSync();
        _chmod(root, _mode0700);

        final report = await ctrl.runOnce(pair);
        expect(report?.refusedReason, FolderSyncRefusalCode.pathChanged.name);
        expect(engine.runs, legacy ? 1 : 0);
        expect((await store.pairs()).single.rootIdentity, bound.rootIdentity);
      },
    );
  }

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
      expect(refusal.approval, isNull);
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
      expect(refusal?.approval, isNotNull);
      expect(container.read(folderSyncControllerProvider), isEmpty);
    });
  });

  test(
    'remembered consent is scoped to the folder and its current ACL',
    () async {
      final tmp = tempRoot('xveil_gate_consent');
      final root = Directory('${tmp.path}/mirror')..createSync();
      _chmod(root, _mode0777);
      final refusal = await controller.addPair(
        localPath: root.path,
        id: 'shared',
      );
      final approval = refusal!.approval!;
      expect(refusal.aclWarning!.grants, isNotEmpty);

      _chmod(root, 0x1FD); // 0775
      final changed = await controller.addPair(
        localPath: root.path,
        id: 'shared',
        rootApproval: approval,
      );
      expect(changed?.approval?.identity, approval.identity);
      expect(changed?.approval?.fingerprint, isNot(approval.fingerprint));
      expect(container.read(folderSyncControllerProvider), isEmpty);

      final current = changed!.approval!;
      expect(
        await controller.addPair(
          localPath: root.path,
          id: 'shared',
          rootApproval: current,
        ),
        isNull,
      );
      final saved =
          (await container.read(folderSyncStoreProvider).pairs()).single;
      expect(saved.rootApproval, current);
      expect(
        folderSyncRootRefusal(root.path, approval: saved.rootApproval),
        isNull,
      );

      root.renameSync('${tmp.path}/old-mirror');
      Directory(root.path).createSync();
      _chmod(root, _mode0700);
      expect(
        folderSyncRootRefusal(root.path, approval: saved.rootApproval)?.code,
        FolderSyncRefusalCode.pathChanged,
      );
    },
  );

  test('a readable shared folder needs consent and keeps deletion sync', () async {
    final root = tempRoot('xveil_gate_readable');
    _chmod(root, _mode0755);
    final warning = await controller.addPair(localPath: root.path, id: 'readable');
    expect(warning?.code, FolderSyncRefusalCode.readableByOtherAccounts);
    expect(warning?.approval?.writeAccess, isFalse);
    expect(
      await controller.addPair(
        localPath: root.path,
        id: 'readable',
        rootApproval: warning!.approval,
      ),
      isNull,
    );
    final saved = (await container.read(folderSyncStoreProvider).pairs()).single;
    expect(saved.deletePropagates, isTrue);
    expect(saved.rootApproval?.writeAccess, isFalse);
  });

  test('a macOS list and search ACL can be accepted', () {
    final root = tempRoot('xveil_gate_darwin_readable');
    final acl = Process.runSync('/bin/chmod', [
      '+a', 'everyone allow list,search', root.path,
    ]);
    expect(acl.exitCode, 0, reason: acl.stderr.toString());
    final warning = folderSyncRootRefusal(root.path);
    expect(warning?.code, FolderSyncRefusalCode.readableByOtherAccounts);
    expect(warning?.approval?.writeAccess, isFalse);
    expect(folderSyncRootRefusal(root.path, approval: warning!.approval), isNull);
  }, skip: !Platform.isMacOS);

  test('a macOS ACL for adding files prompts for write consent', () {
    final root = tempRoot('xveil_gate_darwin_add');
    final acl = Process.runSync('/bin/chmod', [
      '+a', 'everyone allow add_file', root.path,
    ]);
    expect(acl.exitCode, 0, reason: acl.stderr.toString());
    final warning = folderSyncRootRefusal(root.path);
    expect(warning?.code, FolderSyncRefusalCode.writableByOtherAccounts);
    expect(warning?.approval?.writeAccess, isTrue);
    expect(folderSyncRootRefusal(root.path, approval: warning!.approval), isNull);
  }, skip: !Platform.isMacOS);

  test('an ordinary private folder is accepted', () async {
    // The gate has to refuse reachability, not depth: a mirror that turned
    // down normal folders would be broken rather than safe. `Directory
    // .systemTemp` is 0700 on macOS and sticky 1777 on Linux, and both are
    // private enough — nobody else may rename what is inside them.
    final tmp = tempRoot('xveil_gate_ok');
    final parent = Directory('${tmp.path}/quiet')..createSync();
    final root = Directory('${parent.path}/mirror')..createSync();
    _chmod(root, _mode0700);
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
