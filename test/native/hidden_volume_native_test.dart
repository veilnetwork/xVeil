import 'dart:io';
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
}
