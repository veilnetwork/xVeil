import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/managed_encrypted_kv_log_store.dart';
import 'package:xveil/data/storage/managed_identity_catalog.dart';
import 'package:xveil/data/storage/managed_keybox.dart';

class ManagedFixtureFailure implements Exception {}

class TrackedManagedNative extends HvKvLogStore {
  TrackedManagedNative(super.space);
  bool closed = false;
  bool failClose = false;
  bool failHeadBefore = false;
  bool failHeadAfter = false;
  String? stagedWarning;
  int closeCalls = 0;
  int commitCalls = 0;

  @override
  int commit(List<KvLogOp> ops) {
    commitCalls++;
    final head = ops.any(
      (op) => op is AppendLogOp && op.namespace == 255 && op.logId == 1,
    );
    if (head && failHeadBefore) {
      failHeadBefore = false;
      throw ManagedFixtureFailure();
    }
    final result = super.commit(ops);
    if (head && failHeadAfter) {
      failHeadAfter = false;
      throw ManagedFixtureFailure();
    }
    return result;
  }

  @override
  String? hardeningWarning() => stagedWarning ?? super.hardeningWarning();
  @override
  void acknowledgeHardeningWarning() {
    super.acknowledgeHardeningWarning();
    stagedWarning = null;
  }

  @override
  void close() {
    if (closed) return;
    closeCalls++;
    if (failClose) {
      failClose = false;
      throw ManagedFixtureFailure();
    }
    super.close();
    closed = true;
  }
}

typedef ManagedFixtureSpaces = ({
  ManagedKeybox keybox,
  TrackedManagedNative content,
  TrackedManagedNative maintenance,
});

/// Synthetic test directory only; this is NOT production path admission.
class ManagedStoreFixture {
  ManagedStoreFixture._(this.root, this.identity);
  final Directory root;
  final ManagedIdentityId identity;
  final password = Uint8List.fromList(utf8.encode('managed-fixture-password'));
  final tracked = <TrackedManagedNative>[];
  Uint8List? keys;

  static Future<ManagedStoreFixture> create({
    String id = '11111111111111111111111111111111',
  }) async {
    final fixture = ManagedStoreFixture._(
      await Directory.systemTemp.createTemp('xveil-managed-port-'),
      ManagedIdentityId(id),
    );
    addTearDown(fixture.dispose);
    return fixture;
  }

  TrackedManagedNative _native(
    String name, {
    required Uint8List password,
    bool create = false,
    Uint8List? keys,
  }) {
    final path = '${root.path}/$name.hv';
    final space = create
        ? hv.HvSpace.create(
            path: path,
            password: password,
            argon: hv.ArgonPreset.min,
          )
        : keys != null
        ? hv.HvSpace.openWithKeys(path: path, keys: keys)
        : hv.HvSpace.open(path: path, password: password);
    if (!create) space.cancelDeferredVacuum();
    space.setPaddingPolicy(hv.PaddingPreset.none);
    final result = TrackedManagedNative(space);
    tracked.add(result);
    return result;
  }

  ManagedFixtureSpaces spaces({
    bool create = false,
    Uint8List? withPassword,
    Uint8List? withKeys,
  }) {
    if (withPassword != null && withKeys != null) {
      throw ArgumentError('Choose fixture password or keys');
    }
    final rawBox = _native(
      'keybox',
      password: withPassword ?? password,
      create: create,
      keys: create || withPassword != null ? null : withKeys ?? keys,
    );
    final box = create
        ? ManagedKeybox.initializeNew(rawBox, identity: identity)
        : ManagedKeybox.openOwned(rawBox, identity: identity);
    if (create) keys = box.exportKeys();
    final contentPassword = box.copyContentPassword();
    final maintenancePassword = box.copyMaintenancePassword();
    TrackedManagedNative? content;
    TrackedManagedNative? maintenance;
    var success = false;
    try {
      content = _native('content', password: contentPassword, create: create);
      maintenance = _native(
        'maintenance',
        password: maintenancePassword,
        create: create,
      );
      success = true;
      return (keybox: box, content: content, maintenance: maintenance);
    } finally {
      contentPassword.fillRange(0, contentPassword.length, 0);
      maintenancePassword.fillRange(0, maintenancePassword.length, 0);
      if (!success) {
        content?.close();
        maintenance?.close();
        box.close();
      }
    }
  }

  ManagedEncryptedKvLogStore initialize({Uint8List? withPassword}) {
    final owned = spaces(create: true, withPassword: withPassword);
    return ManagedEncryptedKvLogStore.initializeOwned(
      keybox: owned.keybox,
      content: owned.content,
      maintenance: owned.maintenance,
    );
  }

  ManagedEncryptedKvLogStore open({
    Uint8List? withPassword,
    Uint8List? withKeys,
  }) {
    final owned = spaces(withPassword: withPassword, withKeys: withKeys);
    return ManagedEncryptedKvLogStore.openOwned(
      keybox: owned.keybox,
      content: owned.content,
      maintenance: owned.maintenance,
    );
  }

  Future<void> dispose() async {
    // The controlled close fault fires once. Still refuse a green cleanup if
    // any owned native lock could not be released on the second attempt.
    for (var attempt = 0; attempt < 2; attempt++) {
      for (final handle in tracked.reversed) {
        try {
          handle.close();
        } catch (_) {}
      }
    }
    if (tracked.any((handle) => !handle.closed)) {
      throw StateError('Managed fixture close incomplete');
    }
    keys?.fillRange(0, keys!.length, 0);
    password.fillRange(0, password.length, 0);
    await root.delete(recursive: true);
  }
}
