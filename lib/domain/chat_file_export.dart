import '../core/document_export.dart';

/// Export the held attachment to a destination explicitly chosen by its owner.
/// Keep provider I/O bounded even for multi-GB attachments. An interrupted read
/// or refused close never counts as saved. No app-private plaintext staging.
Future<bool> exportChatFile({
  required String name,
  required int size,
  required Future<List<int>?> Function(int offset, int want) read,
  required bool Function() stillOurs,
  ExportDocumentPicker pick = openExportDocument,
}) async {
  void checkOwner() {
    if (!stillOurs()) throw const DocumentExportException('owner');
  }

  checkOwner();
  if (size < 0) throw const DocumentExportException('size');
  final document = await pick(name);
  if (document == null) return false;
  try {
    checkOwner();
    var offset = 0;
    while (offset < size) {
      final want = (size - offset).clamp(0, 4 * 1024 * 1024);
      final bytes = await read(offset, want);
      checkOwner();
      if (bytes == null || bytes.isEmpty || bytes.length > want) {
        throw const DocumentExportException('read');
      }
      await document.write(bytes);
      checkOwner();
      offset += bytes.length;
    }
    await document.finish();
    return true;
  } catch (error, stack) {
    Error.throwWithStackTrace(
      await abortFailedDocument(document, error),
      stack,
    );
  }
}
