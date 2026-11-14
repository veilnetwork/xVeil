part of 'managed_directory_catalog.dart';

/// Explicit profile-owned auxiliary data. The legacy parent must be the
/// managed profile's parent. External model overrides are not owned by this
/// profile and must not be included. No password or hidden-space scan.
final class ProfileErasureAuxiliaryTargets {
  const ProfileErasureAuxiliaryTargets({
    required this.legacyPath,
    this.speech = true,
    this.translation = true,
  });
  final String legacyPath;
  final bool speech, translation;
}

/// Retained in the terminal witness and opaque release binding, after the
/// per-file inventory is gone. It can only verify absence, never delete.
final class _AuxiliaryErasureScope {
  const _AuxiliaryErasureScope(
    this.base,
    this.identity,
    this.legacy,
    this.speech,
    this.translation,
  );
  final String base, identity, legacy;
  final bool speech, translation;
  static bool _leaf(String value) =>
      value.isNotEmpty &&
      value != '.' &&
      value != '..' &&
      !value.contains('/') &&
      !value.contains('\\') &&
      !value.contains(':') &&
      !value.contains('\x00') &&
      utf8.encode(value).length <= 255;
  static bool _objectId(Object? value) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= 256 &&
      !value.contains('\x00');
  static final _pair = RegExp(
    r'^(?:\.incoming-|\.replacing-)?[a-z]{2,3}-[a-z]{2,3}$',
  );
  static final _archive = RegExp(
    r'^[0-9a-f]{16}-[a-z]{2,3}-[a-z]{2,3}\.veiltranslate(?:\.part)?$',
  );
  RegExp get _rewrite => RegExp(
    '^\\.${RegExp.escape(legacy)}\\.hv-(?:compact|rotate)\\.[0-9a-f]{16}\\.tmp\$',
  );
  String absolute(List<String> parts) => File.fromUri(
    Directory(base).uri.resolveUri(Uri(pathSegments: parts)),
  ).path;

  Map<String, Object> encode() => {
    'identity': identity,
    'legacy': legacy,
    'speech': speech,
    'translation': translation,
    'preferences': true,
  };
  static _AuxiliaryErasureScope? decode(Object? raw, String base) {
    if (raw == null) return null;
    if (raw is! Map ||
        raw.length != 5 ||
        raw['preferences'] != true ||
        !_objectId(raw['identity']) ||
        raw['legacy'] is! String ||
        !_leaf(raw['legacy'] as String) ||
        raw['speech'] is! bool ||
        raw['translation'] is! bool) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    return _AuxiliaryErasureScope(
      base,
      raw['identity'] as String,
      raw['legacy'] as String,
      raw['speech'] as bool,
      raw['translation'] as bool,
    );
  }

  void validateBase(StorageProfileCoordinator gate) {
    gate.requireHeld(exclusive: true);
    final parent = Directory(gate.profileDirectory).parent.path;
    if (base != parent ||
        legacy ==
            Directory(
              gate.profileDirectory,
            ).uri.pathSegments.where((p) => p.isNotEmpty).last ||
        {
          'blobs',
          ...ProfilePreferencesLayout.files,
          ProfileModelLayout.translationDirectory,
          ProfileModelLayout.speechFile,
          '${ProfileModelLayout.speechFile}.part',
          '.incoming-speech',
          StorageProfileCoordinator.directoryName,
        }.contains(legacy)) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final actual = gate._fs.inspect(base);
    if (!actual.directory ||
        !actual.ownedByCurrentUser ||
        !actual.safeAncestor ||
        actual.identity != identity) {
      throw const ManagedFsFailure(ManagedFsFailureKind.changed);
    }
    ManagedDirectoryCatalog._assertProfile(base, actual, gate._fs);
  }

  /// Enumerate only known top-level names, including rewrites created late.
  /// No content outside these names is treated as this wipe's authority.
  Set<String> roots(StorageProfileCoordinator gate) {
    validateBase(gate);
    final names = <String>{
      legacy,
      'blobs',
      ...ProfilePreferencesLayout.files,
      if (speech) ...[
        ProfileModelLayout.speechFile,
        '${ProfileModelLayout.speechFile}.part',
        '.incoming-speech',
      ],
      if (translation) ProfileModelLayout.translationDirectory,
    };
    var count = 0;
    for (final child in Directory(base).listSync(followLinks: false)) {
      if (++count > _RootErasePlan.maxEntries) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
      final name = child.uri.pathSegments.where((p) => p.isNotEmpty).last;
      if (_rewrite.hasMatch(name)) names.add(name);
    }
    validateBase(gate);
    return names;
  }

  bool allowed(List<String> p, bool directory) {
    if (p.isEmpty || p.any((v) => !_leaf(v))) return false;
    if (ProfilePreferencesLayout.files.contains(p.first)) {
      return p.length == 1 && !directory;
    }
    if (p.first == legacy || _rewrite.hasMatch(p.first)) {
      return p.length == 1 && !directory;
    }
    if (p.first == 'blobs') {
      return p.length == 1 && directory ||
          p.length == 2 && directory && _RootErasePlan._blob.hasMatch(p[1]) ||
          p.length == 3 &&
              !directory &&
              _RootErasePlan._blob.hasMatch(p[1]) &&
              _RootErasePlan._piece.hasMatch(p[2]);
    }
    if (speech) {
      if ({
        ProfileModelLayout.speechFile,
        '${ProfileModelLayout.speechFile}.part',
      }.contains(p.first)) {
        return p.length == 1 && !directory;
      }
      if (p.first == '.incoming-speech') {
        return p.length == 1 && directory ||
            p.length == 2 &&
                !directory &&
                p[1] == ProfileModelLayout.speechFile;
      }
    }
    if (!translation || p.first != ProfileModelLayout.translationDirectory) {
      return false;
    }
    if (p.length == 1) return directory;
    if (p[1] == '.github-downloads') {
      return p.length == 2 && directory ||
          p.length == 3 && !directory && _archive.hasMatch(p[2]);
    }
    if (!_pair.hasMatch(p[1])) return false;
    return p.length == 2 && directory ||
        p.length == 3 &&
            !directory &&
            (ProfileModelLayout.translationFiles.contains(p[2]) ||
                ProfileModelLayout.translationFiles.any(
                  (f) => '$f.part' == p[2],
                ));
  }

  void requireAbsent(StorageProfileCoordinator gate) {
    for (final name in roots(gate)) {
      if (FileSystemEntity.typeSync(absolute([name]), followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
    }
    validateBase(gate);
  }
}

final class _AuxiliaryErasurePlan {
  _AuxiliaryErasurePlan(this.scope, this.entries);
  final _AuxiliaryErasureScope scope;
  final Map<String, _RootEraseEntry> entries;
  late final Map<String, Set<String>> _children = () {
    final result = <String, Set<String>>{};
    for (final e in entries.values) {
      if (e.parts.length > 1) {
        (result[e.parts.take(e.parts.length - 1).join('/')] ??= <String>{}).add(
          e.parts.last,
        );
      }
    }
    return result;
  }();

  static Future<_AuxiliaryErasurePlan> capture(
    StorageProfileCoordinator gate,
    ProfileErasureAuxiliaryTargets target,
  ) async {
    gate.requireHeld(exclusive: true);
    if (target.legacyPath.isEmpty ||
        target.legacyPath.contains('\x00') ||
        !File(target.legacyPath).isAbsolute) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final file = File.fromUri(
      File(target.legacyPath).absolute.uri.normalizePath(),
    );
    final base = Directory(gate.profileDirectory).parent.path;
    if (file.parent.resolveSymbolicLinksSync() != base) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final scope = _AuxiliaryErasureScope(
      base,
      gate._fs.inspect(base).identity,
      file.uri.pathSegments.last,
      target.speech,
      target.translation,
    );
    scope.validateBase(gate);
    final entries = <String, _RootEraseEntry>{};
    Future<void> visit(List<String> parts) async {
      scope.validateBase(gate);
      final path = scope.absolute(parts);
      final witness = gate._fs.inspect(path);
      if (!scope.allowed(parts, witness.directory) ||
          !witness.ownedByCurrentUser ||
          !witness.safeAncestor) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
      final stamp = File(path).statSync();
      final entry = _RootEraseEntry(
        parts,
        witness.identity,
        witness.directory,
        witness.directory ? 0 : stamp.size,
        witness.directory ? 0 : stamp.modified.microsecondsSinceEpoch,
      );
      entries[entry.path] = entry;
      if (entries.length > _RootErasePlan.maxEntries) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
      if (witness.directory) {
        await for (final child in Directory(path).list(followLinks: false)) {
          await visit([
            ...parts,
            child.uri.pathSegments.where((p) => p.isNotEmpty).last,
          ]);
        }
      }
    }

    for (final name in scope.roots(gate)) {
      if (FileSystemEntity.typeSync(
            scope.absolute([name]),
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        await visit([name]);
      }
    }
    final result = _AuxiliaryErasurePlan(scope, Map.unmodifiable(entries));
    result.validateTree(gate);
    return result;
  }

  Map<String, Object> encode() => {
    'scope': scope.encode(),
    'entries': [for (final e in entries.values) e.encode()],
  };
  static _AuxiliaryErasurePlan? decode(
    Object? raw,
    StorageProfileCoordinator gate,
  ) {
    if (raw == null) return null;
    if (raw is! Map || raw.length != 2 || raw['entries'] is! List) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final scope = _AuxiliaryErasureScope.decode(
      raw['scope'],
      Directory(gate.profileDirectory).parent.path,
    );
    final list = raw['entries'] as List;
    if (scope == null || list.length > _RootErasePlan.maxEntries) {
      throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
    }
    final entries = <String, _RootEraseEntry>{};
    for (final row in list) {
      if (row is! List ||
          row.length != 5 ||
          row[0] is! String ||
          !_AuxiliaryErasureScope._objectId(row[1]) ||
          row[2] is! bool ||
          row[3] is! int ||
          row[4] is! int ||
          row[3] < 0 ||
          row[4] < 0 ||
          row[3] > 0x7fffffffffffffff ||
          row[4] > 0x7fffffffffffffff) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
      final path = row[0] as String;
      final parts = path.split('/');
      if (utf8.encode(path).length > 1024 ||
          !scope.allowed(parts, row[2] as bool) ||
          entries.containsKey(path) ||
          row[2] == true && (row[3] != 0 || row[4] != 0)) {
        throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
      }
      entries[path] = _RootEraseEntry(
        parts,
        row[1] as String,
        row[2] as bool,
        row[3] as int,
        row[4] as int,
      );
    }
    for (final entry in entries.values) {
      for (var i = 1; i < entry.parts.length; i++) {
        if (entries[entry.parts.take(i).join('/')]?.directory != true) {
          throw const ManagedFsFailure(ManagedFsFailureKind.unsafe);
        }
      }
    }
    return _AuxiliaryErasurePlan(scope, Map.unmodifiable(entries));
  }

  bool validateEntry(StorageProfileCoordinator gate, _RootEraseEntry entry) {
    scope.validateBase(gate);
    for (var i = 1; i <= entry.parts.length; i++) {
      final expected = entries[entry.parts.take(i).join('/')]!;
      final path = scope.absolute(expected.parts);
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return false;
      }
      final actual = gate._fs.inspect(path);
      if (actual.identity != expected.identity ||
          actual.directory != expected.directory ||
          !actual.ownedByCurrentUser ||
          !actual.safeAncestor) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
      if (!actual.directory) {
        final stamp = File(path).statSync();
        if (stamp.size != expected.bytes ||
            stamp.modified.microsecondsSinceEpoch != expected.modified) {
          throw const ManagedFsFailure(ManagedFsFailureKind.changed);
        }
        ManagedDirectoryCatalog._assertSame(path, actual, gate._fs);
      }
    }
    return true;
  }

  void validateTree(StorageProfileCoordinator gate) {
    for (final name in scope.roots(gate)) {
      if (FileSystemEntity.typeSync(
                scope.absolute([name]),
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound &&
          !entries.containsKey(name)) {
        throw const ManagedFsFailure(ManagedFsFailureKind.changed);
      }
    }
    for (final entry in entries.values) {
      if (!validateEntry(gate, entry) || !entry.directory) continue;
      final expected = _children[entry.path] ?? const <String>{};
      for (final child in Directory(
        scope.absolute(entry.parts),
      ).listSync(followLinks: false).take(expected.length + 1)) {
        if (!expected.contains(
          child.uri.pathSegments.where((p) => p.isNotEmpty).last,
        )) {
          throw const ManagedFsFailure(ManagedFsFailureKind.changed);
        }
      }
    }
  }
}
