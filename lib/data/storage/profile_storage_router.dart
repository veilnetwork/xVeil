import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'legacy_compaction_source.dart';

import '../../domain/identity_erase_review.dart';
import '../../domain/storage_locator.dart';
import '../../domain/storage_protection.dart';
import 'async_kv_log_store.dart';
import 'managed_directory_catalog.dart';
import 'managed_identity_catalog.dart';
import 'managed_identity_storage.dart';
import 'storage.dart';

typedef ProfileIdentityStorageFactory =
    Storage Function(IdentityStorageLocator locator, bool create);

/// Owns immutable facades across selections; old asynchronous work keeps its
/// old facade and can never be redirected into a newly selected identity.
final class ProfileStorageRouter {
  ProfileStorageRouter._(
    this.profileDirectory,
    this._catalog,
    this._factory,
    this.legacySourceName,
  );
  final String profileDirectory;
  final String legacySourceName;
  final ManagedCatalogWorker _catalog;
  final ProfileIdentityStorageFactory _factory;
  final _retiredStores = <Storage>{};
  static final _retiredRouters = <ProfileStorageRouter>{};
  Future<void> _tail = Future.value();
  Future<void>? _closingJob;
  bool _closing = false, _closed = false;
  int _epoch = 0;
  Storage? _storage;
  IdentityStorageLocator _location = const LegacyStorageLocator();
  IdentityStorageLocator _access = const LegacyStorageLocator();
  bool _selectionRequired = false;
  ManagedIdentityCatalog _snapshot = ManagedIdentityCatalog([]);

  Storage get storage =>
      _storage ?? (throw StateError('storage selection is unavailable'));
  IdentityStorageLocator get location => _location;
  IdentityStorageLocator get access => _access;
  bool get selectionRequired => _selectionRequired;
  ManagedIdentityCatalog get catalog => _snapshot;
  void cancelSelections() => _epoch++;

  static Future<ProfileStorageRouter> open({
    required String profileDirectory,
    required Storage Function() legacyFactory,
    String? legacyPath,
    ProfileIdentityStorageFactory? storageFactory,
  }) async {
    profileDirectory = Directory(
      profileDirectory,
    ).absolute.uri.normalizePath().toFilePath();
    final sourceName = legacyPath == null
        ? LegacyCompactionSource.defaultName
        : LegacyCompactionSource.nameForPath(profileDirectory, legacyPath);
    for (final retired in _retiredRouters.toList()) {
      if (retired.profileDirectory == profileDirectory) await retired.close();
    }
    final catalog = await ManagedCatalogWorker.open(profileDirectory);
    final router = ProfileStorageRouter._(
      profileDirectory,
      catalog,
      storageFactory ??
          (location, create) => switch (location) {
            LegacyStorageLocator() => legacyFactory(),
            ManagedStorageLocator() =>
              (create
                      ? ManagedIdentityStorage.forCreation(
                          profileDirectory: profileDirectory,
                          entry: ManagedIdentityEntry.fromLocator(location),
                          recoverReferences: ({password, keys}) async {
                            await ManagedProfilePreferencesFile.withProfileReleased(
                              profileDirectory,
                              () => catalog.recoverLegacyReferences(
                                ManagedIdentityEntry.fromLocator(location),
                                password: password,
                                keys: keys,
                                sourceName: sourceName,
                              ),
                            );
                          },
                        )
                      : ManagedIdentityStorage.existing(
                          profileDirectory: profileDirectory,
                          entry: ManagedIdentityEntry.fromLocator(location),
                          recoverReferences: ({password, keys}) async {
                            await ManagedProfilePreferencesFile.withProfileReleased(
                              profileDirectory,
                              () => catalog.recoverLegacyReferences(
                                ManagedIdentityEntry.fromLocator(location),
                                password: password,
                                keys: keys,
                                sourceName: sourceName,
                              ),
                            );
                          },
                        ))
                  .storage,
          },
      sourceName,
    );
    // The bootstrap owns its cleanup even before a facade is published.
    _retiredRouters.add(router);
    try {
      router._snapshot = (await catalog.snapshot()).snapshot.catalog;
      router._access = router._location =
          router._snapshot.selected ?? const LegacyStorageLocator();
      router._selectionRequired =
          router._snapshot.identities.isNotEmpty &&
          router._snapshot.selected == null;
      router._storage = router._factory(router._location, false);
      _retiredRouters.remove(router);
      return router;
    } catch (_) {
      try {
        await catalog.close();
        _retiredRouters.remove(router);
      } catch (_) {}
      rethrow;
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _sealStores() {
    for (final storage in _retiredStores) {
      if (storage is StorageRetirementOwner) {
        (storage as StorageRetirementOwner).retireOpening();
      }
    }
  }

  /// Synchronous admission seal; actual native release remains close()'s job.
  void retireFacades() {
    if (!_closing) {
      _closing = true;
      _epoch++;
    }
    final current = _storage;
    if (current is StorageRetirementOwner) {
      (current as StorageRetirementOwner).retireOpening();
    }
    _sealStores();
  }

  Future<void> _retireStores() async {
    _sealStores();
    for (final storage in _retiredStores.toList()) {
      if (storage is StorageOpeningOwner) {
        await (storage as StorageOpeningOwner).settleOpening();
      }
      await storage.close();
      _retiredStores.remove(storage);
    }
  }

  Future<void> refresh() => _enqueue(() async {
    if (_closing) throw StateError('storage router is closing');
    _snapshot = (await _catalog.snapshot()).snapshot.catalog;
  });

  /// Explicit target only. The caller has stopped/closed its data owner and
  /// durably journaled the parent's roster obligation before invoking this.
  Future<void> eraseManaged(
    ManagedStorageLocator target,
    Uint8List keys, {
    IdentityEraseReview? review,
    Future<void> Function()? beforeErase,
  }) {
    final copied = Uint8List.fromList(keys);
    return _enqueue(() async {
      if (_closing) throw StateError('storage router is closing');
      try {
        _snapshot = (await _catalog.erase(
          ManagedIdentityEntry.fromLocator(target),
          keys: copied,
          review: review,
          beforeErase: beforeErase,
        )).catalog;
      } finally {
        // A late metadata-cleanup error may follow the durable catalog remove.
        // Refresh does not adopt another access root or redirect an old facade.
        _snapshot = (await _catalog.snapshot()).snapshot.catalog;
      }
    }).whenComplete(() => copied.fillRange(0, copied.length, 0));
  }

  Future<IdentityEraseReview> reviewManagedErasure(
    ManagedStorageLocator target,
    Uint8List keys,
  ) {
    final copied = Uint8List.fromList(keys);
    return _enqueue(() async {
      if (_closing) throw StateError('storage router is closing');
      return await _catalog.reviewErasure(
        ManagedIdentityEntry.fromLocator(target),
        copied,
      );
    }).whenComplete(() => copied.fillRange(0, copied.length, 0));
  }

  /// Existing, explicitly selected owner for maintenance credential collection.
  /// Keep its opening/close under this router's lifetime without changing the
  /// active view. The normal factory retains selected-root journal recovery.
  Storage createMaintenanceProbe(ManagedStorageLocator identity) {
    if (_closing ||
        !_snapshot.identities.any((entry) => entry.locator == identity)) {
      throw StateError('maintenance owner is not available');
    }
    final storage = _factory(identity, false);
    _retiredStores.add(storage);
    return storage;
  }

  /// Temporary legacy space for an authenticated roster operation. The parent
  /// sharing this container must be closed first. Retain before any opener
  /// await; close errors remain in the router's retirement set for retry.
  Future<void> eraseLegacy(Uint8List keys, {required void Function() check}) {
    final copied = Uint8List.fromList(keys);
    return _enqueue(() async {
      if (_closing) throw StateError('storage router is closing');
      check();
      final child = _factory(const LegacyStorageLocator(), false);
      _retiredStores.add(child);
      try {
        if (!await child.openWithKeys(copied)) {
          throw StateError('legacy roster credential refused');
        }
        check();
        await child.eraseSpace();
        check();
      } finally {
        if (child is StorageOpeningOwner) {
          await (child as StorageOpeningOwner).settleOpening();
        }
        await child.close();
        _retiredStores.remove(child);
      }
    }).whenComplete(() => copied.fillRange(0, copied.length, 0));
  }

  Future<void> select(
    IdentityStorageLocator location, {
    bool create = false,
    bool access = true,
  }) {
    if (_closing) return Future.error(StateError('storage router is closing'));
    if (!create &&
        location is ManagedStorageLocator &&
        !_snapshot.identities.any((entry) => entry.locator == location)) {
      return Future.error(
        const ManagedWorkerFailure(ManagedWorkerFailureKind.missing),
      );
    }
    final ticket = ++_epoch;
    return _enqueue(() async {
      if (_closing || ticket != _epoch) {
        throw StateError('storage selection superseded');
      }
      if (!create && location is ManagedStorageLocator) {
        _snapshot = (await _catalog.snapshot()).snapshot.catalog;
        if (!_snapshot.identities.any((entry) => entry.locator == location)) {
          throw const ManagedWorkerFailure(ManagedWorkerFailureKind.missing);
        }
      }
      final previous = _storage;
      if (previous != null) _retiredStores.add(previous);
      await _retireStores();
      if (_closing || ticket != _epoch) {
        throw StateError('storage selection superseded');
      }
      final next = _factory(location, create);
      _storage = next;
      _location = location;
      if (access) {
        _access = location;
        _selectionRequired = false;
      }
    });
  }

  Future<void> create(StorageProtection protection, {bool access = true}) =>
      select(
        protection == StorageProtection.hidden
            ? const LegacyStorageLocator()
            : ManagedStorageLocator(
                id: ManagedIdentityFiles.newId(),
                protection: protection,
              ),
        create: true,
        access: access,
      );

  void requireAccessSelection() {
    if (_selectionRequired) {
      throw StateError('choose a storage identity before unlocking');
    }
  }

  Future<void> rememberAccess() {
    final selected = _access;
    return _enqueue(() async {
      if (_closing || _access != selected) {
        throw StateError('storage selection superseded');
      }
      _snapshot = (await _catalog.select(
        selected is ManagedStorageLocator
            ? ManagedIdentityEntry.fromLocator(selected)
            : null,
      )).catalog;
    });
  }

  /// Adopt the opened root only after its caller has durably published the
  /// master roster. Child creation/selection can keep the prior access intact.
  /// Catalog confirmation precedes the in-memory change. The metadata result
  /// remains authoritative if lock supersedes the caller while it is awaited.
  Future<void> rememberCurrentAccess() {
    final selected = _location;
    return _enqueue(() async {
      if (_closing || _location != selected || !storage.isOpen) {
        throw StateError('the new access root must be open');
      }
      final snapshot = await _catalog.select(
        selected is ManagedStorageLocator
            ? ManagedIdentityEntry.fromLocator(selected)
            : null,
      );
      _snapshot = snapshot.catalog;
      _access = selected;
      _selectionRequired = false;
    });
  }

  Future<void> close() {
    if (_closed) return Future.value();
    retireFacades();
    _retiredRouters.add(this);
    return _closingJob ??= _enqueue(() async {
      final current = _storage;
      if (current != null) _retiredStores.add(current);
      await _retireStores();
      await _catalog.close();
      _closed = true;
      _retiredRouters.remove(this);
    }).whenComplete(() => _closingJob = null);
  }
}
