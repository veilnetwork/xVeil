@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/rollback_anchor.dart';

Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));
Uint8List body(int seed) {
  final random = Random(seed);
  return Uint8List.fromList(List.generate(1024, (_) => random.nextInt(256)));
}

void main() {
  late Directory fixture;
  late ManagedDirectoryCatalog root;
  final live = <ManagedIdentityStore>[];
  final id = ManagedIdentityId('1' * 32);
  final siblingId = ManagedIdentityId('2' * 32);
  final password = bytes('synthetic reclaim password');
  setUp(() {
    expect(ensureHiddenVolumeLoaded(), isTrue);
    fixture = Directory.systemTemp.createTempSync('xveil-managed-reclaim-');
    final profile = '${fixture.path}/profile';
    expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
    root = ManagedDirectoryCatalog.createOrOpen(profile);
  });
  tearDown(() {
    for (final store in live) {
      store.close();
    }
    live.clear();
    root.close();
    fixture.deleteSync(recursive: true);
  });
  ManagedIdentityStore seeded() {
    final store = ManagedIdentityFiles.createEncrypted(
      root,
      id: id,
      password: password,
    );
    live.add(store);
    for (var i = 0; i < 80; i++) {
      store.commit([AppendLogOp(Ns.fileChunks, i % 4 + 1, body(i))]);
    }
    return store;
  }

  void anchorClean(ManagedIdentityStore store, int seq, String hash) {
    expect(
      checkRollbackAnchor(
        anchorSeq: seq,
        anchorRoot: hash,
        currentSeq: store.commitSeq(),
        history: store.commitHistory(),
        roots: store.commitRoots(),
      ).verdict,
      AnchorVerdict.clean,
    );
  }

  test(
    'plaintext reclamation remains SQLite-owned without encrypted side files',
    () async {
      final store = ManagedIdentityFiles.createUnencrypted(
        root,
        id: id,
        initial: [PutOp(1, bytes('plain'), bytes('fixture value'))],
      );
      live.add(store);
      final snapshot = File(root.layout.dataPath(id)).readAsBytesSync();
      final report = await store.reclaim(force: true);
      expect(report.changed, isFalse);
      expect(report.beforeBytes, snapshot.length);
      expect(report.afterBytes, snapshot.length);
      expect(File(root.layout.dataPath(id)).readAsBytesSync(), snapshot);
      expect(File(root.layout.keyboxPath(id)).existsSync(), isFalse);
      expect(store.get(1, bytes('plain')), bytes('fixture value'));
    },
  );

  test(
    'content and maintenance shrink with stable outer keys and isolated sibling',
    () async {
      var store = seeded();
      // Grow a real live log, then delete it. Constant-size overwrites can
      // already reuse native slots and need not leave a shrinkable file.
      for (var i = 0; i < 1200; i++) {
        store.commit([AppendLogOp(Ns.fileChunks, 1000 + i, body(1000 + i))]);
      }
      for (var first = 0; first < 1200; first += 32) {
        store.commit([
          for (var i = first; i < min(first + 32, 1200); i++)
            DeleteLogOp(Ns.fileChunks, 1000 + i),
        ]);
      }
      final sibling = ManagedIdentityFiles.createUnencrypted(
        root,
        id: siblingId,
        initial: [PutOp(1, bytes('scope'), bytes('independent'))],
      );
      live.add(sibling);
      final siblingBytes = File(
        root.layout.dataPath(siblingId),
      ).readAsBytesSync();
      final keyboxBytes = File(root.layout.keyboxPath(id)).readAsBytesSync();
      final keys = store.exportKeys();
      final head = store.commitSeq(),
          hash = store.commitRoots()[store.commitSeq()]!;
      final report = await store.reclaim(force: true);
      expect(report.contentRepacked, isTrue);
      expect(report.maintenanceRepacked, isTrue);
      expect(report.afterBytes, lessThan(report.beforeBytes));
      expect(store.exportKeys(), keys);
      expect(store.commitSeq(), head + 2);
      anchorClean(store, head, hash);
      for (var i = 76; i < 80; i++) {
        expect(store.readLog(Ns.fileChunks, i % 4 + 1), body(i));
      }
      expect(File(root.layout.keyboxPath(id)).readAsBytesSync(), keyboxBytes);
      expect(
        File(root.layout.dataPath(siblingId)).readAsBytesSync(),
        siblingBytes,
      );
      expect(sibling.get(1, bytes('scope')), bytes('independent'));
      final idle = await store.reclaim();
      expect(idle.changed, isFalse);
      expect(idle.afterBytes, report.afterBytes);
      store.close();
      store = ManagedIdentityFiles.openWithKeys(root, id: id, keys: keys);
      live.add(store);
      expect(store.exportKeys(), keys);
      anchorClean(store, head, hash);
      expect(
        store.commit([PutOp(1, bytes('later'), bytes('durable'))]),
        head + 3,
      );
      store.close();
      final cold = ManagedIdentityFiles.openWithPassword(
        root,
        id: id,
        password: password,
      );
      live.add(cold);
      expect(cold.get(1, bytes('later')), bytes('durable'));
      anchorClean(cold, head, hash);
      keys.fillRange(0, keys.length, 0);
    },
  );

  test(
    'held prepare blocks use/close, abort restores old content and its anchor',
    () async {
      final store = seeded();
      final keys = store.exportKeys();
      final head = store.commitSeq(),
          hash = store.commitRoots()[store.commitSeq()]!;
      final entered = Completer<void>(), release = Completer<void>();
      final pending = store.debugReclaim((stage) async {
        if (stage == ManagedReclaimStage.contentPrepared) {
          entered.complete();
          await release.future;
          throw StateError('synthetic pre-publication refusal');
        }
      });
      final failure = expectLater(
        pending,
        throwsA(isA<ManagedIdentityFailure>()),
      );
      await entered.future;
      try {
        for (final action in [
          () => store.get(1, bytes('scope')),
          store.close,
          root.close,
        ]) {
          expect(action, throwsA(isA<ManagedIdentityFailure>()));
        }
        final contender = ManagedDirectoryCatalog.openExisting(
          root.profileDirectory,
        )!;
        try {
          expect(
            () => ManagedIdentityFiles.openWithKeys(
              contender,
              id: id,
              keys: keys,
            ),
            throwsA(isA<ManagedIdentityFailure>()),
          );
        } finally {
          contender.close();
        }
      } finally {
        release.complete();
      }
      await failure;
      expect(store.commitSeq(), head + 1);
      expect(store.exportKeys(), keys);
      anchorClean(store, head, hash);
      for (var i = 76; i < 80; i++) {
        expect(store.readLog(Ns.fileChunks, i % 4 + 1), body(i));
      }
      keys.fillRange(0, keys.length, 0);
    },
  );

  for (final cut in [
    ManagedReclaimStage.contentPublished,
    ManagedReclaimStage.maintenancePrepared,
    ManagedReclaimStage.maintenancePublished,
  ]) {
    test(
      'refused $cut reattaches the authenticated current generation',
      () async {
        final store = seeded();
        final head = store.commitSeq(),
            hash = store.commitRoots()[store.commitSeq()]!;
        final keybox = File(root.layout.keyboxPath(id)).readAsBytesSync();
        await expectLater(
          store.debugReclaim((stage) async {
            if (stage == cut) throw StateError('synthetic maintenance refusal');
          }),
          throwsA(isA<ManagedIdentityFailure>()),
        );
        expect(store.commitSeq(), head + 2);
        anchorClean(store, head, hash);
        for (var i = 76; i < 80; i++) {
          expect(store.readLog(Ns.fileChunks, i % 4 + 1), body(i));
        }
        expect(File(root.layout.keyboxPath(id)).readAsBytesSync(), keybox);
        expect(
          store.commit([PutOp(1, bytes('after-error'), bytes('preserved'))]),
          head + 3,
        );
      },
    );
  }

  test(
    'in-place source replay cannot be promoted under the current host anchor',
    () async {
      final store = ManagedIdentityFiles.createEncrypted(
        root,
        id: id,
        password: password,
      );
      live.add(store);
      store.commit([PutOp(1, bytes('snapshot'), bytes('old fixture value'))]);
      final content = File(root.layout.contentPath(id));
      final old = content.readAsBytesSync();
      store.commit([
        PutOp(1, bytes('snapshot'), bytes('latest fixture value')),
      ]);
      final head = store.commitSeq(),
          hash = store.commitRoots()[store.commitSeq()]!;
      var restored = false;
      Object outcome;
      try {
        await store.debugReclaim((stage) async {
          if (stage == ManagedReclaimStage.contentDetached && !restored) {
            restored = true;
            // Preserve the inode: path identity alone cannot detect page/whole-
            // file replay between closing the source and preparing its copy.
            content.writeAsBytesSync(old, flush: true);
          }
        });
        outcome = {
          'value': utf8.decode(store.get(1, bytes('snapshot'))!),
          'anchor': checkRollbackAnchor(
            anchorSeq: head,
            anchorRoot: hash,
            currentSeq: store.commitSeq(),
            history: store.commitHistory(),
            roots: store.commitRoots(),
          ).verdict.name,
        };
      } catch (error) {
        outcome = error;
      }
      expect(outcome, isA<ManagedIdentityFailure>());
      expect(restored, isTrue);
      expect(
        () => store.get(1, bytes('snapshot')),
        throwsA(isA<ManagedIdentityFailure>()),
      );
    },
  );
}
