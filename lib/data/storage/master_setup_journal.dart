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

enum _MasterRosterState { absent, base, full }

final class _RetiredReceipt {
  const _RetiredReceipt(this.kind, this.attempt);
  final String kind;
  final String? attempt;
}

/// The caller owns exclusive storage/lifecycle admission. The private plan
/// authorizes only exact creation values, never network activation or deletion.
abstract final class MasterSetupJournal {
  /// Authenticate the original opened parent and its exact accepted pending
  /// plan without changing its roster, child or completion state.
  static Future<void> validate({
    required Storage storage,
    required MasterSetupIntent intent,
    required IdentityStorageLocator root,
    required Uint8List keys,
    required void Function() check,
  }) => _request<void>(intent, keys, (owned, ownedKeys, _) async {
    await _authenticate(storage, owned, root, ownedKeys, check);
    final current = await read(storage, check);
    try {
      final marker = await storage.getSetting(kPendingMasterSetupSetting);
      check();
      if (current == null || !current.same(owned) || marker != '1') {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
      await _inspect(storage, owned, check);
    } finally {
      current?.destroy();
    }
  });
  static Uint8List _digest(MasterSetupIntent intent) {
    final bytes = intent.encode();
    try {
      return Uint8List.fromList(sha256.convert(bytes).bytes);
    } finally {
      wipeSecretBytes(bytes);
    }
  }

  static Uint8List _receipt(MasterSetupIntent intent, {bool aborted = false}) {
    final digest = _digest(intent);
    try {
      return Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'v': 1,
            aborted ? 'aborted' : 'complete': true,
            'digest': base64.encode(digest),
            if (intent.attemptId != null) 'attempt': intent.attemptId,
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
    void Function() check, {
    bool aborted = false,
  }) async {
    final receipt = _receipt(intent, aborted: aborted);
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
    List<RosterEntry>? roster;
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
      if (MasterSetupIntent.requiresRoster(bytes)) {
        final copy = Uint8List.fromList(bytes);
        wipeSecretBytes(bytes);
        bytes = copy;
        if (storage is! RosterMaintenanceReader) {
          throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
        }
        roster = await (storage as RosterMaintenanceReader)
            .loadRosterForMaintenance();
        check();
      }
      return MasterSetupIntent.decode(bytes, roster: roster);
    } finally {
      if (bytes != null) wipeSecretBytes(bytes);
      for (final row in roster ?? const <RosterEntry>[]) {
        wipeSecretBytes(row.spaceKeys);
      }
    }
  }

  static Future<_RetiredReceipt?> _retiredStatus(
    Storage storage,
    void Function() check,
  ) async {
    Uint8List? bytes, digest, attempt;
    try {
      bytes = await storage.loadFile(
        kMasterSetupJournalFile,
        maxBytes: MasterSetupIntent.maxBytes,
      );
      check();
      if (bytes == null) {
        if (await storage.hasFile(kMasterSetupJournalFile)) {
          throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
        }
        check();
        return null;
      }
      final m = jsonDecode(utf8.decode(bytes));
      final key = m is Map && m['complete'] == true ? 'complete' : 'aborted';
      final hasAttempt = m is Map && m.containsKey('attempt');
      if (m is! Map ||
          m.length != (hasAttempt ? 4 : 3) ||
          m['v'] is! int ||
          m['v'] != 1 ||
          m[key] != true ||
          m['digest'] is! String ||
          !m.keys.every(
            (k) => {'v', key, 'digest', if (hasAttempt) 'attempt'}.contains(k),
          )) {
        throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
      }
      digest = base64.decode(m['digest'] as String);
      if (digest.length != 32 || base64.encode(digest) != m['digest']) {
        throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
      }
      if (hasAttempt) {
        if (m['attempt'] is! String) {
          throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
        }
        attempt = base64.decode(m['attempt'] as String);
        if (attempt.length != 16 || base64.encode(attempt) != m['attempt']) {
          throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
        }
      }
      return _RetiredReceipt(key, hasAttempt ? m['attempt'] as String : null);
    } on MasterSetupFailure {
      rethrow;
    } catch (_) {
      throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
    } finally {
      if (bytes != null) wipeSecretBytes(bytes);
      if (digest != null) wipeSecretBytes(digest);
      if (attempt != null) wipeSecretBytes(attempt);
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
      owned = intent.copy();
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

  static bool _sameRoster(List<RosterEntry> a, List<RosterEntry> b) =>
      a.length == b.length &&
      List.generate(
        a.length,
        (i) =>
            a[i].label == b[i].label &&
            a[i].anonymous == b[i].anonymous &&
            a[i].storageLocator == b[i].storageLocator &&
            _same(a[i].spaceKeys, b[i].spaceKeys),
      ).every((v) => v);

  static Future<_MasterRosterState> _inspect(
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
    if (!intent.append &&
        (storage is! MasterSetupInspectionSource ||
            !await (storage as MasterSetupInspectionSource)
                .masterSetupHasOnlyBootstrapData())) {
      throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
    }
    check();
    if (storage is! RosterMaintenanceReader) {
      throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
    }
    List<RosterEntry>? rows, expected, base;
    try {
      rows = await (storage as RosterMaintenanceReader)
          .loadRosterForMaintenance();
      check();
      if (rows == null && !intent.append) return _MasterRosterState.absent;
      if (rows != null && intent.append) {
        base = intent.copyBase();
        if (_sameRoster(rows, base)) return _MasterRosterState.base;
      }
      if (rows != null && intent.childKnown) {
        expected = intent.copyRoster();
        if (_sameRoster(rows, expected)) return _MasterRosterState.full;
      }
      throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
    } finally {
      for (final row in [...?rows, ...?expected, ...?base]) {
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
    MasterSetupIntent? current;
    try {
      final stage = await storage.getSetting(kPendingMasterSetupSetting);
      check();
      if (stage == '1') {
        current = await read(storage, check);
        if (current == null || !current.same(owned)) {
          throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
        }
        await _inspect(storage, owned, check);
        return;
      }
      if (masterSetupIsPending(stage)) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
      if (owned.attemptId == null) {
        throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
      }
      final retired = await _retiredStatus(storage, check);
      if (retired != null &&
          (stage != '0' ||
              !owned.append && retired.kind != 'aborted' ||
              retired.attempt == owned.attemptId)) {
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

  /// A definitive rejected candidate has received no personalized writes or
  /// attached key. Retire only that exact prepared obligation, preserving the
  /// existing roster and every child. Never abort an advanced transaction.
  static Future<void> abortPrepared({
    required Storage storage,
    required MasterSetupIntent intent,
    required IdentityStorageLocator root,
    required Uint8List keys,
    required void Function() check,
  }) => _request<void>(intent, keys, (owned, ownedKeys, _) async {
    await _authenticate(storage, owned, root, ownedKeys, check);
    if (owned.childKnown) {
      throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
    }
    if (await _completed(storage, owned, check, aborted: true)) return;
    final current = await read(storage, check);
    try {
      final stage = await storage.getSetting(kPendingMasterSetupSetting);
      check();
      if (stage != '1' || current == null || !current.same(owned)) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
      final state = await _inspect(storage, owned, check);
      if (state !=
              (owned.append
                  ? _MasterRosterState.base
                  : _MasterRosterState.absent) ||
          storage is! StoredFileSettingWriter) {
        throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
      }
      final receipt = _receipt(owned, aborted: true);
      try {
        check();
        await (storage as StoredFileSettingWriter).storeFileWithSetting(
          StoredFileWrite(kMasterSetupJournalFile, receipt),
          settingKey: kPendingMasterSetupSetting,
          settingValue: '0',
        );
        check();
        if (!await _completed(storage, owned, check, aborted: true)) {
          throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
        }
      } finally {
        wipeSecretBytes(receipt);
      }
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
      final state = await _inspect(storage, owned, check);
      if (storage is! StoredFileSettingWriter) {
        throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
      }
      if (state != _MasterRosterState.full) {
        final rows = owned.copyRoster();
        try {
          await storage.saveRoster(rows);
          check();
        } finally {
          for (final row in rows) {
            wipeSecretBytes(row.spaceKeys);
          }
        }
      }
      if (await _inspect(storage, owned, check) != _MasterRosterState.full) {
        throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
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
