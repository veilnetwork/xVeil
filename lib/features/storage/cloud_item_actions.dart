import 'dart:io';
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
  try {
    // The bytes may live only on another device. Waiting for them is the whole
    // point of the action, so unlike a preview this one blocks.
    if (!await service.ensureLocal(item)) return CloudExportResult.failed;
    final String? destination;
    if (Platform.isAndroid || Platform.isIOS) {
      // saveFile wants every byte up front on mobile, which an item of any
      // size cannot promise, so there the destination is app documents.
      destination =
          '${(await getApplicationDocumentsDirectory()).path}/'
          '${safeCloudExportName(item.name)}';
    } else {
      destination = await FilePicker.saveFile(
        fileName: safeCloudExportName(item.name),
      );
    }
    if (destination == null) return CloudExportResult.cancelled;
    // Written beside the target and renamed only once whole: picking an
    // existing file must not destroy it because the copy failed halfway, and a
    // truncated file that looks complete is worse than none.
    final partial = File('$destination.part');
    var written = 0;
    final sink = partial.openWrite();
    try {
      const chunk = 4 * 1024 * 1024;
      while (written < item.size) {
        final want = (item.size - written) < chunk
            ? item.size - written
            : chunk;
        final part = await service.readContentRange(item, written, want);
        if (part == null || part.isEmpty) break;
        sink.add(part);
        written += part.length;
      }
    } finally {
      await sink.close();
    }
    if (written >= item.size) {
      await partial.rename(destination);
      return CloudExportResult.done;
    }
    await partial.delete();
    return CloudExportResult.failed;
  } catch (_) {
    return CloudExportResult.failed;
  }
}

/// A cloud item's name is whatever the user typed, so it may carry separators
/// that would place the export somewhere else entirely.
String safeCloudExportName(String value) {
  final sanitized = value.trim().replaceAll(RegExp(r'[/\\\x00]'), '_');
  return sanitized.isEmpty ? 'file' : sanitized;
}

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
