import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/sovereign_identity_material.dart';
import 'package:xveil/data/storage/identity_setup_journal.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/identity_setup_intent.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'support/fake_hv_container.dart';

void main() {
  test(
    'the memory backend snapshots committed bytes like the native backend',
    () {
      final store = FakeKvLogStore();
      final kv = Uint8List.fromList([1, 2]);
      final log = Uint8List.fromList([3, 4]);
      final key = Uint8List.fromList([5]);
      store.commit([
        PutOp(Ns.settings, key, kv),
        AppendLogOp(Ns.fileChunks, 1, log),
      ]);
      kv.fillRange(0, kv.length, 0);
      log.fillRange(0, log.length, 0);
      expect(store.get(Ns.settings, key), [1, 2]);
      expect(store.readLog(Ns.fileChunks, 1), [3, 4]);
    },
  );

  test(
    'blank inspection leaves bootstrap markers unchanged across repeated reads',
    () async {
      final storage = FakeHvContainer().storage();
      expect(
        await storage.open(password: 'synthetic', createIfMissing: true),
        isTrue,
      );
      try {
        expect(await storage.initializationIsBlank(), isTrue);
        expect(await storage.initializationIsBlank(), isTrue);
      } finally {
        await storage.close();
      }
    },
  );

  test(
    'read-only replay inspection must not mutate borrowed log payloads',
    () async {
      final storage = FakeHvContainer().storage();
      expect(
        await storage.open(password: 'synthetic', createIfMissing: true),
        isTrue,
      );
      final keys = await storage.exportSpaceKeys();
      final intent = IdentitySetupIntent.create(
        root: const LegacyStorageLocator(),
        keys: keys,
        mode: StorageMode.hiddenSpace,
        persistLegacyMode: false,
        credential: Uint8List.fromList([1, 2, 3]),
      );
      try {
        await IdentitySetupJournal.save(storage, intent, () {});
        final before = await storage.loadFile(kIdentitySetupJournalFile);
        final credential = await storage.loadFile(kIdentitySetupCredentialFile);
        await IdentitySetupJournal.validate(
          storage,
          intent,
          const LegacyStorageLocator(),
          keys,
          () {},
        );
        expect(await storage.loadFile(kIdentitySetupJournalFile), before);
        expect(
          await storage.loadFile(kIdentitySetupCredentialFile),
          credential,
        );
        expect(await storage.loadFile(kSovereignBundleSetting), isNull);
        before?.fillRange(0, before.length, 0);
        credential?.fillRange(0, credential.length, 0);
      } finally {
        intent.destroy();
        keys.fillRange(0, keys.length, 0);
        await storage.close();
      }
    },
  );
}
