import 'dart:io';
import '../../domain/file_export.dart';
import '../../domain/file_names.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/cloud.dart';
import '../../state/cloud_service.dart';

/// What a caller needs to bring ONE cloud item in or out: the file-picker
/// import, the export back to an ordinary file, and the size line both of them
/// are shown next to. It lives apart from the cloud screen because the note
/// body renders single items too — an attachment chip has to import and export
/// through exactly the same path, not a second one that drifts.

enum CloudExportResult { done, cancelled, failed }

/// Pick a file and import it into [service]. Returns the new row, or null when
/// the picker was dismissed; import failures throw, as [CloudService] reports
/// them.
Future<CloudItem?> importPickedCloudFile(
  CloudService service, {
  String? folderId,
}) async {
  final picked = await FilePicker.pickFiles(
    allowMultiple: false,
    withData: false,
    withReadStream: false,
  );
  final path = picked?.files.single.path;
  if (picked == null || path == null) return null;
  final name = picked.files.single.name;
  _RangeFileReader? reader;
  try {
    final file = File(path);
    final size = await file.length();
    reader = _RangeFileReader(await file.open(mode: FileMode.read));
    return await service.importContent(
      name: name,
      size: size,
      readRange: reader.read,
      folderId: folderId,
      thumbnail: await _previewOf(file, name),
    );
  } finally {
    await reader?.close();
  }
}

/// Copy one item's content out of the volume and into an ordinary file.
///
/// [CloudService.ensureLocal] brings bytes onto this device but leaves them
/// encrypted and reachable only through the app; this is the other half — the
/// one that makes the storage usable from the rest of the machine.
Future<CloudExportResult> exportCloudItem(
  CloudService service,
  CloudItem item,
) async {
  if (item.contentId == null || item.deleted) return CloudExportResult.failed;
  if (service.isClosed) return CloudExportResult.failed;
  try {
    // The bytes may live only on another device. Waiting for them is the whole
    // point of the action, so unlike a preview this one blocks.
    if (!await service.ensureLocal(item)) return CloudExportResult.failed;
    final String? destination;
    if (Platform.isAndroid || Platform.isIOS) {
      // saveFile wants every byte up front on mobile, which an item of any
      // size cannot promise, so there the destination is app documents.
      //
      // A FREE name, not the item's. The destination was taken straight from
      // the name and the rename below REPLACES, so exporting an item called
      // `notes.txt` destroyed whatever was already called that - and the name
      // belongs to a shared volume, not necessarily to the person exporting.
      destination = uncontestedPath(
        (await getApplicationDocumentsDirectory()).path,
        safeCloudExportName(item.name),
      );
    } else {
      destination = await FilePicker.saveFile(
        fileName: safeCloudExportName(item.name),
      );
    }
    if (destination == null) return CloudExportResult.cancelled;
    // THE SAVE DIALOG IS THE WINDOW. It is the platform's, it stays open as
    // long as the user wants, and in all-online mode they can switch identity
    // while it is up: every node stays running, so this captured service kept
    // working and the copy below wrote one identity's plaintext to a path
    // chosen while looking at the other (report21 X21-H2). A service whose
    // identity has been left is closed, which is the signal.
    if (service.isClosed) return CloudExportResult.failed;
    // Straight to the chosen path, no `.part` sibling.
    //
    // The sibling was there to protect an existing file from a copy that
    // failed halfway, and on a sandboxed macOS build it could not be opened at
    // all: the save panel grants a read-write exception for the SELECTED path
    // only, so `open()` on `<dest>.part` returns "Operation not permitted" and
    // every export failed. The same discovery is written up in the chat
    // download path, which is why it writes direct too.
    //
    // What replaces the sibling is cleanup that always runs: a copy that did
    // not finish leaves no file at all, so there is never a truncated one that
    // looks complete.
    final complete = await writeStreamedFile(
      file: File(destination),
      size: item.size,
      read: (offset, want) => service.readContentRange(item, offset, want),
    );
    return complete ? CloudExportResult.done : CloudExportResult.failed;
  } catch (_) {
    return CloudExportResult.failed;
  }
}

/// A cloud item's name is whatever somebody typed, so it may carry separators
/// that would place the export somewhere else entirely.
///
/// Delegates. This was a third copy of the rule and the weakest of them: it
/// handled `/`, `\` and NUL, and let through `.` and `..` (which as a leaf
/// name the directory itself), every other control character, a bidi override
/// that reorders the extension a person reads, and a name of any length at
/// all.
String safeCloudExportName(String value) => safeFileLeaf(value);

String formatCloudBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
}

/// A small preview of an imported picture, or null when there is nothing to
/// preview. Decoding lives here rather than in the service: the state layer
/// stays free of image codecs and testable without a Flutter binding.
///
/// Failure is never fatal — a file that claims to be a picture and is not, or a
/// format this platform cannot decode, simply gets no preview.
Future<Uint8List?> _previewOf(File file, String name) async {
  const previewWidth = 96;
  const decodableCeiling = 32 * 1024 * 1024;
  final lower = name.toLowerCase();
  const extensions = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'];
  if (!extensions.any(lower.endsWith)) return null;
  try {
    // Decoding wants the whole picture in memory at once, so the very large
    // ones are left alone: a preview is not worth an out-of-memory on a phone.
    // Width only, so the shape survives.
    if (await file.length() > decodableCeiling) return null;
    final codec = await ui.instantiateImageCodec(
      await file.readAsBytes(),
      targetWidth: previewWidth,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    final bytes = data?.buffer.asUint8List();
    if (bytes == null || bytes.length > CloudService.maxThumbnailBytes) {
      return null;
    }
    return bytes;
  } catch (_) {
    return null;
  }
}

/// A RandomAccessFile has one mutable cursor. [ContentManifest.fromReader]
/// prefetches the next range, so serialize cursor moves without buffering the
/// whole source in memory.
class _RangeFileReader {
  _RangeFileReader(this._file);

  final RandomAccessFile _file;
  Future<void> _gate = Future.value();

  Future<Uint8List> read(int offset, int length) {
    final result = _gate.then((_) async {
      await _file.setPosition(offset);
      return Uint8List.fromList(await _file.read(length));
    });
    _gate = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> close() => _gate.then((_) => _file.close());
}
