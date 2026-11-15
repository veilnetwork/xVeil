import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/secret_wipe.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/master_setup_intent.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/storage_locator.dart';
import 'package:xveil/domain/storage_protection.dart';

class MasterSetupFixture {
  MasterSetupFixture(this.directory, this.mode);
  final Directory directory;
  final StorageProtection mode;
  String get profile => '${directory.path}/visible-storage';
  String get legacy => '${directory.path}/legacy.hv';
  ManagedIdentityId id(String n) => ManagedIdentityId(n * 32);
  IdentityStorageLocator get root => mode == StorageProtection.hidden
      ? const LegacyStorageLocator()
      : ManagedStorageLocator(id: id('a'), protection: mode);
  ManagedStorageLocator get child => ManagedStorageLocator(
    id: id('b'),
    protection: StorageProtection.encrypted,
  );
  Uint8List get password =>
      Uint8List.fromList(utf8.encode('synthetic master password'));

  KvLogStore openRoot(ManagedDirectoryCatalog owner) => switch (mode) {
    StorageProtection.hidden => HvKvLogStore(
      hv.HvSpace.open(path: legacy, password: password),
    ),
    StorageProtection.encrypted => ManagedIdentityFiles.openWithPassword(
      owner,
      id: id('a'),
      password: password,
    ),
    StorageProtection.unencrypted => ManagedIdentityFiles.openUnencrypted(
      owner,
      id: id('a'),
    ),
  };

  Future<void> create() async {
    const fs = ManagedFsPlatform();
    if (!fs.createPrivateDirectory(profile)) {
      throw StateError('fixture profile admission failed');
    }
    final owner = ManagedDirectoryCatalog.createOrOpen(profile);
    Uint8List? original, keys, bytes;
    MasterSetupIntent? intent;
    try {
      final source = HiddenVolumeStorage.fromStore(
        ManagedIdentityFiles.createUnencrypted(owner, id: id('c')),
      );
      try {
        await source.saveProfile(
          const UserProfile(displayName: 'original identity'),
        );
        await source.putSetting('fixture', 'original payload');
        original = await source.exportSpaceKeys();
      } finally {
        await source.close();
      }
      final KvLogStore raw = switch (mode) {
        StorageProtection.hidden => HvKvLogStore(
          hv.HvSpace.create(
            path: legacy,
            password: password,
            argon: hv.ArgonPreset.min,
            padding: hv.PaddingPreset.none,
          ),
        ),
        StorageProtection.encrypted => ManagedIdentityFiles.createEncrypted(
          owner,
          id: id('a'),
          password: password,
        ),
        StorageProtection.unencrypted => ManagedIdentityFiles.createUnencrypted(
          owner,
          id: id('a'),
        ),
      };
      keys = raw.exportKeys();
      raw.close();
      intent = MasterSetupIntent.create(
        root: root,
        keys: keys,
        base: [
          RosterEntry(
            label: 'original identity',
            spaceKeys: original,
            storageLocator: ManagedStorageLocator(
              id: id('c'),
              protection: StorageProtection.unencrypted,
            ),
          ),
        ],
        childLocator: child,
        childLabel: 'new child',
        childAnonymous: true,
      );
      bytes = intent.encode();
      final file = File('${directory.path}/request-private.json')
        ..createSync(exclusive: true);
      fs.restrictNewFile(file.path);
      file.writeAsStringSync(
        jsonEncode({
          'keys': base64.encode(keys),
          'intent': base64.encode(bytes),
        }),
        flush: true,
      );
    } finally {
      intent?.destroy();
      for (final b in [original, keys, bytes]) {
        if (b != null) wipeSecretBytes(b);
      }
      owner.close();
    }
  }
}
