import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../domain/file_names.dart';
import '../domain/folder_sync.dart';
import 'folder_publication.dart';

class FolderSavedOperationCancelled implements Exception {
  const FolderSavedOperationCancelled();
}

class FolderSavedVersionChanged implements Exception {
  const FolderSavedVersionChanged();
}

class FolderSavedVersion {
  const FolderSavedVersion({
    required this.relativePath,
    required this.version,
    this.originalPath,
  });
  final String relativePath;
  final LocalFile? version;
  final String? originalPath;
  bool get previous => relativePath.endsWith('.previous');
  bool get readable => version != null;
  String get exportName =>
      'copy-${safeFileLeaf(originalPath?.split('/').last, fallback: 'saved.bin')}';
}

class FolderSavedVersionPage {
  const FolderSavedVersionPage(this.entries, {this.nextAfter});
  final List<FolderSavedVersion> entries;
  final String? nextAfter;
}

abstract interface class FolderSavedVersionAccess {
  Future<FolderSavedVersionPage> list(
    String root, {
    String? after,
    bool Function()? stillCurrent,
  });
  Future<SavedFolderFile> open(String root, FolderSavedVersion version);
}

/// Lists protocol copies only. Intent contents supply a display/export name,
/// never an open path or authority to read another file. A damaged intent does
/// not hide the surviving copy; it is shown without an original filename.
class NativeFolderSavedVersions implements FolderSavedVersionAccess {
  const NativeFolderSavedVersions({this.library, this.pageSize = 50});
  final DynamicLibrary? library;
  final int pageSize;
  static final _copy = RegExp(r'^\.xveil-[0-9a-f]{32}\.(previous|incoming)$');

  @override
  Future<FolderSavedVersionPage> list(
    String root, {
    String? after,
    bool Function()? stillCurrent,
  }) async {
    if (pageSize < 1 || pageSize > 200) {
      throw ArgumentError('Invalid page size');
    }
    void check() {
      if (stillCurrent?.call() == false) {
        throw const FolderSavedOperationCancelled();
      }
    }

    check();
    final scope = NativeFolderSession.open(root, lib: library);
    try {
      // Keep only the next page (+ one witness for pagination). Enumeration
      // streams; neither a huge directory nor a long history becomes a list
      // of open descriptors. An explicit refresh includes newly created names
      // that sort before the current cursor; this is not an atomic snapshot.
      final names = SplayTreeSet<String>();
      Future<void> walk(Directory directory, String prefix) async {
        await for (final entry in directory.list(followLinks: false)) {
          check();
          final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (name.contains(r'\')) {
            throw const FolderFsFailure(FolderFsFailureKind.reading);
          }
          final relative = '$prefix$name';
          if (_copy.hasMatch(name) &&
              (after == null || relative.compareTo(after) > 0)) {
            names.add(relative);
            if (names.length > pageSize + 1) names.remove(names.last);
          } else if (entry is Directory && !folderMirrorSkipsName(name)) {
            await walk(entry, '$relative/');
          }
        }
      }

      scope.checkRoot();
      await walk(Directory(root), '');
      final selected = names.take(pageSize).toList();
      final entries = <FolderSavedVersion>[];
      final targets = <String, String?>{};
      for (final relative in selected) {
        check();
        SavedFolderFile? file;
        try {
          file = scope.openSaved(relative);
          if (file == null) {
            continue; // Removed after the directory observation.
          }
          final stem = relative.replaceFirst(
            RegExp(r'\.(previous|incoming)$'),
            '',
          );
          if (!targets.containsKey(stem)) {
            targets[stem] = await _target(scope, '$stem.intent');
          }
          check();
          entries.add(
            FolderSavedVersion(
              relativePath: relative,
              version: file.version,
              originalPath: targets[stem],
            ),
          );
        } on FolderFsFailure {
          entries.add(
            FolderSavedVersion(relativePath: relative, version: null),
          );
        } finally {
          await file?.source.dispose();
        }
      }
      check();
      scope.checkRoot();
      return FolderSavedVersionPage(
        List.unmodifiable(entries),
        nextAfter: names.length > pageSize ? selected.last : null,
      );
    } on FileSystemException {
      throw const FolderFsFailure(FolderFsFailureKind.reading);
    } finally {
      scope.close();
    }
  }

  Future<String?> _target(NativeFolderSession scope, String relative) async {
    SavedFolderFile? intent;
    try {
      intent = scope.openSaved(relative);
      if (intent == null ||
          intent.source.size < 12 ||
          intent.source.size > 1036) {
        return null;
      }
      final bytes = await intent.source.read(0, intent.source.size);
      if (bytes == null ||
          bytes.length != intent.source.size ||
          !intent.unchanged()) {
        return null;
      }
      const magic = [88, 86, 80, 85, 66, 48, 49, 0];
      for (var i = 0; i < magic.length; i++) {
        if (bytes[i] != magic[i]) return null;
      }
      if (bytes[8] > 1 ||
          bytes[9] > 1 ||
          bytes.length != 12 + bytes[10] + 256 * bytes[11]) {
        return null;
      }
      final leaf = utf8.decode(bytes.sublist(12));
      if (leaf.isEmpty ||
          leaf.startsWith('.') ||
          leaf.contains('/') ||
          leaf.contains(r'\') ||
          leaf.contains('\u0000')) {
        return null;
      }
      final separator = relative.lastIndexOf('/');
      return separator < 0 ? leaf : '${relative.substring(0, separator)}/$leaf';
    } on FormatException {
      return null;
    } on FolderFsFailure {
      return null;
    } on FileSystemException {
      return null;
    } finally {
      await intent?.source.dispose();
    }
  }

  @override
  Future<SavedFolderFile> open(String root, FolderSavedVersion version) async {
    if (version.version == null ||
        !_copy.hasMatch(version.relativePath.split('/').last)) {
      throw const FolderSavedVersionChanged();
    }
    final scope = NativeFolderSession.open(root, lib: library);
    SavedFolderFile? file;
    var handedOff = false;
    try {
      scope.checkRoot();
      file = scope.openSaved(version.relativePath);
      if (file == null ||
          version.version == null ||
          !sameFolderSyncVersion(version.version, file.version)) {
        throw const FolderSavedVersionChanged();
      }
      scope.checkRoot();
      handedOff = true;
      return file;
    } finally {
      try {
        if (!handedOff) await file?.source.dispose();
      } finally {
        scope.close();
      }
    }
  }
}
