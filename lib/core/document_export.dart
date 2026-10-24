import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

/// Deliberately contains no platform exception message, URI, path or filename.
class DocumentExportException implements Exception {
  const DocumentExportException(this.stage);
  final String stage;
  @override
  String toString() => 'Document export failed ($stage)';
}

Future<ExportDocument?> openExportDocument(String name) async {
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
    } catch (_) {
      throw const DocumentExportException('open');
    }
  }
  try {
    final path = await FilePicker.saveFile(fileName: name);
    if (path == null) return null;
    return await _FileExportDocument.open(File(path));
  } catch (_) {
    throw const DocumentExportException('open');
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
    } catch (_) {
      throw const DocumentExportException('write');
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
    } catch (_) {
      throw const DocumentExportException('finish');
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
    } catch (_) {
      throw const DocumentExportException('abort');
    }
  }
}

class _FileExportDocument extends _SequentialDocument {
  _FileExportDocument(this.target, this.writingFile, this.handle);
  final File target;
  final File writingFile;
  RandomAccessFile? handle;

  static Future<_FileExportDocument> open(File target) async {
    final random = Random.secure();
    final suffix = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final sibling = File('${target.path}.xveil-part-$suffix');
    try {
      return _FileExportDocument(
        target,
        sibling,
        await sibling.open(mode: FileMode.writeOnly),
      );
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      if (code != 1 && code != 13 && !(Platform.isWindows && code == 5)) {
        rethrow;
      }
      // NSSavePanel may grant only the chosen file, not its parent. As with
      // writeStreamedFile, direct replacement is the sandbox fallback after
      // the person has explicitly selected/confirmed that target.
      return _FileExportDocument(
        target,
        target,
        await target.open(mode: FileMode.writeOnly),
      );
    }
  }

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
      if (writingFile.path != target.path) {
        await writingFile.rename(target.path);
      }
      state = _DocumentState.finished;
    } catch (_) {
      throw const DocumentExportException('finish');
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
    if (failed) throw const DocumentExportException('abort');
  }
}
