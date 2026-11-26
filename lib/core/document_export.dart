import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../domain/file_names.dart';
import '../data/storage/managed_fs_platform.dart';
import '../data/storage/managed_fs_posix_acl.dart' show writePosixStorageAcl;
import 'posix_file_facts.dart';
import '../data/storage/profile_preferences_file.dart'
    show FileReplacementAccess;
import '../data/storage/managed_fs_windows.dart' as windows;
import '../l10n/app_localizations.dart';
import 'filesystem_errors.dart';

const documentExportChannel = MethodChannel('xveil/document_export');
const kDocumentExportChunkBytes = 256 * 1024;

/// A user-selected destination, never an app-private plaintext staging file.
/// Each write awaits actual I/O; calls must be sequential. Success is reported
/// only after [finish], including the provider's close/flush, has completed.
abstract interface class ExportDocument {
  Future<void> write(List<int> bytes);
  Future<void> finish();
  Future<void> abort();
}

typedef ExportDocumentPicker = Future<ExportDocument?> Function(String name);

/// Native provider errors contain only stable codes. Managed filesystem
/// evidence is available to local UI and never included in the log text.
class DocumentExportException implements Exception {
  const DocumentExportException(
    this.stage, {
    this.permissionDenied = false,
    this.partialMayRemain = false,
    this.filesystemFailure,
  });
  final String stage;
  final bool permissionDenied;
  final bool partialMayRemain;
  final ManagedFsFailure? filesystemFailure;
  @override
  String toString() => 'Document export failed ($stage)';
}

String documentExportFailureText(AppL10n l, Object error, String fallback) {
  if (error is! DocumentExportException) return fallback;
  final message = error.permissionDenied
      ? l.chatFileSavePermissionDenied
      : switch (error.stage) {
          'access-policy' => l.exportAccessPolicyCannotBePreserved,
          'destination-changed' => l.exportDestinationChanged,
          'destination-type' => l.exportDestinationNotFile,
          _ => fallback,
        };
  return error.partialMayRemain
      ? '$message ${l.exportPartialMayRemain}'
      : message;
}

/// Preserve the original failure. Add the provider cleanup outcome without
/// retaining paths or raw exception text.
Future<Object> abortFailedDocument(
  ExportDocument? document,
  Object error,
) async {
  try {
    await document?.abort();
    return error;
  } catch (_) {
    final failure = _failure('abort', error);
    return DocumentExportException(
      failure.stage,
      permissionDenied: failure.permissionDenied,
      partialMayRemain: true,
      filesystemFailure: failure.filesystemFailure,
    );
  }
}

/// Classify only stable codes. Never retain provider messages, URIs or paths.
DocumentExportException _failure(String stage, Object error) {
  if (error is DocumentExportException) return error;
  final platform = error is PlatformException ? error : null;
  final filesystem = error is ManagedFsFailure ? error : null;
  return DocumentExportException(
    filesystem == null || filesystem.accessDenied
        ? stage
        : filesystem.kind == ManagedFsFailureKind.changed
        ? 'destination-changed'
        : filesystem.aclWarnings.isNotEmpty
        ? 'access-policy'
        : stage,
    permissionDenied:
        platform?.code == 'document_export_permission' ||
        filesystem?.accessDenied == true ||
        error is FileSystemException && fileSystemAccessDenied(error),
    partialMayRemain: platform?.details == 'partial_may_remain',
    filesystemFailure: filesystem,
  );
}

Future<ExportDocument?> openExportDocument(
  String name, {
  Future<bool> Function(ManagedFsFailure)? reviewAccess,
}) async {
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      final result = await documentExportChannel
          .invokeMapMethod<String, dynamic>('open', {
            'name': name,
            'mime': 'application/octet-stream',
          });
      if (result == null) return null;
      final id = result['id'];
      if (id is! String || id.isEmpty) {
        throw const DocumentExportException('open');
      }
      return _NativeExportDocument(id);
    } catch (error) {
      throw _failure('open', error);
    }
  }
  try {
    final path = await FilePicker.saveFile(fileName: name);
    if (path == null) return null;
    try {
      return await _FileExportDocument.open(
        File(path),
        reviewAccess: reviewAccess,
      );
    } on FileSystemException catch (error) {
      if (!Platform.isMacOS || !_failure('open', error).permissionDenied) {
        rethrow;
      }
      // The save panel may grant access to the selected file only. Ask for a
      // directory grant so the export can still be published in one step.
      final directory = await FilePicker.getDirectoryPath(
        initialDirectory: p.dirname(path),
      );
      if (directory == null) return null;
      return await _FileExportDocument.open(
        File(uncontestedPath(directory, p.basename(path))),
        replaceExisting: false,
      );
    }
  } catch (error) {
    throw _failure('open', error);
  }
}

enum _DocumentState { open, finishing, finished, aborted }

abstract class _SequentialDocument implements ExportDocument {
  _DocumentState state = _DocumentState.open;
  bool writing = false;
  Future<void>? activeWrite;
  Future<void>? aborting;

  @override
  Future<void> write(List<int> bytes) async {
    if (state != _DocumentState.open || writing) {
      throw const DocumentExportException('write-state');
    }
    writing = true;
    final drained = Completer<void>();
    activeWrite = drained.future;
    try {
      for (var offset = 0; offset < bytes.length;) {
        if (state != _DocumentState.open) {
          throw const DocumentExportException('write-state');
        }
        final end = min(offset + kDocumentExportChunkBytes, bytes.length);
        final part = bytes is Uint8List
            ? Uint8List.sublistView(bytes, offset, end)
            : Uint8List.fromList(bytes.sublist(offset, end));
        await writeChunk(part);
        offset = end;
      }
    } catch (error) {
      throw _failure('write', error);
    } finally {
      writing = false;
      drained.complete();
      activeWrite = null;
    }
  }

  Future<void> writeChunk(Uint8List bytes);

  @override
  Future<void> abort() => aborting ??= abortOnce();

  Future<void> abortOnce();

  void beginFinish() {
    if (state != _DocumentState.open || writing) {
      throw const DocumentExportException('finish-state');
    }
    state = _DocumentState.finishing;
  }
}

class _NativeExportDocument extends _SequentialDocument {
  _NativeExportDocument(this.id);
  final String id;

  @override
  Future<void> writeChunk(Uint8List bytes) => documentExportChannel
      .invokeMethod<void>('write', {'id': id, 'bytes': bytes});

  @override
  Future<void> finish() async {
    beginFinish();
    try {
      await documentExportChannel.invokeMethod<void>('finish', {'id': id});
      state = _DocumentState.finished;
    } catch (error) {
      throw _failure('finish', error);
    }
  }

  @override
  Future<void> abortOnce() async {
    if (state == _DocumentState.finished || state == _DocumentState.aborted) {
      return;
    }
    state = _DocumentState.aborted;
    await activeWrite;
    try {
      await documentExportChannel.invokeMethod<void>('abort', {'id': id});
    } catch (error) {
      throw _failure('abort', error);
    }
  }
}

class _FileExportDocument extends _SequentialDocument {
  _FileExportDocument(this.target, this.writingFile, this.handle, this.access);
  final File target;
  final File writingFile;
  RandomAccessFile? handle;
  final FileReplacementAccess? access;

  static Future<_FileExportDocument?> open(
    File target, {
    bool replaceExisting = true,
    Future<bool> Function(ManagedFsFailure)? reviewAccess,
  }) async {
    final type = FileSystemEntity.typeSync(target.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw const DocumentExportException('destination-type');
    }
    final random = Random.secure();
    final suffix = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final sibling = File(
      '${target.parent.path}${Platform.pathSeparator}.xveil-part-$suffix',
    );
    final FileReplacementAccess? access;
    try {
      access = replaceExisting ? FileReplacementAccess.capture(target) : null;
    } on ManagedFsFailure catch (error) {
      if (error.accessDenied) rethrow;
      throw DocumentExportException(
        'access-policy',
        filesystemFailure: _destinationAccessFailure(target, error),
      );
    }
    if (access?.witness case final witness?
        when reviewAccess != null && witness.aclWarning != null) {
      final failure = ManagedFsFailure(
        ManagedFsFailureKind.unsafe,
        path: target.path,
        aclWarnings: [witness.aclWarning!.withPolicy(canContinue: true)],
      );
      if (!await reviewAccess(failure)) return null;
      access!.checkDestination(target);
    }
    if (Platform.isWindows) {
      if (!windows.createPrivateFile(sibling.path)) {
        throw const DocumentExportException('destination-changed');
      }
    } else {
      await sibling.create(exclusive: true);
    }
    try {
      // A Darwin directory can pass its own ACL to a newly created empty
      // file. Remove the inherited ACL while the staging file is still empty.
      if ((Platform.isMacOS ? posixLstat(sibling.path) : null) case final facts?
          when facts.uid == posixEuid()) {
        if (readDarwinStorageAcl(sibling.path, facts)?.isNotEmpty == true) {
          posixSetModeForFile(
            sibling.path,
            facts,
            0x180,
            applyAcl: (fd) => writePosixStorageAcl(fd, ''),
          );
        }
      }
      const ManagedFsPlatform().restrictNewFile(sibling.path);
      return _FileExportDocument(
        target,
        sibling,
        await sibling.open(mode: FileMode.writeOnlyAppend),
        access,
      );
    } catch (error) {
      try {
        await sibling.delete();
      } on FileSystemException {
        // Preserve the original open error.
      }
      if (error is ManagedFsFailure && error.aclWarnings.isNotEmpty) {
        throw DocumentExportException(
          'access-policy',
          filesystemFailure: _destinationAccessFailure(target, error),
        );
      }
      rethrow;
    }
  }

  static ManagedFsFailure _destinationAccessFailure(
    File target,
    ManagedFsFailure error,
  ) => ManagedFsFailure(
    error.kind,
    unsafeReason: error.unsafeReason,
    path: target.path,
    posixError: error.posixError,
    aclWarnings: [
      for (final warning in error.aclWarnings)
        ManagedStorageAclWarning(
          path: target.path,
          fingerprint: warning.fingerprint,
          grants: warning.grants,
          inheritedGrants: warning.inheritedGrants,
          directory: false,
          owner: warning.owner,
          extendedAcl: warning.extendedAcl,
          canContinue: false,
          grantsArePotential: warning.grantsArePotential,
        ),
    ],
  );

  @override
  Future<void> writeChunk(Uint8List bytes) async {
    await handle!.writeFrom(bytes);
  }

  @override
  Future<void> finish() async {
    beginFinish();
    try {
      await handle!.flush();
      await handle!.close();
      handle = null;
      if (access?.witness != null) {
        try {
          access!.prepareReplacement(target, writingFile);
          access!.checkDestination(target);
        } on ManagedFsFailure catch (error) {
          if (error.accessDenied ||
              error.kind == ManagedFsFailureKind.changed) {
            rethrow;
          }
          throw DocumentExportException(
            'access-policy',
            filesystemFailure: _destinationAccessFailure(target, error),
          );
        }
        writingFile.renameSync(target.path);
      } else if (!const ManagedFsPlatform().publishFileNoReplace(
        writingFile.path,
        target.path,
      )) {
        throw const DocumentExportException('destination-changed');
      }
      state = _DocumentState.finished;
    } catch (error) {
      throw _failure('finish', error);
    }
  }

  @override
  Future<void> abortOnce() async {
    if (state == _DocumentState.finished || state == _DocumentState.aborted) {
      return;
    }
    state = _DocumentState.aborted;
    await activeWrite;
    var failed = false;
    try {
      await handle?.close();
    } catch (_) {
      failed = true;
    }
    handle = null;
    try {
      if (await writingFile.exists()) await writingFile.delete();
    } catch (_) {
      failed = true;
    }
    if (failed) {
      throw const DocumentExportException('abort', partialMayRemain: true);
    }
  }
}
