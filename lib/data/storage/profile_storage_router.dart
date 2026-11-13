import 'dart:async';
import 'dart:io';

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
  ProfileStorageRouter._(this.profileDirectory, this._catalog, this._factory);
  final String profileDirectory;
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
    ProfileIdentityStorageFactory? storageFactory,
  }) async {
    profileDirectory = Directory(
      profileDirectory,
    ).absolute.uri.normalizePath().toFilePath();
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
                        )
                      : ManagedIdentityStorage.existing(
                          profileDirectory: profileDirectory,
                          entry: ManagedIdentityEntry.fromLocator(location),
                        ))
                  .storage,
          },
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

  Future<void> _retireStores() async {
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
    _closing = true;
    _epoch++;
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
