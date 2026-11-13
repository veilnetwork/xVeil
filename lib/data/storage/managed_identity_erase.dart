part of 'managed_directory_catalog.dart';

enum ManagedEraseStage {
  validated,
  blobsRemoved,
  contentRemoved,
  payloadsRemoved,
  catalogRemoved,
  roleRemoved,
  metadataRemoved,
}

typedef ManagedEraseObserver = Future<void> Function(ManagedEraseStage stage);

/// Payload-first removal under the identity's role lease. The keybox is last,
/// so a retry can authenticate without reopening partially removed content.
/// Catalog removal precedes releasing the lease; listed openers recheck it
/// AFTER acquiring their lease. Public-metadata-only tails need no payload
/// authentication, but never authorize deleting even an empty payload file.
abstract final class _ManagedIdentityEraser {
  static const _meta = [
    'identity.meta-journal',
    'identity.meta-wal',
    'identity.meta-shm',
    'identity.meta',
    'identity.meta.lock',
  ];

  static Future<void> run(
    ManagedDirectoryCatalog owner,
    ManagedIdentityEntry entry, {
    Uint8List? password,
    Uint8List? keys,
    ManagedEraseObserver? observer,
  }) {
    // Snapshot before the first await. Never retain/wipe a borrowed roster key.
    final pass = password == null ? null : Uint8List.fromList(password);
    final key = keys == null ? null : Uint8List.fromList(keys);
    return ManagedIdentityFiles._safeAsync(() async {
      _ManagedIdentityResources? resources;
      try {
        if (pass != null && key != null) {
          throw const ManagedIdentityFailure(ManagedIdentityFailureKind.mode);
        }
        final before = owner.snapshot();
        ManagedIdentityEntry? listed;
        for (final known in before.catalog.identities) {
          if (known.id == entry.id) listed = known;
        }
        if (listed != null) ManagedIdentityFiles._sameMode(listed, entry);
        if (listed != null && before.revision == 0x7fffffffffffffff) {
          throw const ManagedCatalogFailure(
            ManagedCatalogFailureKind.exhausted,
          );
        }
        final retired = owner._identityOwners[entry.id];
        if (retired != null) {
          if (!retired.closing) {
            throw const ManagedIdentityFailure(ManagedIdentityFailureKind.busy);
          }
          retired.close();
        }
        if (ManagedIdentityFiles._exists(
          ManagedIdentityFiles._staging(owner, entry.id),
        )) {
          throw const ManagedIdentityFailure(
            ManagedIdentityFailureKind.ambiguous,
          );
        }
        final path = owner.layout.directory(entry.id);
        if (!ManagedIdentityFiles._exists(path)) {
          owner._catalog.remove(entry); // Public metadata only; no files exist.
          owner._validate();
          return;
        }
        final held = _ManagedIdentityResources(owner, entry);
        resources = held;
        owner._reserveIdentity(held);
        held.erasing = true;
        held.admit(path);
        final hasRole = ManagedIdentityFiles._exists(
          held.file('identity.meta'),
        );
        if (hasRole) held.acquireLease();
        // This may be an unlisted retry after catalog removal. A changed mode
        // still refuses; absence never becomes permission to create a store.
        final current = ManagedIdentityFiles._listed(owner, entry.id);
        if (current != null) ManagedIdentityFiles._sameMode(current, entry);
        final inventory = _ManagedUsageInventory(held);
        final usage = await inventory.measure(requireComplete: false);
        if (usage.unrecognizedEntries != 0) {
          throw const ManagedIdentityFailure(
            ManagedIdentityFailureKind.ambiguous,
          );
        }
        final payloadPresent =
            inventory.dataFiles != 0 || inventory.blobFiles != 0;
        if (ManagedIdentityFiles._exists(held.file('identity.meta.lock')) &&
            File(held.file('identity.meta.lock')).lengthSync() != 0) {
          throw const ManagedIdentityFailure(
            ManagedIdentityFailureKind.ambiguous,
          );
        }
        if (!hasRole &&
            (payloadPresent ||
                _meta
                    .take(3)
                    .any(
                      (name) => ManagedIdentityFiles._exists(held.file(name)),
                    ))) {
          throw const ManagedIdentityFailure(
            ManagedIdentityFailureKind.ambiguous,
          );
        }
        if (payloadPresent) {
          if (entry.protection == StorageProtection.encrypted) {
            if (!inventory.seen.contains('keybox.hv')) {
              throw const ManagedIdentityFailure(
                ManagedIdentityFailureKind.authentication,
              );
            }
            if (key != null && key.length != 64 ||
                key == null && pass == null) {
              throw const ManagedIdentityFailure(
                ManagedIdentityFailureKind.authentication,
              );
            }
            held.rawKeybox = held._native(
              'keybox.hv',
              password: pass ?? Uint8List(0),
              keys: key,
              outer: true,
            );
            held.keybox = ManagedKeybox.openOwned(
              held.rawKeybox!,
              identity: entry.id,
            );
          } else {
            final expected = held._plainKeys();
            try {
              if (pass != null ||
                  key != null &&
                      !_ManagedIdentityResources._equal(expected, key)) {
                throw const ManagedIdentityFailure(
                  ManagedIdentityFailureKind.authentication,
                );
              }
            } finally {
              expected.fillRange(0, expected.length, 0);
            }
          }
        }
        // Close every payload handle before touching names, retaining the role
        // lease. A consuming-close error remains owned and stops this operation.
        held.closeDataHandles();
        await observer?.call(ManagedEraseStage.validated);
        await _removeBlobs(held);
        await observer?.call(ManagedEraseStage.blobsRemoved);
        if (entry.protection == StorageProtection.encrypted) {
          _removeFile(held, 'content.hv');
          _removeFile(held, 'maintenance.hv');
        } else {
          for (final suffix in ['-journal', '-wal', '-shm']) {
            _removeFile(held, 'data.store$suffix');
          }
        }
        owner._fs.syncDirectory(path);
        await observer?.call(ManagedEraseStage.contentRemoved);
        _removeFile(
          held,
          entry.protection == StorageProtection.encrypted
              ? 'keybox.hv'
              : 'data.store',
        );
        owner._fs.syncDirectory(path);
        await observer?.call(ManagedEraseStage.payloadsRemoved);

        // Preflight again before removing the public reference. Missing payload
        // names are expected; unexpected content is still preserved/refused.
        final tail = _ManagedUsageInventory(held);
        final remaining = await tail.measure(requireComplete: false);
        if (remaining.unrecognizedEntries != 0 ||
            tail.dataFiles != 0 ||
            tail.blobFiles != 0) {
          throw const ManagedIdentityFailure(
            ManagedIdentityFailureKind.ambiguous,
          );
        }
        final witnesses = <String, ManagedPathWitness>{};
        for (final name in _meta) {
          if (ManagedIdentityFiles._exists(held.file(name))) {
            witnesses[name] = owner._fs.requirePrivateFile(held.file(name));
            if (name == 'identity.meta.lock' &&
                File(held.file(name)).lengthSync() != 0) {
              throw const ManagedIdentityFailure(
                ManagedIdentityFailureKind.ambiguous,
              );
            }
          }
        }
        held.validatePaths();
        owner._catalog.remove(entry);
        owner._validate();
        await observer?.call(ManagedEraseStage.catalogRemoved);
        held.lease?.close();
        held.lease = null;
        for (final name in _meta) {
          final witness = witnesses[name];
          if (witness != null) _removeFile(held, name, expected: witness);
          if (name == 'identity.meta') {
            await observer?.call(ManagedEraseStage.roleRemoved);
          }
        }
        final blobs = held.file('blobs');
        if (ManagedIdentityFiles._exists(blobs)) {
          ManagedDirectoryCatalog._privateDirectory(blobs, owner._fs);
          Directory(
            blobs,
          ).deleteSync(); // Nonrecursive: unknown/new content refuses.
        }
        held.validatePaths();
        Directory(
          path,
        ).deleteSync(); // No recursive delete anywhere in this protocol.
        owner._fs.syncDirectory(owner.directory);
        await observer?.call(ManagedEraseStage.metadataRemoved);
      } finally {
        try {
          if (resources != null) {
            resources.erasing = false;
            resources.close();
          }
        } finally {
          pass?.fillRange(0, pass.length, 0);
          key?.fillRange(0, key.length, 0);
        }
      }
    });
  }

  static void _removeFile(
    _ManagedIdentityResources held,
    String name, {
    ManagedPathWitness? expected,
  }) {
    held.validatePaths();
    final path = held.file(name);
    if (!ManagedIdentityFiles._exists(path)) {
      if (expected != null) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
      return;
    }
    final before = held.owner._fs.requirePrivateFile(path);
    if (expected != null && !expected.sameObject(before)) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    ManagedDirectoryCatalog._assertSame(path, before, held.owner._fs);
    File(path).deleteSync();
  }

  static Future<void> _removeBlobs(_ManagedIdentityResources held) async {
    final path = held.file('blobs');
    if (!ManagedIdentityFiles._exists(path)) return;
    final fs = held.owner._fs;
    final rootWitness = ManagedDirectoryCatalog._privateDirectory(path, fs);
    await for (final blob in Directory(path).list(followLinks: false)) {
      held.validatePaths();
      ManagedDirectoryCatalog._assertSame(path, rootWitness, fs);
      final name = blob.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final witness = fs.inspect(blob.path);
      if (!_ManagedUsageInventory._blobName.hasMatch(name) ||
          !witness.directory ||
          !witness.ownedByCurrentUser ||
          !witness.safeAncestor) {
        throw const ManagedIdentityFailure(
          ManagedIdentityFailureKind.ambiguous,
        );
      }
      await for (final piece in Directory(blob.path).list(followLinks: false)) {
        held.validatePaths();
        ManagedDirectoryCatalog._assertSame(path, rootWitness, fs);
        ManagedDirectoryCatalog._assertSame(blob.path, witness, fs);
        final pieceName = piece.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last;
        final before = fs.inspect(piece.path);
        if (!_ManagedUsageInventory._pieceName.hasMatch(pieceName) ||
            before.directory ||
            !before.ownedByCurrentUser ||
            !before.safeAncestor) {
          throw const ManagedIdentityFailure(
            ManagedIdentityFailureKind.ambiguous,
          );
        }
        ManagedDirectoryCatalog._assertSame(piece.path, before, fs);
        File(piece.path).deleteSync();
      }
      ManagedDirectoryCatalog._assertSame(path, rootWitness, fs);
      ManagedDirectoryCatalog._assertSame(blob.path, witness, fs);
      Directory(blob.path).deleteSync();
      fs.syncDirectory(path);
    }
    held.validatePaths();
    ManagedDirectoryCatalog._assertSame(path, rootWitness, fs);
    fs.syncDirectory(path);
  }
}
