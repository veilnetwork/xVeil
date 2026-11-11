import 'dart:io';

import '../core/document_export.dart';
import '../core/diagnostic_journal.dart';
import '../data/folder_publication.dart';
import '../data/folder_saved_versions.dart';
import '../domain/range_source.dart';

/// Classification compares source-owned categories only. Never stringify an
/// exception, retain it in a report, or serialize a provider stage verbatim.
FolderSavedDiagnosticFailure folderSavedFailureCode(
  Object error,
) => switch (error) {
  FolderFsFailure(:final kind) => switch (kind) {
    FolderFsFailureKind.unavailable => FolderSavedDiagnosticFailure.unavailable,
    FolderFsFailureKind.busy => FolderSavedDiagnosticFailure.busy,
    FolderFsFailureKind.rootChanged => FolderSavedDiagnosticFailure.rootChanged,
    FolderFsFailureKind.recovery => FolderSavedDiagnosticFailure.recovery,
    FolderFsFailureKind.preparation => FolderSavedDiagnosticFailure.preparation,
    FolderFsFailureKind.reading => FolderSavedDiagnosticFailure.reading,
    FolderFsFailureKind.publication => FolderSavedDiagnosticFailure.publication,
    FolderFsFailureKind.cleanup => FolderSavedDiagnosticFailure.cleanup,
  },
  FolderSavedVersionChanged() => FolderSavedDiagnosticFailure.changed,
  FileSystemException() => FolderSavedDiagnosticFailure.reading,
  RangeSourceUnreadable() => FolderSavedDiagnosticFailure.reading,
  DocumentExportException(permissionDenied: true) =>
    FolderSavedDiagnosticFailure.destinationPermission,
  DocumentExportException(:final stage) => switch (stage) {
    'open' => FolderSavedDiagnosticFailure.destinationOpen,
    'write' => FolderSavedDiagnosticFailure.destinationWrite,
    'finish' => FolderSavedDiagnosticFailure.destinationFinish,
    _ => FolderSavedDiagnosticFailure.other,
  },
  _ => FolderSavedDiagnosticFailure.other,
};

class FolderSavedExportCancellation {
  bool cancelled = false;
  ExportDocument? _document;
  Future<void> cancel() async {
    cancelled = true;
    await _document?.abort();
  }
}

/// A read-only copy to a user-chosen destination. No current mirror target,
/// sync base or recovery copy is rewritten. The root admission is released by
/// access.open before the picker; the source remains pinned by descriptor.
Future<bool> exportFolderSavedVersion({
  required FolderSavedVersionAccess access,
  required String root,
  required FolderSavedVersion version,
  required bool Function() stillCurrent,
  ExportDocumentPicker pick = openExportDocument,
  FolderSavedExportCancellation? cancellation,
}) async {
  void check() {
    if (cancellation?.cancelled == true || !stillCurrent()) {
      throw const FolderSavedOperationCancelled();
    }
  }

  check();
  final file = await access.open(root, version);
  ExportDocument? document;
  var finished = false;
  try {
    check();
    document = await pick(version.exportName);
    if (document == null) return false;
    if (cancellation != null) cancellation._document = document;
    check();
    await for (final chunk in rangeChunks(file.source, 0, file.source.size)) {
      check();
      await document.write(chunk);
      check();
    }
    check();
    if (!file.unchanged()) throw const FolderSavedVersionChanged();
    await document.finish();
    finished = true;
    return true;
  } finally {
    try {
      if (!finished) await document?.abort();
    } finally {
      if (cancellation != null) cancellation._document = null;
      await file.source.dispose();
    }
  }
}
