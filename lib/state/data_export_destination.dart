import '../core/document_export.dart';
import 'data_export.dart';

class DataExportCancelled implements Exception {
  const DataExportCancelled();
}

/// A route can disappear while source storage is still being read. Closing
/// the destination must not wait for that read (or for the next output chunk).
class DataExportCancellation {
  bool cancelled = false;
  ExportDocument? _document;
  Future<void> cancel() async {
    cancelled = true;
    await _document?.abort();
  }

  void attach(ExportDocument document) {
    _document = document;
  }

  void detach() {
    _document = null;
  }
}

/// Own the destination for the entire export, including a failed provider
/// close. Sources must already belong to the captured identity. The caller's
/// lease is checked after the picker and around every awaited output block.
Future<DataExportReport?> exportDataArchive({
  required DataExporter exporter,
  required String name,
  required bool Function() stillOurs,
  required bool includeIdentity,
  required bool includeFiles,
  String? password,
  void Function(int done, int total)? onProgress,
  ExportDocumentPicker pick = openExportDocument,
  DataExportCancellation? cancellation,
}) async {
  void checkOwner() {
    if (cancellation?.cancelled == true || !stillOurs()) {
      throw const DataExportCancelled();
    }
  }

  checkOwner();
  final document = await pick(name);
  if (document == null) return null;
  cancellation?.attach(document);
  var finished = false;
  try {
    checkOwner();
    final report = await exporter.run(
      sink: (bytes) async {
        checkOwner();
        await document.write(bytes);
        checkOwner();
      },
      password: password,
      includeIdentity: includeIdentity,
      includeFiles: includeFiles,
      onProgress: onProgress,
    );
    checkOwner();
    await document.finish();
    finished = true;
    return report;
  } finally {
    try {
      if (!finished) await document.abort();
    } finally {
      cancellation?.detach();
    }
  }
}
