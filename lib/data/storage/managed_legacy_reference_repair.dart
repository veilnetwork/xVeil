part of 'managed_directory_catalog.dart';

typedef LegacyCompactionKeyChange = ({Uint8List before, Uint8List after});

enum LegacyReferenceRepairOutcome { none, retainedSource, publishedReplacement }

/// Bounded failure only; never include a path, locator, key or native message.
final class LegacyReferenceRepairFailure implements Exception {
  const LegacyReferenceRepairFailure();
  @override
  String toString() => 'LegacyReferenceRepairFailure';
}

/// Worker-only recovery for references held OUTSIDE a shared hidden rewrite.
/// The owner must hold exclusive profile/catalog grants throughout native
/// prepare/publication and recovery. Preparation authenticates every visible
/// identity; cold recovery may authenticate just its selected root. Catalog
/// metadata must not disclose which identity holds hidden references.
/// This backend does not acquire grants or enable application maintenance.
/// Source-name durability is rechecked before finalizing recovery. Unsupported
/// Windows directory flushes refuse admission, retaining private journals.
abstract final class ManagedLegacyReferenceRepair {
  /// Private in-volume file; its plaintext mode follows its owning identity.
  static const journalFile = 'storage:legacy-reference-repair.v1';

  /// Presence only, after authenticating this store. Partial/corrupt declarations
  /// also require recovery; this is not an authorization or validity verdict.
  static bool hasPendingJournal(ManagedIdentityStore store) =>
      ['file:$journalFile', 'ondisk:$journalFile'].any(
        (key) =>
            store.get(Ns.settings, Uint8List.fromList(utf8.encode(key))) !=
            null,
      );

  static void _wipeRows(List<RosterEntry>? rows) {
    for (final row in rows ?? const <RosterEntry>[]) {
      row.spaceKeys.fillRange(0, row.spaceKeys.length, 0);
    }
  }

  static void _requireOwner(ManagedDirectoryCatalog owner, int revision) {
    owner._validate();
    owner._coordinator.requireHeld(exclusive: true);
    owner._profileLease.requireHeld(exclusive: true);
    if (owner.snapshot().revision != revision) {
      throw const LegacyReferenceRepairFailure();
    }
  }

  static Future<T> _run<T>(
    ManagedDirectoryCatalog owner,
    Map<ManagedIdentityId, Uint8List> authorizations,
    Future<T> Function(
      List<ManagedIdentityEntry> entries,
      Map<ManagedIdentityId, Uint8List> keys,
      void Function() check,
    )
    work, {
    ManagedIdentityId? only,
  }) async {
    final keys = <ManagedIdentityId, Uint8List>{};
    var acquired = false;
    try {
      final snapshot = owner.snapshot();
      _requireOwner(owner, snapshot.revision);
      final entries = only == null
          ? snapshot.catalog.identities
          : snapshot.catalog.identities
                .where((entry) => entry.id == only)
                .toList();
      if (owner._legacyReferenceRepairBusy ||
          (only != null && entries.length != 1) ||
          authorizations.length != entries.length) {
        throw const LegacyReferenceRepairFailure();
      }
      for (final entry in entries) {
        final value = authorizations[entry.id];
        if (value == null || value.length != 64) {
          throw const LegacyReferenceRepairFailure();
        }
        keys[entry.id] = Uint8List.fromList(value);
      }
      owner._legacyReferenceRepairBusy = acquired = true;
      // Probe the actual existing-parent barrier before preparing any private
      // obligation. Windows publication's generic directory no-op is not a
      // recovery capability. A denied/unsupported flush refuses without writes.
      owner._fs.syncSourceDirectory(
        Directory(owner.profileDirectory).parent.path,
      );
      _requireOwner(owner, snapshot.revision);
      return await work(
        entries,
        keys,
        () => _requireOwner(owner, snapshot.revision),
      );
    } on LegacyReferenceRepairFailure {
      rethrow;
    } catch (_, trace) {
      Error.throwWithStackTrace(const LegacyReferenceRepairFailure(), trace);
    } finally {
      for (final key in keys.values) {
        key.fillRange(0, key.length, 0);
      }
      if (acquired) owner._legacyReferenceRepairBusy = false;
    }
  }

  static Future<T> _withMaster<T>(
    ManagedDirectoryCatalog owner,
    ManagedIdentityEntry entry,
    Uint8List keys,
    Future<T> Function(HiddenVolumeStorage master, ManagedIdentityStore store)
    action,
  ) async {
    final store = ManagedIdentityFiles.openWithKeys(
      owner,
      id: entry.id,
      keys: keys,
    );
    final master = HiddenVolumeStorage.fromStore(store);
    try {
      return await action(master, store);
    } finally {
      await master.close();
    }
  }

  static Future<_LegacyReferenceIntent?> _read(
    HiddenVolumeStorage master,
    ManagedIdentityStore store,
  ) async {
    // A declared partial file is not an absent journal. Download completeness
    // (hasFile) is deliberately insufficient for this protected recovery root.
    if (store.get(
          Ns.settings,
          Uint8List.fromList(utf8.encode('ondisk:$journalFile')),
        ) !=
        null) {
      throw const LegacyReferenceRepairFailure();
    }
    final declared =
        store.get(
          Ns.settings,
          Uint8List.fromList(utf8.encode('file:$journalFile')),
        ) !=
        null;
    final raw = await master.loadFile(
      journalFile,
      maxBytes: _LegacyReferenceIntent.maxBytes,
    );
    try {
      if (raw == null) {
        if (declared) {
          throw const LegacyReferenceRepairFailure();
        }
        return null;
      }
      return _LegacyReferenceIntent.decode(raw);
    } finally {
      raw?.fillRange(0, raw.length, 0);
    }
  }

  /// Call from the prepared native callback, before granting publication.
  /// All holders are authenticated/validated before the first journal write.
  /// A partial failure leaves old rosters and recoverable private journals.
  static Future<void> prepare({
    required ManagedDirectoryCatalog owner,
    required Map<ManagedIdentityId, Uint8List> authorizations,
    required List<LegacyCompactionKeyChange> changes,
    String sourceName = LegacyCompactionSource.defaultName,
  }) {
    final copied = _LegacyReferenceIntent.copyChanges(changes);
    return _run<void>(owner, authorizations, (entries, keys, check) async {
      LegacyCompactionSource.validateName(sourceName);
      final plans = <ManagedIdentityId, _LegacyReferenceIntent>{};
      try {
        for (final entry in entries) {
          check();
          await _withMaster(owner, entry, keys[entry.id]!, (
            master,
            store,
          ) async {
            final existing = await _read(master, store);
            List<RosterEntry>? rows;
            try {
              check();
              rows = await master.loadRosterForMaintenance();
              check();
              final requiredKeys = {
                for (final row in rows ?? const <RosterEntry>[])
                  if (row.storageLocator is LegacyStorageLocator)
                    base64.encode(row.spaceKeys),
              };
              final relevant = [
                for (final change in copied)
                  if (requiredKeys.remove(base64.encode(change.before))) change,
              ];
              if (requiredKeys.isNotEmpty) {
                throw const LegacyReferenceRepairFailure();
              }
              if (relevant.isEmpty) {
                if (existing != null) {
                  throw const LegacyReferenceRepairFailure();
                }
                return;
              }
              final intent = _LegacyReferenceIntent.create(
                entry.locator,
                keys[entry.id]!,
                relevant,
                sourceName,
              );
              plans[entry.id] = intent;
              if (existing != null && !existing.same(intent)) {
                throw const LegacyReferenceRepairFailure();
              }
            } finally {
              _wipeRows(rows);
              existing?.destroy();
            }
          });
          check();
        }
        for (final entry in entries) {
          final intent = plans[entry.id];
          if (intent == null) continue;
          check();
          await _withMaster(owner, entry, keys[entry.id]!, (
            master,
            store,
          ) async {
            // Revalidate the live roster, rather than replacing it from the
            // preflight snapshot. The intent itself never contains labels.
            final rows = await master.loadRosterForMaintenance();
            Uint8List? bytes;
            try {
              check();
              intent.repair(rows, published: false);
              bytes = intent.encode();
              await master.storeFile(journalFile, bytes);
              check();
              final verified = await _read(master, store);
              try {
                check();
                if (verified == null || !verified.same(intent)) {
                  throw const LegacyReferenceRepairFailure();
                }
              } finally {
                verified?.destroy();
              }
            } finally {
              bytes?.fillRange(0, bytes.length, 0);
              _wipeRows(rows);
            }
          });
          check();
        }
      } finally {
        for (final intent in plans.values) {
          intent.destroy();
        }
      }
    }).whenComplete(() {
      for (final change in copied) {
        change.before.fillRange(0, change.before.length, 0);
        change.after.fillRange(0, change.after.length, 0);
      }
    });
  }

  /// Resume only after the native prepared owner has settled/released source.
  /// Probe actual old/new keys under exclusive profile ownership; elapsed time,
  /// a header, an earlier return value or a lost reply cannot choose the result.
  static Future<LegacyReferenceRepairOutcome> resume({
    required ManagedDirectoryCatalog owner,
    required Map<ManagedIdentityId, Uint8List> authorizations,
    String sourceName = LegacyCompactionSource.defaultName,
  }) => _resume(
    owner: owner,
    authorizations: authorizations,
    sourceName: sourceName,
  );

  /// Recover one authenticated root without inspecting other private journals.
  /// Later rewrite preparation still authenticates every visible owner and
  /// refuses to bury an unresolved journal in a second source generation.
  static Future<LegacyReferenceRepairOutcome> resumeForIdentity({
    required ManagedDirectoryCatalog owner,
    required ManagedIdentityId identity,
    required Uint8List keys,
    String sourceName = LegacyCompactionSource.defaultName,
  }) => _resume(
    owner: owner,
    authorizations: {identity: keys},
    only: identity,
    sourceName: sourceName,
  );

  static Future<LegacyReferenceRepairOutcome> _resume({
    required ManagedDirectoryCatalog owner,
    required Map<ManagedIdentityId, Uint8List> authorizations,
    ManagedIdentityId? only,
    required String sourceName,
  }) => _run(owner, authorizations, (entries, keys, check) async {
    LegacyCompactionSource.validateName(sourceName);
    final intents = <ManagedIdentityId, _LegacyReferenceIntent>{};
    try {
      for (final entry in entries) {
        check();
        await _withMaster(owner, entry, keys[entry.id]!, (master, store) async {
          final intent = await _read(master, store);
          if (intent != null) intents[entry.id] = intent;
          check();
          if (intent == null) return;
          intent.validate(entry.locator, keys[entry.id]!);
          if (intent.sourceName != sourceName) {
            throw const LegacyReferenceRepairFailure();
          }
          final rows = await master.loadRosterForMaintenance();
          try {
            check();
            intent.repair(rows, published: null);
          } finally {
            _wipeRows(rows);
          }
        });
        check();
      }
      if (intents.isEmpty) return LegacyReferenceRepairOutcome.none;
      final profile = ManagedDirectoryCatalog._admitProfile(
        Directory(owner.profileDirectory).parent.path,
        owner._fs,
      );
      final source = LegacyCompactionSource.path(
        owner.profileDirectory,
        sourceName,
      );
      final sourceWitness = owner._fs.requirePrivateFile(source);
      void stableSource() {
        check();
        ManagedDirectoryCatalog._assertProfile(
          profile.path,
          profile.witness,
          owner._fs,
        );
        owner._fs.requirePrivateFile(source);
        ManagedDirectoryCatalog._assertSame(source, sourceWitness, owner._fs);
      }

      final proofs = <String, bool>{};
      bool proves(Uint8List value) {
        stableSource();
        final encoded = base64.encode(value);
        if (proofs.containsKey(encoded)) return proofs[encoded]!;
        final result = hv.verifySpaceKeys(path: source, keys: value);
        stableSource();
        proofs[encoded] = result;
        return result;
      }

      bool? published;
      for (final intent in intents.values) {
        for (final change in intent.changes) {
          final before = proves(change.before), after = proves(change.after);
          if (before == after || (published != null && published != after)) {
            throw const LegacyReferenceRepairFailure();
          }
          published = after;
        }
      }
      // A visible rename can have returned a durability-uncertain outcome.
      // Anchor the observed source NAME before moving/clearing any journal in
      // another file. Native prepared publication already syncs its file data.
      // An unsuccessful directory barrier leaves every private intent intact.
      stableSource();
      owner._fs.syncSourceDirectory(profile.path);
      stableSource();
      for (final entry in entries) {
        final intent = intents[entry.id];
        if (intent == null) continue;
        stableSource();
        await _withMaster(owner, entry, keys[entry.id]!, (master, store) async {
          final rows = await master.loadRosterForMaintenance();
          List<RosterEntry>? repaired;
          try {
            stableSource();
            repaired = intent.repair(rows, published: published!);
            if (published) {
              await master.saveRoster(repaired);
              stableSource();
            }
            // Separate durable steps: a crash after save repeats the same repair.
            await master.deleteStoredFile(journalFile);
            stableSource();
          } finally {
            _wipeRows(rows);
            _wipeRows(repaired);
          }
        });
        stableSource();
      }
      return published == true
          ? LegacyReferenceRepairOutcome.publishedReplacement
          : LegacyReferenceRepairOutcome.retainedSource;
    } finally {
      for (final intent in intents.values) {
        intent.destroy();
      }
    }
  }, only: only);
}

final class _LegacyReferenceIntent {
  _LegacyReferenceIntent(
    this.root,
    this.masterDigest,
    this.changes,
    this.sourceName,
  );
  final String sourceName;
  final ManagedStorageLocator root;
  final Uint8List masterDigest;
  final List<LegacyCompactionKeyChange> changes;
  static const maxBytes = 64 * 1024, maxChanges = 256;

  static List<LegacyCompactionKeyChange> copyChanges(
    List<LegacyCompactionKeyChange> input,
  ) {
    final result = <LegacyCompactionKeyChange>[];
    try {
      if (input.isEmpty || input.length > maxChanges) {
        throw const LegacyReferenceRepairFailure();
      }
      final seen = <String>{};
      for (final change in input) {
        if (change.before.length != 64 ||
            change.after.length != 64 ||
            !seen.add(base64.encode(change.before)) ||
            !seen.add(base64.encode(change.after))) {
          throw const LegacyReferenceRepairFailure();
        }
        result.add((
          before: Uint8List.fromList(change.before),
          after: Uint8List.fromList(change.after),
        ));
      }
      result.sort(
        (a, b) => base64.encode(a.before).compareTo(base64.encode(b.before)),
      );
      return result;
    } catch (_) {
      for (final change in result) {
        change.before.fillRange(0, change.before.length, 0);
        change.after.fillRange(0, change.after.length, 0);
      }
      rethrow;
    }
  }

  factory _LegacyReferenceIntent.create(
    ManagedStorageLocator root,
    Uint8List keys,
    List<LegacyCompactionKeyChange> changes,
    String sourceName,
  ) => _LegacyReferenceIntent(
    root,
    Uint8List.fromList(sha256.convert(keys).bytes),
    copyChanges(changes),
    LegacyCompactionSource.validateName(sourceName),
  );

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 2,
        'source': sourceName,
        'root': root.encode(),
        'master': base64.encode(masterDigest),
        'changes': [
          for (final change in changes)
            [base64.encode(change.before), base64.encode(change.after)],
        ],
      }),
    ),
  );

  factory _LegacyReferenceIntent.decode(Uint8List bytes) {
    Uint8List? digest;
    final decoded = <LegacyCompactionKeyChange>[];
    try {
      if (bytes.length > maxBytes) throw const LegacyReferenceRepairFailure();
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic> || value['v'] is! int) {
        throw const LegacyReferenceRepairFailure();
      }
      final expected = switch (value['v']) {
        1 => {'v', 'root', 'master', 'changes'},
        2 => {'v', 'source', 'root', 'master', 'changes'},
        _ => throw const LegacyReferenceRepairFailure(),
      };
      if (value.length != expected.length ||
          !value.keys.toSet().containsAll(expected)) {
        throw const LegacyReferenceRepairFailure();
      }
      final sourceName = value['v'] == 1
          ? LegacyCompactionSource.defaultName
          : value['source'];
      if (sourceName is! String) throw const LegacyReferenceRepairFailure();
      LegacyCompactionSource.validateName(sourceName);
      final root = IdentityStorageLocator.decode(value['root']);
      if (root is! ManagedStorageLocator) {
        throw const LegacyReferenceRepairFailure();
      }
      Uint8List parse(Object? text, int length) {
        if (text is! String) throw const LegacyReferenceRepairFailure();
        final data = base64.decode(text);
        if (data.length != length || base64.encode(data) != text) {
          data.fillRange(0, data.length, 0);
          throw const LegacyReferenceRepairFailure();
        }
        return data;
      }

      digest = parse(value['master'], 32);
      final raw = value['changes'];
      if (raw is! List || raw.isEmpty || raw.length > maxChanges) {
        throw const LegacyReferenceRepairFailure();
      }
      for (final pair in raw) {
        if (pair is! List || pair.length != 2) {
          throw const LegacyReferenceRepairFailure();
        }
        final before = parse(pair[0], 64);
        try {
          decoded.add((before: before, after: parse(pair[1], 64)));
        } catch (_) {
          before.fillRange(0, before.length, 0);
          rethrow;
        }
      }
      return _LegacyReferenceIntent(
        root,
        digest,
        copyChanges(decoded),
        sourceName,
      );
    } catch (_) {
      digest?.fillRange(0, digest.length, 0);
      throw const LegacyReferenceRepairFailure();
    } finally {
      for (final change in decoded) {
        change.before.fillRange(0, change.before.length, 0);
        change.after.fillRange(0, change.after.length, 0);
      }
    }
  }

  void validate(ManagedStorageLocator actualRoot, Uint8List keys) {
    if (root != actualRoot ||
        keys.length != 64 ||
        !_same(masterDigest, sha256.convert(keys).bytes)) {
      throw const LegacyReferenceRepairFailure();
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  bool same(_LegacyReferenceIntent other) {
    final a = encode(), b = other.encode();
    try {
      return _same(a, b);
    } finally {
      a.fillRange(0, a.length, 0);
      b.fillRange(0, b.length, 0);
    }
  }

  List<RosterEntry> repair(
    List<RosterEntry>? rows, {
    required bool? published,
  }) {
    if (rows == null) throw const LegacyReferenceRepairFailure();
    final found = <int>{};
    final indices = <int>[];
    for (final row in rows) {
      if (row.storageLocator is ManagedStorageLocator) {
        indices.add(-1);
        continue;
      }
      final index = changes.indexWhere(
        (change) =>
            _same(row.spaceKeys, change.before) ||
            _same(row.spaceKeys, change.after),
      );
      if (index < 0) throw const LegacyReferenceRepairFailure();
      final change = changes[index];
      if (published == false && !_same(row.spaceKeys, change.before)) {
        throw const LegacyReferenceRepairFailure();
      }
      found.add(index);
      indices.add(index);
    }
    if (found.length != changes.length) {
      throw const LegacyReferenceRepairFailure();
    }
    return [
      for (var i = 0; i < rows.length; i++)
        if (published == true && indices[i] >= 0)
          rows[i].copyWith(
            spaceKeys: Uint8List.fromList(changes[indices[i]].after),
          )
        else
          rows[i],
    ];
  }

  void destroy() {
    masterDigest.fillRange(0, masterDigest.length, 0);
    for (final change in changes) {
      change.before.fillRange(0, change.before.length, 0);
      change.after.fillRange(0, change.after.length, 0);
    }
  }
}
