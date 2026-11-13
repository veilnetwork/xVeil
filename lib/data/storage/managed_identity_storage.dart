import 'dart:io';
import 'dart:typed_data';

import '../../domain/storage_protection.dart';
import 'async_kv_log_store.dart';
import 'hidden_volume_storage.dart';
import 'managed_identity_catalog.dart';
import 'managed_reclaim_budget.dart';

/// Binds the application's domain mapping and large-file tier to ONE visible
/// identity. Neither password nor key failures probe another locator or mode.
/// The location carries no hidden-space information and is immutable for the
/// lifetime of this facade; switching requires closing it and choosing another.
final class ManagedIdentityStorage {
  ManagedIdentityStorage.existing({
    required String profileDirectory,
    required this.entry,
  }) : _profile = _profilePath(profileDirectory),
       _creationPending = false {
    _bind();
  }

  /// Only an explicit `storage.open(createIfMissing: true)` creates this ID.
  /// Existing files/catalog entries are refused, not adopted or overwritten.
  /// After successful creation, this same facade can reopen the existing ID.
  ManagedIdentityStorage.forCreation({
    required String profileDirectory,
    required this.entry,
  }) : _profile = _profilePath(profileDirectory),
       _creationPending = true {
    _bind();
  }

  static String _profilePath(String path) =>
      Directory(path).absolute.uri.normalizePath().toFilePath();

  final String _profile;
  final ManagedIdentityEntry entry;
  bool _creationPending;
  bool _opening = false;
  WorkerKvLogStore? _worker;

  /// Existing message, file, ratchet and durable-outbox domain behavior. This
  /// facade owns its worker, and preserves a failed-close owner for retry.
  late final HiddenVolumeStorage storage;

  void _bind() {
    storage = HiddenVolumeStorage.async(_open, keysOpener: _openKeys)
      ..useOnDiskTier(
        Directory(ManagedIdentityLayout(_profile).blobDirectory(entry.id)),
      );
  }

  Future<WorkerKvLogStore?> _openingWorker(
    Future<WorkerKvLogStore> Function() action,
  ) async {
    if (_opening) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.busy);
    }
    _opening = true;
    try {
      final worker = await action();
      _worker = worker;
      return worker;
    } on ManagedWorkerFailure catch (error) {
      // Only actual authentication refusal means "wrong credential" to the
      // domain port. Missing/corrupt data, wrong mode and cleanup failures are
      // errors, not permission to create a replacement or try plaintext.
      if (error.kind == ManagedWorkerFailureKind.authentication) return null;
      rethrow;
    } finally {
      _opening = false;
    }
  }

  Future<WorkerKvLogStore?> _open({
    required Uint8List password,
    required bool create,
  }) async {
    // HiddenVolumeStorage created this UTF-8 buffer for this opener; workers
    // take their own snapshot. Wipe this owned copy after every outcome.
    try {
      if (create != _creationPending) {
        throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
      }
      final created = _creationPending;
      final worker = await _openingWorker(() {
        if (created) {
          return entry.protection == StorageProtection.encrypted
              ? ManagedWorkerIdentity.createEncrypted(
                  profileDirectory: _profile,
                  id: entry.id,
                  password: password,
                )
              : ManagedWorkerIdentity.createUnencrypted(
                  profileDirectory: _profile,
                  id: entry.id,
                );
        }
        return entry.protection == StorageProtection.encrypted
            ? ManagedWorkerIdentity.openEncrypted(
                profileDirectory: _profile,
                id: entry.id,
                password: password,
              )
            : ManagedWorkerIdentity.openUnencrypted(
                profileDirectory: _profile,
                id: entry.id,
              );
      });
      if (worker != null && created) _creationPending = false;
      return worker;
    } finally {
      password.fillRange(0, password.length, 0);
    }
  }

  Future<WorkerKvLogStore?> _openKeys(Uint8List keys) {
    if (_creationPending) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.mode);
    }
    // Keys are borrowed from a roster/vault. The worker snapshots them; never
    // wipe or retain the caller's buffer here.
    return _openingWorker(
      () => ManagedWorkerIdentity.openWithKeys(
        profileDirectory: _profile,
        id: entry.id,
        protection: entry.protection,
        keys: keys,
      ),
    );
  }

  Future<ManagedReclaimReport> reclaim({bool force = false}) {
    final worker = _worker;
    if (!storage.isOpen || worker == null) {
      throw const ManagedWorkerFailure(ManagedWorkerFailureKind.closed);
    }
    return ManagedWorkerIdentity.reclaim(worker, force: force);
  }
}
