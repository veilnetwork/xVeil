import 'dart:typed_data';

import '../../core/secret_wipe.dart';
import '../../domain/master_setup_intent.dart';
import '../../domain/pending_identity_erase.dart';
import '../../domain/roster.dart';
import '../../domain/storage_initialization.dart';
import '../../domain/storage_locator.dart';
import '../../domain/storage_setup.dart';
import '../node/sovereign_identity_material.dart';
import 'file_store.dart';
import 'storage.dart';

/// Preparation only: no child/profile/roster writes, activation, discovery or
/// deletion authority. Application recovery must authenticate its exact root,
/// reconcile the planned child and finish the separate publication protocol.
abstract final class MasterSetupJournal {
  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Future<MasterSetupIntent?> read(
    Storage storage,
    void Function() check,
  ) async {
    Uint8List? bytes;
    try {
      bytes = await storage.loadFile(
        kMasterSetupJournalFile,
        maxBytes: MasterSetupIntent.maxBytes,
      );
      check();
      if (bytes == null) {
        final exists = await storage.hasFile(kMasterSetupJournalFile);
        check();
        if (exists) {
          throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
        }
        return null;
      }
      return MasterSetupIntent.decode(bytes);
    } finally {
      if (bytes != null) wipeSecretBytes(bytes);
    }
  }

  /// Snapshot and own every sensitive request buffer before the first await.
  static Future<T> _request<T>(
    MasterSetupIntent intent,
    Uint8List keys,
    Future<T> Function(MasterSetupIntent, Uint8List, Uint8List) action,
  ) async {
    Uint8List? bytes, ownedKeys;
    MasterSetupIntent? owned;
    try {
      bytes = intent.encode();
      ownedKeys = Uint8List.fromList(keys);
      owned = MasterSetupIntent.decode(bytes);
      return await action(owned, ownedKeys, bytes);
    } on MasterSetupFailure {
      rethrow;
    } catch (_) {
      throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
    } finally {
      owned?.destroy();
      if (ownedKeys != null) wipeSecretBytes(ownedKeys);
      if (bytes != null) wipeSecretBytes(bytes);
    }
  }

  static Future<void> _authenticate(
    Storage storage,
    MasterSetupIntent intent,
    IdentityStorageLocator root,
    Uint8List keys,
    void Function() check,
  ) async {
    check();
    intent.validateOwner(root, keys);
    final actual = await storage.exportSpaceKeys();
    try {
      check();
      if (!_same(actual, keys)) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
    } finally {
      wipeSecretBytes(actual);
    }
  }

  static Future<void> _inspect(
    Storage storage,
    MasterSetupIntent intent,
    void Function() check,
  ) async {
    final profile = await storage.loadProfile();
    check();
    if (profile != null) {
      throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
    }
    final config = await storage.loadNodeConfig();
    check();
    if (config != null) {
      throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
    }
    final credential = await readSovereignCredential(storage);
    try {
      check();
      if (credential.corrupt || credential.bundle != null) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
    } finally {
      if (credential.bundle != null) wipeSecretBytes(credential.bundle!);
    }
    for (final key in [kPendingIdentitySetupSetting, kPendingIdentityErase]) {
      final stage = await storage.getSetting(key);
      check();
      if (stage != null && stage.isNotEmpty && stage != '0') {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
    }
    if (storage is! MasterSetupInspectionSource ||
        !await (storage as MasterSetupInspectionSource)
            .masterSetupHasOnlyBootstrapData()) {
      throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
    }
    check();
    if (storage is! RosterMaintenanceReader) {
      throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
    }
    List<RosterEntry>? rows, expected;
    try {
      rows = await (storage as RosterMaintenanceReader)
          .loadRosterForMaintenance();
      check();
      if (rows == null) return;
      if (!intent.childKnown) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
      expected = intent.copyRoster();
      if (rows.length != expected.length ||
          !List.generate(
            rows.length,
            (i) =>
                rows![i].label == expected![i].label &&
                rows[i].anonymous == expected[i].anonymous &&
                rows[i].storageLocator == expected[i].storageLocator &&
                _same(rows[i].spaceKeys, expected[i].spaceKeys),
          ).every((v) => v)) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
    } finally {
      for (final row in [...?rows, ...?expected]) {
        wipeSecretBytes(row.spaceKeys);
      }
    }
  }

  static Future<MasterSetupIntent> _readBack(
    Storage storage,
    MasterSetupIntent expected,
    void Function() check,
  ) async {
    MasterSetupIntent? result;
    var adopted = false;
    try {
      result = await read(storage, check);
      if (result == null ||
          !result.same(expected) ||
          await storage.getSetting(kPendingMasterSetupSetting) != '1') {
        throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
      }
      check();
      adopted = true;
      return result;
    } finally {
      if (!adopted) result?.destroy();
    }
  }

  /// Atomic private intent + pending marker. Unsupported writers never get a
  /// sequential fallback. Retry accepts only the exact already published intent.
  static Future<void> prepare({
    required Storage storage,
    required MasterSetupIntent intent,
    required IdentityStorageLocator root,
    required Uint8List keys,
    required void Function() check,
  }) => _request<void>(intent, keys, (owned, ownedKeys, bytes) async {
    await _authenticate(storage, owned, root, ownedKeys, check);
    if (owned.childKnown) {
      throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
    }
    final current = await read(storage, check);
    try {
      final stage = await storage.getSetting(kPendingMasterSetupSetting);
      check();
      if (current != null) {
        if (!current.same(owned) || stage != '1') {
          throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
        }
        await _inspect(storage, owned, check);
        return;
      }
      if (masterSetupIsPending(stage)) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
      await _inspect(storage, owned, check);
      if (storage is! StoredFileSettingWriter) {
        throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
      }
      check();
      await (storage as StoredFileSettingWriter).storeFileWithSetting(
        StoredFileWrite(kMasterSetupJournalFile, bytes),
        settingKey: kPendingMasterSetupSetting,
        settingValue: '1',
      );
      check();
      final verified = await _readBack(storage, owned, check);
      verified.destroy();
    } finally {
      current?.destroy();
    }
  });

  /// Add only the planned child's keys, once. Never accepts a changed source
  /// roster, locator, label, anonymity or a second, different child key.
  /// Caller owns the returned independently read-back intent.
  static Future<MasterSetupIntent> attachChild({
    required Storage storage,
    required MasterSetupIntent intent,
    required Uint8List childKeys,
    required IdentityStorageLocator root,
    required Uint8List keys,
    required void Function() check,
  }) {
    final next = intent.withChildKeys(childKeys);
    final result = _request<MasterSetupIntent>(next, keys, (
      owned,
      ownedKeys,
      bytes,
    ) async {
      await _authenticate(storage, owned, root, ownedKeys, check);
      final current = await read(storage, check);
      try {
        if (current == null ||
            !current.same(owned, planOnly: true) ||
            current.childKnown && !current.same(owned) ||
            await storage.getSetting(kPendingMasterSetupSetting) != '1') {
          throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
        }
        check();
        await _inspect(storage, owned, check);
        if (current.childKnown) return _readBack(storage, owned, check);
        if (storage is! StoredFileSettingWriter) {
          throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
        }
        check();
        await (storage as StoredFileSettingWriter).storeFileWithSetting(
          StoredFileWrite(kMasterSetupJournalFile, bytes),
          settingKey: kPendingMasterSetupSetting,
          settingValue: '1',
        );
        check();
        return _readBack(storage, owned, check);
      } finally {
        current?.destroy();
      }
    });
    // _request snapshots synchronously before its first await.
    next.destroy();
    return result;
  }
}
