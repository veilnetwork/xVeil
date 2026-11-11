import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../domain/folder_sync.dart';
import 'fs_beneath.dart';
import 'node/veil_library.dart';

enum FolderFsFailureKind {
  unavailable,
  busy,
  rootChanged,
  recovery,
  preparation,
  publication,
}

/// Only a category survives this boundary. Native paths and error strings are
/// neither kept on this object nor copied into the diagnostic error registry.
class FolderFsFailure implements Exception {
  const FolderFsFailure(this.kind);
  final FolderFsFailureKind kind;

  @override
  String toString() => 'Folder filesystem operation refused (${kind.name})';
}

typedef _OpenNative =
    Pointer<Void> Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _OpenDart =
    Pointer<Void> Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _MatchNative =
    Bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _MatchDart =
    bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _RecoverNative =
    Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _RecoverDart =
    int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _CreateIncomingNative =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Pointer<Utf8>>,
    );
typedef _CreateIncomingDart =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Pointer<Utf8>>,
    );
typedef _PublishNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Bool,
      Uint64,
      Int64,
      Pointer<Uint64>,
      Pointer<Int64>,
      Pointer<Pointer<Utf8>>,
    );
typedef _PublishDart =
    int Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      bool,
      int,
      int,
      Pointer<Uint64>,
      Pointer<Int64>,
      Pointer<Pointer<Utf8>>,
    );
typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class _Api {
  _Api(DynamicLibrary library)
    : open = library.lookupFunction<_OpenNative, _OpenDart>(
        'veil_fs_folder_open',
      ),
      matches = library.lookupFunction<_MatchNative, _MatchDart>(
        'veil_fs_folder_matches_root',
      ),
      recover = library.lookupFunction<_RecoverNative, _RecoverDart>(
        'veil_fs_folder_recover',
      ),
      createIncoming = library
          .lookupFunction<_CreateIncomingNative, _CreateIncomingDart>(
            'veil_fs_folder_create_incoming',
          ),
      writer = VeilFileWriter(library),
      publish = library.lookupFunction<_PublishNative, _PublishDart>(
        'veil_fs_folder_publish',
      ),
      close = library.lookupFunction<_CloseNative, _CloseDart>(
        'veil_fs_folder_close',
      ),
      free = library.lookupFunction<_FreeNative, _FreeDart>('veil_free_string');

  final _OpenDart open;
  final _MatchDart matches;
  final _RecoverDart recover;
  final _CreateIncomingDart createIncoming;
  final VeilFileWriter writer;
  final _PublishDart publish;
  final _CloseDart close;
  final _FreeDart free;

  bool freeError(Pointer<Pointer<Utf8>> error) {
    final value = error.value;
    if (value == nullptr) return false;
    try {
      return value.toDartString() == 'folder publication is busy';
    } finally {
      free(value);
      error.value = nullptr;
    }
  }
}

/// An admitted, pinned root. Every producer/scan uses this same native
/// admission. A host must keep it open across recovery AND enumeration, and
/// close it in finally, including when its async work throws.
///
/// A supplied library is the explicit test seam used by other fs-beneath
/// bindings. The default path uses verifiedVeilLibrary's ABI gate;
/// missing symbols or an old library never select a pathname-rename fallback.
class NativeFolderSession {
  NativeFolderSession._(this.root, this._api, this._handle);
  final String root;
  final _Api _api;
  Pointer<Void> _handle;

  static NativeFolderSession open(String root, {DynamicLibrary? lib}) {
    _validate(root);
    final _Api api;
    try {
      api = _Api(lib ?? verifiedVeilLibrary());
    } catch (_) {
      throw const FolderFsFailure(FolderFsFailureKind.unavailable);
    }
    final path = root.toNativeUtf8();
    final error = calloc<Pointer<Utf8>>();
    try {
      final handle = api.open(path, error);
      final busy = api.freeError(error);
      if (handle == nullptr) {
        throw FolderFsFailure(
          busy ? FolderFsFailureKind.busy : FolderFsFailureKind.unavailable,
        );
      }
      return NativeFolderSession._(root, api, handle);
    } finally {
      calloc.free(path);
      calloc.free(error);
    }
  }

  static void _validate(String value) {
    if (value.contains('\u0000')) {
      throw const FormatException('Invalid folder path');
    }
    // UTF-8 encoding replaces unpaired UTF-16 surrogates. Refuse that lossy
    // conversion rather than let a remote name select another real filename.
    final units = value.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
          throw const FormatException('Invalid folder path');
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const FormatException('Invalid folder path');
      }
    }
  }

  Pointer<Void> get _live {
    if (_handle == nullptr) throw StateError('Folder admission is closed');
    return _handle;
  }

  void checkRoot() {
    final handle = _live;
    final path = root.toNativeUtf8();
    final error = calloc<Pointer<Utf8>>();
    try {
      final matches = _api.matches(handle, path, error);
      _api.freeError(error);
      if (!matches) {
        throw const FolderFsFailure(FolderFsFailureKind.rootChanged);
      }
    } finally {
      calloc.free(path);
      calloc.free(error);
    }
  }

  /// Discover only this protocol's intents, without entering hidden user
  /// directories or following links. Native recovery validates every record
  /// and walks from the pinned root; this discovery grants no write authority.
  /// An unreadable/invalid recovery state refuses the scan in its entirety.
  Future<void> recoverBeforeScan() => _recoverDirectory('', recursive: true);

  /// Only this target's parent can affect its replacement. Do not re-walk the
  /// whole tree for every downloaded file: full recovery belongs to the scan.
  Future<void> recoverBeforePublish(String target) {
    _validate(target);
    final parts = target.replaceAll(r'\', '/').split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException('Invalid folder path');
    }
    final parent = parts.take(parts.length - 1).join('/');
    return _recoverDirectory(
      parent.isEmpty ? '' : '$parent/',
      recursive: false,
      allowMissing: true,
    );
  }

  Future<void> _recoverDirectory(
    String prefix, {
    required bool recursive,
    bool allowMissing = false,
  }) async {
    checkRoot();
    final intent = RegExp(r'^\.xveil-[0-9a-f]{32}\.intent$');
    Future<void> walk(Directory directory, String prefix) async {
      final entries = directory.listSync(followLinks: false);
      for (final entry in entries) {
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final relative = '$prefix$name';
        if (intent.hasMatch(name)) {
          // A link bearing an intent name must be refused, not skipped as
          // evidence of an empty directory. The native walk refuses it.
          recover(relative);
        } else if (recursive &&
            entry is Directory &&
            !folderMirrorSkipsName(name)) {
          // A POSIX directory can literally contain a backslash; it is not
          // the separator accepted by the cross-platform relative-path ABI.
          if (name.contains(r'\')) {
            throw const FolderFsFailure(FolderFsFailureKind.recovery);
          }
          await walk(entry, '$relative/');
        }
      }
    }

    try {
      final directory = Directory(prefix.isEmpty ? root : '$root/$prefix');
      if (allowMissing &&
          FileSystemEntity.typeSync(directory.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
        checkRoot();
        return;
      }
      await walk(directory, prefix);
      checkRoot();
    } on FolderFsFailure {
      rethrow;
    } on FileSystemException {
      throw const FolderFsFailure(FolderFsFailureKind.recovery);
    }
  }

  bool recover(String relativeIntent) {
    _validate(relativeIntent);
    final handle = _live;
    final path = relativeIntent.toNativeUtf8();
    final error = calloc<Pointer<Utf8>>();
    try {
      final result = _api.recover(handle, path, error);
      final busy = _api.freeError(error);
      if (result < 0) {
        throw FolderFsFailure(
          busy ? FolderFsFailureKind.busy : FolderFsFailureKind.recovery,
        );
      }
      return result == 1;
    } finally {
      calloc.free(path);
      calloc.free(error);
    }
  }

  VeilCreatedSink createIncoming(String incoming) {
    _validate(incoming);
    final handle = _live;
    final path = incoming.toNativeUtf8();
    final error = calloc<Pointer<Utf8>>();
    try {
      final file = _api.createIncoming(handle, path, error);
      final busy = _api.freeError(error);
      if (file == nullptr) {
        throw FolderFsFailure(
          busy ? FolderFsFailureKind.busy : FolderFsFailureKind.preparation,
        );
      }
      return _api.writer.own(file);
    } finally {
      calloc.free(path);
      calloc.free(error);
    }
  }

  LocalFile publish(
    String path,
    String incoming, {
    required LocalFile? expected,
  }) {
    _validate(path);
    _validate(incoming);
    if (expected != null && expected.size < 0) {
      throw const FormatException('Invalid file size');
    }
    final handle = _live;
    final destination = path.toNativeUtf8();
    final prepared = incoming.toNativeUtf8();
    final size = calloc<Uint64>();
    final modified = calloc<Int64>();
    final error = calloc<Pointer<Utf8>>();
    try {
      final result = _api.publish(
        handle,
        destination,
        prepared,
        expected != null,
        expected?.size ?? 0,
        expected?.modifiedAtMs ?? 0,
        size,
        modified,
        error,
      );
      final busy = _api.freeError(error);
      if (result == 0) throw const FolderSyncLocalChanged();
      if (result != 1) {
        throw FolderFsFailure(
          busy ? FolderFsFailureKind.busy : FolderFsFailureKind.publication,
        );
      }
      return LocalFile(
        path: path,
        size: size.value,
        modifiedAtMs: modified.value,
      );
    } finally {
      calloc.free(destination);
      calloc.free(prepared);
      calloc.free(size);
      calloc.free(modified);
      calloc.free(error);
    }
  }

  void close() {
    if (_handle == nullptr) return;
    final handle = _handle;
    _handle = nullptr;
    _api.close(handle);
  }
}
