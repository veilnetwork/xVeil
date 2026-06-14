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
}
