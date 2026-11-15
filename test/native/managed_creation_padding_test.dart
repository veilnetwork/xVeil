@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_directory_catalog.dart';
import 'package:xveil/data/storage/managed_fs_platform.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_keybox.dart';

void main() {
  for (final role in ['keybox.hv', 'content.hv', 'maintenance.hv']) {
    test('managed $role persists no-padding across a raw native reopen', () {
      expect(ensureHiddenVolumeLoaded(), isTrue);
      final fixture = Directory.systemTemp.createTempSync(
        'xveil-managed-padding-',
      );
      final profile = '${fixture.path}/profile';
      expect(const ManagedFsPlatform().createPrivateDirectory(profile), isTrue);
      final root = ManagedDirectoryCatalog.createOrOpen(profile);
      final password = Uint8List.fromList(
        utf8.encode('synthetic padding fixture'),
      );
      final passwords = <String, Uint8List>{'keybox.hv': password};
      final id = ManagedIdentityId('5' * 32);
      try {
        final store = ManagedIdentityFiles.createEncrypted(
          root,
          id: id,
          password: password,
        );
        final keys = store.exportKeys();
        store.close();
        final space = hv.HvSpace.openWithKeys(
          path: root.layout.keyboxPath(id),
          keys: keys,
        );
        keys.fillRange(0, keys.length, 0);
        space.cancelDeferredVacuum();
        final keybox = ManagedKeybox.openOwned(
          HvKvLogStore(space),
          identity: id,
        );
        try {
          passwords['content.hv'] = keybox.copyContentPassword();
          passwords['maintenance.hv'] = keybox.copyMaintenancePassword();
        } finally {
          keybox.close();
        }
        // Mutate only a disposable copy: the raw reopen deliberately omits the
        // application's session-only padding override, as the native compactor does.
        final copy = File(
          '${root.layout.directory(id)}/$role',
        ).copySync('${fixture.path}/copy.hv');
        final before = copy.lengthSync();
        expect(before, lessThan(128 * 1024));
        final reopened = hv.HvSpace.open(
          path: copy.path,
          password: passwords[role]!,
        );
        reopened.cancelDeferredVacuum();
        final raw = HvKvLogStore(reopened);
        try {
          raw.commit([
            PutOp(230, Uint8List.fromList([1]), Uint8List.fromList([2])),
          ]);
          expect(raw.get(230, Uint8List.fromList([1])), [2]);
        } finally {
          raw.close();
        }
        // One tiny transaction may add index/checkpoint slots, not a 1-MiB
        // concealment bucket. File contents and KDF behavior remain encrypted.
        expect(copy.lengthSync() - before, lessThanOrEqualTo(64 * 1024));
      } finally {
        root.close();
        for (final secret in passwords.values) {
          secret.fillRange(0, secret.length, 0);
        }
        fixture.deleteSync(recursive: true);
      }
    });
  }
}
