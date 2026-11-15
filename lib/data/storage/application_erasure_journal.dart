part of 'managed_directory_catalog.dart';

/// Enclosing application recovery data, separate from the native terminal.
/// Addresses support only read-only OS checks after a restart. They never
/// authorize removal or supply passwords, hidden slots or absolute paths.
final class _ApplicationErasureJournal {
  _ApplicationErasureJournal(
    this.binding,
    this.records,
    this._file,
    this._digest,
  );
  final ManagedErasureBinding binding;
  final SavedEntryAddresses records;
  final ManagedPathWitness _file;
  final String _digest;
  bool _unlinked = false, _synced = false;
  bool get unlinkPending => _unlinked && !_synced;
  static const _maxBytes = SavedEntryAddresses.maxEncodedBytes + 8192;

  static String _path(StorageProfileCoordinator gate) =>
      ManagedDirectoryCatalog._child(
        gate.directory,
        ManagedRootErasure.applicationJournalName,
      );

  static Map<String, Object?> _bindingRecord(ManagedErasureBinding binding) => {
    'profile': binding._profile,
    'coordinator': binding._coordinator,
    'pending': binding._pending,
    'digest': binding._digest,
    'auxiliary': binding._auxiliaryScope?.encode(),
  };

  static _ApplicationErasureJournal? openIfPresent(
    StorageProfileCoordinator gate,
    ManagedErasureBinding expected,
  ) {
    gate.requireHeld(exclusive: true);
    final path = _path(gate);
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    final file = gate._fs.requirePrivateFile(path);
    final bytes = _ErasureCompletion._read(path, file, _maxBytes, gate._fs);
    try {
      final raw = jsonDecode(utf8.decode(bytes));
      if (!expected._applicationProfile ||
          raw is! Map<String, dynamic> ||
          raw.length != 3 ||
          raw['v'] is! int ||
          raw['v'] != 1 ||
          raw['records'] is! String ||
          jsonEncode(raw['binding']) != jsonEncode(_bindingRecord(expected))) {
        throw const FormatException();
      }
      final records = SavedEntryAddresses.decode(raw['records'] as String);
      final canonical = jsonEncode({
        'v': 1,
        'binding': _bindingRecord(expected),
        'records': records.encode(),
      });
      if (utf8.decode(bytes) != canonical) throw const FormatException();
      return _ApplicationErasureJournal(
        expected,
        records,
        file,
        sha256.convert(bytes).toString(),
      );
    } catch (_) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
  }

  /// Journal-only recovery can reconstruct only a read-only reconciliation
  /// selector. Current native object identities must still match; no payload
  /// removal is admitted through this entrypoint.
  static _ApplicationErasureJournal openForRecovery(
    StorageProfileCoordinator gate,
  ) {
    gate.requireHeld(exclusive: true);
    final path = _path(gate);
    final file = gate._fs.requirePrivateFile(path);
    final bytes = _ErasureCompletion._read(path, file, _maxBytes, gate._fs);
    try {
      final raw = jsonDecode(utf8.decode(bytes));
      final fields = raw is Map ? raw['binding'] : null;
      bool objectId(Object? value) =>
          value is String &&
          value.isNotEmpty &&
          value.length <= 256 &&
          !value.contains('\x00');
      if (fields is! Map ||
          fields.length != 5 ||
          fields['profile'] != gate._profileWitness.identity ||
          fields['coordinator'] != gate._directoryWitness.identity ||
          !objectId(fields['pending']) ||
          fields['digest'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(fields['digest'] as String)) {
        throw const FormatException();
      }
      final auxiliary = _AuxiliaryErasureScope.decode(
        fields['auxiliary'],
        Directory(gate.profileDirectory).parent.path,
      );
      if (auxiliary == null || !auxiliary.speech || !auxiliary.translation) {
        throw const FormatException();
      }
      auxiliary.validateBase(gate);
      final binding = ManagedErasureBinding._(
        fields['profile'] as String,
        fields['coordinator'] as String,
        fields['pending'] as String,
        fields['digest'] as String,
        auxiliary: auxiliary,
        applicationProfile: true,
      );
      return openIfPresent(gate, binding)!;
    } catch (_) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
  }

  static _ApplicationErasureJournal publish(
    StorageProfileCoordinator gate,
    ManagedErasureBinding binding,
    SavedEntryAddresses records,
  ) {
    gate.requireHeld(exclusive: true);
    if (!binding._applicationProfile) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final existing = openIfPresent(gate, binding);
    if (existing != null) {
      if (existing.records.encode() != records.encode()) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
      return existing;
    }
    final bytes = utf8.encode(
      jsonEncode({
        'v': 1,
        'binding': _bindingRecord(binding),
        'records': records.encode(),
      }),
    );
    if (bytes.length > _maxBytes) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final suffix = List.generate(
      16,
      (_) => Random.secure().nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    final stage = File(
      ManagedDirectoryCatalog._child(
        gate.directory,
        '.application-erasure-$suffix.pending',
      ),
    );
    stage.createSync(exclusive: true);
    final witness = gate._fs.inspect(stage.path);
    var published = false;
    try {
      gate._fs.restrictNewFile(stage.path);
      ManagedDirectoryCatalog._assertSame(stage.path, witness, gate._fs);
      stage.writeAsBytesSync(bytes, flush: true);
      gate.requireHeld(exclusive: true);
      ManagedDirectoryCatalog._assertSame(stage.path, witness, gate._fs);
      published = gate._fs.publishFileNoReplace(stage.path, _path(gate));
      if (!published) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
      return openIfPresent(gate, binding)!;
    } finally {
      if (!published &&
          FileSystemEntity.typeSync(stage.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
        ManagedDirectoryCatalog._assertSame(stage.path, witness, gate._fs);
        gate._fs.requirePrivateFile(stage.path);
        stage.deleteSync();
        gate._fs.syncDirectory(gate.directory);
      }
    }
  }

  void validate(StorageProfileCoordinator gate) {
    gate.requireHeld(exclusive: true);
    if (_unlinked ||
        !binding._applicationProfile ||
        binding._profile != gate._profileWitness.identity ||
        binding._coordinator != gate._directoryWitness.identity ||
        sha256
                .convert(
                  _ErasureCompletion._read(
                    _path(gate),
                    _file,
                    _maxBytes,
                    gate._fs,
                  ),
                )
                .toString() !=
            _digest) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
  }

  void validateForRelease(StorageProfileCoordinator gate) {
    if (!_unlinked) {
      validate(gate);
      return;
    }
    gate.requireHeld(exclusive: true);
    if (FileSystemEntity.typeSync(_path(gate), followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
  }

  /// Only after the native terminal has finished and before its role releases.
  /// A failed final sync retains the same owner for a read-only retry.
  void removeAndSync(StorageProfileCoordinator gate) {
    if (!_unlinked) {
      validate(gate);
      File(_path(gate)).deleteSync();
      _unlinked = true;
    }
    gate.requireHeld(exclusive: true);
    if (FileSystemEntity.typeSync(_path(gate), followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    gate._fs.syncDirectory(gate.directory);
    _synced = true;
  }
}
