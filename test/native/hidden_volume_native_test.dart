import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';

/// End-to-end test against the REAL hidden-volume native library — proves the
/// storage layer persists to an actual deniable container on disk. Skipped
/// (not failed) when the dylib hasn't been built, so CI without the Rust
/// toolchain stays green; run `scripts/build-native.sh` first to exercise it.
void main() {
  final available = ensureHiddenVolumeLoaded();
  final skipReason = available
      ? null
      : 'libhidden_volume_ffi not built — run scripts/build-native.sh';

  test('persists identity + messages to a real container, survives reopen',
      () async {
    final dir = Directory.systemTemp.createTempSync('xveil_hv_');
    final path = '${dir.path}/test.store';
    // ArgonPreset.min — test-only fast KDF.
    SpaceOpener opener() => hvSpaceOpener(path, argon: hv.ArgonPreset.min);

    try {
      final storage = HiddenVolumeStorage(opener());
      expect(await storage.open(password: 'sw0rdfish', createIfMissing: true),
          isTrue);

      final nodeId = NodeId(Uint8List.fromList(List.filled(32, 9)));
      await storage.saveIdentity(Identity(nodeId: nodeId, displayName: 'Nat'));
      await storage.appendMessage(Message(
        id: 'm1',
        conversationId: nodeId.hex,
        direction: MessageDirection.outgoing,
        body: 'hello over real storage',
        timestamp: DateTime(2026, 6, 14, 20),
      ));
      await storage.close();

      // Reopen with the correct password — data is durable.
      final reopened = HiddenVolumeStorage(opener());
      expect(await reopened.open(password: 'sw0rdfish'), isTrue);
      expect((await reopened.loadIdentity())?.displayName, 'Nat');
      final msgs = await reopened.loadMessages(nodeId.hex);
      expect(msgs.single.body, 'hello over real storage');
      await reopened.close();

      // Wrong password unlocks nothing (AuthFailed -> false), no leak.
      final attacker = HiddenVolumeStorage(opener());
      expect(await attacker.open(password: 'guess'), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skipReason);

  // Multi-identity: createIfMissing over an existing container adds a NEW
  // parallel deniable space (a new identity hidden in the same file) for a new
  // password, and adopts the existing space for the same password — never
  // crashes with `Io: File exists`, never clobbers existing data.
  test('createIfMissing over an existing container: new password adds an '
      'identity, same password adopts', () async {
    final dir = Directory.systemTemp.createTempSync('xveil_hv_multi_');
    final path = '${dir.path}/test.store';
    SpaceOpener opener() => hvSpaceOpener(path, argon: hv.ArgonPreset.min);
    try {
      final first = HiddenVolumeStorage(opener());
      expect(await first.open(password: 'p1', createIfMissing: true), isTrue);
      await first.putSetting('marker', 'orig');
      await first.close();

      // Same password again: adopt the existing space (SpaceAlreadyExists ->
      // open), preserving its data — not a second copy, not a crash.
      final again = HiddenVolumeStorage(opener());
      expect(await again.open(password: 'p1', createIfMissing: true), isTrue);
      expect(await again.getSetting('marker'), 'orig');
      await again.close();

      // A DIFFERENT password adds a new parallel space: a fresh, empty identity
      // in the same file. It opens successfully and shares nothing with p1.
      final second = HiddenVolumeStorage(opener());
      expect(await second.open(password: 'p2', createIfMissing: true), isTrue);
      expect(await second.getSetting('marker'), isNull, reason: 'fresh space');
      await second.putSetting('marker', 'second');
      await second.close();

      // Both identities now coexist, each opening only its own data.
      final p1 = HiddenVolumeStorage(opener());
      expect(await p1.open(password: 'p1'), isTrue);
      expect(await p1.getSetting('marker'), 'orig');
      await p1.close();
      final p2 = HiddenVolumeStorage(opener());
      expect(await p2.open(password: 'p2'), isTrue);
      expect(await p2.getSetting('marker'), 'second');
      await p2.close();

      // A never-used password still unlocks nothing (no leak, no auto-create on
      // the non-creating open path).
      final stranger = HiddenVolumeStorage(opener());
      expect(await stranger.open(password: 'p3'), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skipReason);

  // Deniable erasure end-to-end on a REAL container: deleting a message orphans
  // its data chunk (a forensic password-holder could otherwise recover it), and
  // scrub/vacuum reclaims it for good. The in-memory fake can't prove this (its
  // scrub is a no-op), so this is the test that backs the threat-model claim.
  test('delete leaves a reclaimable orphan; scrub reclaims it (real container)',
      () async {
    final dir = Directory.systemTemp.createTempSync('xveil_hv_scrub_');
    final path = '${dir.path}/test.store';
    final conv = NodeId(Uint8List.fromList(List.filled(32, 7))).hex;
    try {
      // Build the real space directly so we can also inspect vacuum counts.
      final space = hv.HvSpace.create(
          path: path,
          password: Uint8List.fromList('pw'.codeUnits),
          argon: hv.ArgonPreset.min);
      final store = HvKvLogStore(space);
      final storage =
          HiddenVolumeStorage(({required password, required create}) => store);
      await storage.open(password: 'pw', createIfMissing: true);

      await storage.appendMessage(Message(
        id: 'secret1',
        conversationId: conv,
        direction: MessageDirection.incoming,
        body: 'PLAINTEXT-THAT-MUST-VANISH',
        timestamp: DateTime(2026, 6, 15),
      ));

      // Delete tombstones the row + orphans the old chunk, but does NOT scrub.
      await storage.deleteMessage(conv, 'secret1');
      expect(await storage.loadMessages(conv), isEmpty,
          reason: 'gone from the API immediately');

      // The orphan is still reclaimable on disk — exactly the forensic surface.
      final reclaimed = space.vacuumDataBatches();
      expect(reclaimed, greaterThan(0),
          reason: 'delete must leave an orphan chunk that vacuum can reclaim');
      // Now nothing left to reclaim, and the container is still consistent.
      expect(space.vacuumDataBatches(), 0);
      expect(() => space.verifyIntegrity(), returnsNormally); // no IntegrityFailure

      await storage.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skipReason);

  // Deleting a file message purges the blob in the SAME atomic operation; after
  // scrub the orphaned blob chunks are reclaimed too.
  test('deleting a file message purges + reclaims the blob (real container)',
      () async {
    final dir = Directory.systemTemp.createTempSync('xveil_hv_blob_');
    final path = '${dir.path}/test.store';
    final conv = NodeId(Uint8List.fromList(List.filled(32, 8))).hex;
    try {
      final space = hv.HvSpace.create(
          path: path,
          password: Uint8List.fromList('pw'.codeUnits),
          argon: hv.ArgonPreset.min);
      final store = HvKvLogStore(space);
      final storage =
          HiddenVolumeStorage(({required password, required create}) => store);
      await storage.open(password: 'pw', createIfMissing: true);

      await storage.storeFile(
          'blob1', Uint8List.fromList(List.filled(4000, 42)),
          name: 'secret.bin');
      await storage.appendMessage(Message(
        id: 'fmsg',
        conversationId: conv,
        direction: MessageDirection.incoming,
        body: '📎 secret.bin',
        timestamp: DateTime(2026, 6, 15),
        fileId: 'blob1',
        fileName: 'secret.bin',
      ));
      expect(await storage.loadFile('blob1'), isNotNull);

      await storage.deleteMessage(conv, 'fmsg'); // folds the blob purge in one commit
      expect(await storage.loadFile('blob1'), isNull, reason: 'blob row gone');

      expect(space.vacuumDataBatches(), greaterThan(0),
          reason: 'the blob chunks were orphaned and are reclaimable');
      expect(() => space.verifyIntegrity(), returnsNormally); // no IntegrityFailure

      await storage.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skipReason);

  // A multi-MiB INCOMPRESSIBLE file on a REAL container — the case a phone photo
  // hits. Each ~4 KiB container chunk holds one ≤3800-byte record; an 8 KiB
  // record (the old chunk size) could NOT be placed in a 4 KiB chunk even after
  // the store's auto-split (which can't divide below one record) → it threw
  // HvException.PayloadTooLarge. CRITICAL: the data must be RANDOM — compressible
  // data zstd-crushes under PAYLOAD_CAP and hides the bug (an earlier patterned
  // test passed falsely).
  test('stores + reloads a multi-MiB INCOMPRESSIBLE file on a real container',
      () async {
    final dir = Directory.systemTemp.createTempSync('xveil_hv_bigfile_');
    final path = '${dir.path}/test.store';
    try {
      final space = hv.HvSpace.create(
          path: path,
          password: Uint8List.fromList('pw'.codeUnits),
          argon: hv.ArgonPreset.min);
      final store = HvKvLogStore(space);
      final storage =
          HiddenVolumeStorage(({required password, required create}) => store);
      await storage.open(password: 'pw', createIfMissing: true);

      // ~3 MiB of RANDOM bytes (incompressible, like a JPEG) — ~790 records.
      final rnd = Random(1234);
      final data =
          Uint8List.fromList(List.generate(3000000, (_) => rnd.nextInt(256)));
      final sw = Stopwatch()..start();
      await storage.storeFile('big', data, name: 'photo.jpg');
      sw.stop();
      // ignore: avoid_print
      print('storeFile 3MB incompressible: ${sw.elapsedMilliseconds}ms');
      expect(await storage.loadFile('big'), data,
          reason: 'blob reassembles byte-for-byte');
      expect(() => space.verifyIntegrity(), returnsNormally);

      await storage.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skipReason);

  // The master-space FFI (open_with_keys / space_keys) end-to-end through
  // xVeil's stack on a real container — using the flock-respecting flow: the
  // real library takes an EXCLUSIVE per-container lock, so only ONE space is
  // open at a time — the flow IdentityManager serializes (open/close), and the
  // reason the earlier simultaneous-open MasterVault only worked on the fake.
  test('master roster + openWithKeys, one space open at a time (real container)',
      () async {
    final dir = Directory.systemTemp.createTempSync('xveil_hv_master_');
    final path = '${dir.path}/test.store';
    HiddenVolumeStorage make() => HiddenVolumeStorage(
          hvSpaceOpener(path, argon: hv.ArgonPreset.min),
          keysOpener: hvKeysSpaceOpener(path),
        );
    try {
      // 1. The child space (first space in the container): write + export keys,
      //    then CLOSE to release the exclusive lock.
      final child = make();
      expect(
          await child.open(password: 'pw-alice', createIfMissing: true), isTrue);
      await child.putSetting('who', 'alice');
      final childKeys = await child.exportSpaceKeys();
      await child.close();

      // 2. The master (a parallel space): record the child's keys, then close.
      final master = make();
      expect(await master.open(password: 'pw-master', createIfMissing: true),
          isTrue);
      await master.saveRoster([RosterEntry(label: 'alice', spaceKeys: childKeys)]);
      await master.close();

      // 3. Fresh master session: read the roster, CLOSE, then open the child by
      //    its keys alone — no password, no two-handles-at-once.
      final m2 = make();
      expect(await m2.open(password: 'pw-master'), isTrue);
      final entries = await m2.loadRoster();
      expect(entries!.map((e) => e.label), ['alice']);
      final aliceKeys = entries.single.spaceKeys;
      await m2.close();

      final reopened = make();
      expect(await reopened.openWithKeys(aliceKeys), isTrue);
      expect(await reopened.getSetting('who'), 'alice');
      await reopened.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skipReason);
}
