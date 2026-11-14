import 'dart:typed_data';

import '../../core/secret_wipe.dart';
import '../../domain/identity_setup_intent.dart';
import '../../domain/pending_identity_erase.dart';
import '../../domain/storage_initialization.dart';
import '../../domain/storage_locator.dart';
import '../../domain/storage_setup.dart';
import '../node/sovereign_identity_material.dart';
import 'file_store.dart';
import 'storage.dart';

abstract final class IdentitySetupJournal {
  static Future<void> save(
    Storage storage,
    IdentitySetupIntent intent,
    void Function() check,
  ) async {
    final metadata = intent.encode();
    final credential = intent.copyCredential();
    try {
      check();
      // This marker also covers a native failure before atomic publication.
      await storage.putSetting(kPendingIdentitySetupSetting, '1');
      check();
      if (credential != null && storage is StoredFilePairWriter) {
        final published = await (storage as StoredFilePairWriter)
            .tryStoreFilePair(
              StoredFileWrite(kIdentitySetupCredentialFile, credential),
              StoredFileWrite(kIdentitySetupJournalFile, metadata),
            );
        check();
        if (!published) {
          throw const IdentitySetupFailure(
            IdentitySetupFailureKind.unavailable,
          );
        }
      } else {
        if (credential != null) {
          await storage.storeFile(kIdentitySetupCredentialFile, credential);
          check();
        }
        await storage.storeFile(kIdentitySetupJournalFile, metadata);
        check();
      }
      final verified = await read(storage, check);
      try {
        if (verified == null) {
          throw const IdentitySetupFailure(
            IdentitySetupFailureKind.unavailable,
          );
        }
        final bytes = verified.encode();
        try {
          if (!_same(bytes, metadata)) {
            throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
          }
        } finally {
          wipeSecretBytes(bytes);
        }
      } finally {
        verified?.destroy();
      }
    } finally {
      wipeSecretBytes(metadata);
      if (credential != null) wipeSecretBytes(credential);
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var different = 0;
    for (var i = 0; i < a.length; i++) {
      different |= a[i] ^ b[i];
    }
    return different == 0;
  }

  /// Caller owns the returned intent. Every native result is adopted before
  /// cancellation checks, so a late reply cannot strand its credential bytes.
  static Future<IdentitySetupIntent?> read(
    Storage storage,
    void Function() check,
  ) async {
    Uint8List? bytes, credential;
    IdentitySetupIntent? intent;
    var adopted = false;
    try {
      bytes = await storage.loadFile(
        kIdentitySetupJournalFile,
        maxBytes: IdentitySetupIntent.maxMetadataBytes,
      );
      check();
      if (bytes == null) {
        final exists = await storage.hasFile(kIdentitySetupJournalFile);
        check();
        if (exists) {
          throw const IdentitySetupFailure(IdentitySetupFailureKind.invalid);
        }
        return null;
      }
      intent = IdentitySetupIntent.decode(bytes);
      if (intent.credentialLength != null) {
        credential = await storage.loadFile(
          kIdentitySetupCredentialFile,
          maxBytes: IdentitySetupIntent.maxCredentialBytes,
        );
        check();
        if (credential == null) {
          throw const IdentitySetupFailure(IdentitySetupFailureKind.invalid);
        }
        intent.attachCredential(credential);
      }
      adopted = true;
      return intent;
    } finally {
      if (bytes != null) wipeSecretBytes(bytes);
      if (credential != null) wipeSecretBytes(credential);
      if (!adopted) intent?.destroy();
    }
  }

  /// No payload is overwritten merely because a journal exists. The exact
  /// root/key witness and every already accepted onboarding value must agree.
  static Future<void> validate(
    Storage storage,
    IdentitySetupIntent intent,
    IdentityStorageLocator root,
    Uint8List keys,
    void Function() check, {
    bool payloadComplete = false,
  }) async {
    check();
    intent.validate(root, keys);
    final stage = await storage.getSetting(kPendingIdentitySetupSetting);
    check();
    if (stage != (payloadComplete ? '2' : '1')) {
      throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
    }
    if (!intent.complete) {
      throw const IdentitySetupFailure(IdentitySetupFailureKind.invalid);
    }
    final roster = await storage.loadRoster();
    try {
      check();
      if (roster != null) {
        throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
      }
    } finally {
      if (roster != null) {
        for (final row in roster) {
          wipeSecretBytes(row.spaceKeys);
        }
      }
    }
    for (final key in [kPendingMasterSetupSetting, kPendingIdentityErase]) {
      final value = await storage.getSetting(key);
      check();
      if (value != null && value.isNotEmpty && value != '0') {
        throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
      }
    }
    final profile = await storage.loadProfile();
    check();
    if (payloadComplete && profile == null ||
        profile != null &&
            (profile.displayName != intent.displayName ||
                profile.username != null)) {
      throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
    }
    final config = await storage.loadNodeConfig();
    check();
    if (payloadComplete && intent.nodeConfig != null && config == null ||
        config != null &&
            config != intent.nodeConfig &&
            (!payloadComplete || intent.nodeConfig != null)) {
      throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
    }
    final held = await readSovereignCredential(storage);
    try {
      check();
      if (held.corrupt ||
          payloadComplete &&
              intent.credentialLength != null &&
              held.bundle == null ||
          held.bundle != null && !intent.matchesCredential(held.bundle!)) {
        throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
      }
    } finally {
      if (held.bundle != null) wipeSecretBytes(held.bundle!);
    }
    final saved = await storage.getSetting(kRecoveryCertificateSavedSetting);
    check();
    if (payloadComplete && intent.certificateSaved && saved != '1' ||
        saved != null && saved != (intent.certificateSaved ? '1' : '0')) {
      throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
    }
    if (!payloadComplete &&
        (storage is! StorageSetupInspectionSource ||
            !await (storage as StorageSetupInspectionSource)
                .setupHasOnlyBootstrapData(
                  files: {
                    kIdentitySetupJournalFile,
                    if (intent.credentialLength != null) ...[
                      kIdentitySetupCredentialFile,
                      kSovereignBundleSetting,
                    ],
                  },
                  settings: {kRecoveryCertificateSavedSetting},
                ))) {
      throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
    }
    check();
  }

  /// A lost cleanup reply does not authorize deleting the only remaining
  /// certificate copy. Inspect the completed payload before retiring staging.
  static Future<void> cleanupCompleted(
    Storage storage,
    IdentityStorageLocator root,
    Uint8List keys,
    void Function() check,
  ) async {
    Uint8List? bytes;
    IdentitySetupIntent? intent;
    try {
      bytes = await storage.loadFile(
        kIdentitySetupJournalFile,
        maxBytes: IdentitySetupIntent.maxMetadataBytes,
      );
      check();
      if (bytes == null) {
        throw const IdentitySetupFailure(IdentitySetupFailureKind.unavailable);
      }
      intent = IdentitySetupIntent.decode(bytes);
      intent.validate(root, keys);
      if (await storage.getSetting(kPendingIdentitySetupSetting) != '0') {
        throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
      }
      check();
      final profile = await storage.loadProfile();
      check();
      if (profile == null) {
        throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
      }
      if (intent.nodeConfig != null) {
        final config = await storage.loadNodeConfig();
        check();
        if (config != intent.nodeConfig) {
          throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
        }
      }
      if (intent.credentialLength != null) {
        final held = await readSovereignCredential(storage);
        try {
          check();
          if (held.corrupt ||
              held.bundle == null ||
              !intent.matchesCredential(held.bundle!)) {
            throw const IdentitySetupFailure(IdentitySetupFailureKind.conflict);
          }
        } finally {
          if (held.bundle != null) wipeSecretBytes(held.bundle!);
        }
      }
      await cleanup(storage, check);
    } finally {
      if (bytes != null) wipeSecretBytes(bytes);
      intent?.destroy();
    }
  }

  /// Only after pending=0: a crash in cleanup must not strand an otherwise
  /// complete identity. A later cold entry may retry these exact reserved IDs.
  static Future<void> cleanup(Storage storage, void Function() check) async {
    for (final file in [
      kIdentitySetupCredentialFile,
      kIdentitySetupJournalFile,
    ]) {
      check();
      await storage.deleteStoredFile(file);
      check();
    }
  }
}
