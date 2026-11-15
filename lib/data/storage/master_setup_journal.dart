import 'dart:typed_data';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/secret_wipe.dart';
import '../../domain/master_setup_intent.dart';
import '../../domain/identity.dart';
import '../../domain/pending_identity_erase.dart';
import '../../domain/roster.dart';
import '../../domain/storage_initialization.dart';
import '../../domain/storage_locator.dart';
import '../../domain/storage_setup.dart';
import '../node/sovereign_identity_material.dart';
import 'file_store.dart';
import 'storage.dart';

/// An in-memory witness issued only after checking the opened planned child.
/// It carries a plan digest, not keys or a password. The caller must retain
/// exclusive lifetime ownership between child validation and master commit.
final class MasterSetupChildProof {
  MasterSetupChildProof._(this._digest);
  final List<int> _digest;
}

/// The caller owns exclusive storage/lifecycle admission. The private plan
/// authorizes only exact creation values, never network activation or deletion.
abstract final class MasterSetupJournal {
  static Uint8List _digest(MasterSetupIntent intent) {
    final bytes = intent.encode();
    try {
      return Uint8List.fromList(sha256.convert(bytes).bytes);
    } finally {
      wipeSecretBytes(bytes);
    }
  }

  static Uint8List _receipt(MasterSetupIntent intent) {
    final digest = _digest(intent);
    try {
      return Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'v': 1,
            'complete': true,
            'digest': base64.encode(digest),
          }),
        ),
      );
    } finally {
      wipeSecretBytes(digest);
    }
  }

  /// A receipt is deliberately not a replayable intent: it has no labels,
  /// locators, source keys or child keys. Exact byte equality also prevents an
  /// arbitrary malformed JSON object from being treated as a completed retry.
  static Future<bool> _completed(
    Storage storage,
    MasterSetupIntent intent,
    void Function() check,
  ) async {
    final receipt = _receipt(intent);
    Uint8List? bytes;
    try {
      bytes = await storage.loadFile(
        kMasterSetupJournalFile,
        maxBytes: MasterSetupIntent.maxBytes,
      );
      check();
      if (bytes == null || !_same(bytes, receipt)) return false;
      final marker = await storage.getSetting(kPendingMasterSetupSetting);
      check();
      if (marker != '0') {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
      return true;
    } finally {
      wipeSecretBytes(receipt);
      if (bytes != null) wipeSecretBytes(bytes);
    }
  }

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

  /// Initialize only the planned, still-unhosted child's exact profile. A
  /// parent intent must already durably contain its keys. A completed child
  /// may have since acquired newer data: verify it without rewriting payloads.
  static Future<MasterSetupChildProof> initializeChild({
    required Storage storage,
    required MasterSetupIntent intent,
    required IdentityStorageLocator child,
    required Uint8List childKeys,
    required void Function() check,
  }) => _request(intent, childKeys, (owned, keys, _) async {
    if (!owned.childKnown || child != owned.childLocator) {
      throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
    }
    final rows = owned.copyRoster();
    try {
      if (!_same(rows.last.spaceKeys, keys)) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
    } finally {
      for (final row in rows) {
        wipeSecretBytes(row.spaceKeys);
      }
    }
    final actual = await storage.exportSpaceKeys();
    try {
      check();
      if (!_same(actual, keys)) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
    } finally {
      wipeSecretBytes(actual);
    }
    if (storage is! RosterMaintenanceReader) {
      throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
    }
    final existingRows = await (storage as RosterMaintenanceReader)
        .loadRosterForMaintenance();
    try {
      check();
      if (existingRows != null) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
    } finally {
      for (final row in existingRows ?? const <RosterEntry>[]) {
        wipeSecretBytes(row.spaceKeys);
      }
    }
    for (final key in [kPendingMasterSetupSetting, kPendingIdentityErase]) {
      final value = await storage.getSetting(key);
      check();
      if (value != null && value.isNotEmpty && value != '0') {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
    }
    final stage = await storage.getSetting(kPendingIdentitySetupSetting);
    check();
    if (stage != null && stage.isNotEmpty && stage != '1' && stage != '0') {
      throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
    }
    final expected = UserProfile(displayName: owned.childLabel);
    final profile = await storage.loadProfile();
    check();
    if (stage == '0') {
      if (profile == null) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
      // Preserve later renames, credentials, ratchet state and user data after
      // an interrupted parent finish. The recorded key and completion marker
      // permit verification, never replay of the initial payload.
      return MasterSetupChildProof._(List.unmodifiable(_digest(owned)));
    }
    if (profile != null && profile != expected) {
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
    if (storage is! StorageSetupInspectionSource ||
        !await (storage as StorageSetupInspectionSource)
            .setupHasOnlyBootstrapData(
              files: {},
              settings: {kPendingMasterSetupSetting, kPendingIdentityErase},
            )) {
      throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
    }
    check();
    if (stage != '0') {
      if (stage != '1') {
        await storage.putSetting(kPendingIdentitySetupSetting, '1');
        check();
      }
      if (profile == null) {
        await storage.saveProfile(expected);
        check();
      }
      await storage.putSetting(kPendingIdentitySetupSetting, '0');
      check();
    }
    final verifiedProfile = await storage.loadProfile();
    check();
    final verifiedStage = await storage.getSetting(
      kPendingIdentitySetupSetting,
    );
    check();
    if (verifiedProfile != expected || verifiedStage != '0') {
      throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
    }
    return MasterSetupChildProof._(List.unmodifiable(_digest(owned)));
  });

  /// Preserve an absent/exact roster, then atomically replace the secret intent
  /// with a non-replayable receipt and clear pending-master. A lost reply can
  /// be retried, but a completed receipt can never restore a later removed row.
  static Future<void> publishAndFinish({
    required Storage storage,
    required MasterSetupIntent intent,
    required MasterSetupChildProof childProof,
    required IdentityStorageLocator root,
    required Uint8List keys,
    required void Function() check,
  }) => _request<void>(intent, keys, (owned, ownedKeys, _) async {
    await _authenticate(storage, owned, root, ownedKeys, check);
    final digest = _digest(owned);
    try {
      if (!owned.childKnown || !_same(childProof._digest, digest)) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
    } finally {
      wipeSecretBytes(digest);
    }
    if (await _completed(storage, owned, check)) return;
    final current = await read(storage, check);
    try {
      final stage = await storage.getSetting(kPendingMasterSetupSetting);
      check();
      if (current == null || !current.same(owned) || stage != '1') {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
      await _inspect(storage, owned, check);
      if (storage is! StoredFileSettingWriter) {
        throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
      }
      final rows = owned.copyRoster();
      List<RosterEntry>? present;
      try {
        present = await (storage as RosterMaintenanceReader)
            .loadRosterForMaintenance();
        check();
        if (present == null) {
          await storage.saveRoster(rows);
          check();
        }
      } finally {
        for (final row in [...rows, ...?present]) {
          wipeSecretBytes(row.spaceKeys);
        }
      }
      // Strict reread checks every row before crossing the completion barrier.
      await _inspect(storage, owned, check);
      final verified = await (storage as RosterMaintenanceReader)
          .loadRosterForMaintenance();
      try {
        check();
        if (verified == null) {
          throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
        }
      } finally {
        for (final row in verified ?? const <RosterEntry>[]) {
          wipeSecretBytes(row.spaceKeys);
        }
      }
      final receipt = _receipt(owned);
      try {
        check();
        await (storage as StoredFileSettingWriter).storeFileWithSetting(
          StoredFileWrite(kMasterSetupJournalFile, receipt),
          settingKey: kPendingMasterSetupSetting,
          settingValue: '0',
        );
        check();
        if (!await _completed(storage, owned, check)) {
          throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
        }
      } finally {
        wipeSecretBytes(receipt);
      }
    } finally {
      current?.destroy();
    }
  });
}
