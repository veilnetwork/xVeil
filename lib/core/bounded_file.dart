import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Whole-image import budget; large chat attachments retain their streaming
/// path. This is an input bound, separate from the normalized image size.
const kMaxImageImportBytes = 32 * 1024 * 1024;

class FileReadLimitExceeded implements Exception {
  const FileReadLimitExceeded(this.maxBytes);
  final int maxBytes;

  @override
  String toString() => 'File exceeds the in-memory read limit';
}

/// Cancel the subscription on overflow, including a file that grew after stat.
/// Never retain more than [maxBytes] of input, regardless of supplied metadata.
Future<Uint8List> readByteStreamBounded(
  Stream<List<int>> stream, {
  required int maxBytes,
}) async {
  RangeError.checkNotNegative(maxBytes, 'maxBytes');
  final builder = BytesBuilder();
  var length = 0;
  await for (final chunk in stream) {
    if (chunk.length > maxBytes - length) {
      throw FileReadLimitExceeded(maxBytes);
    }
    builder.add(chunk);
    length += chunk.length;
  }
  return builder.takeBytes();
}

Future<Uint8List> readFileBytesBounded(
  File file, {
  required int maxBytes,
}) async {
  RangeError.checkNotNegative(maxBytes, 'maxBytes');
  if (await file.length() > maxBytes) {
    throw FileReadLimitExceeded(maxBytes);
  }
  return readByteStreamBounded(file.openRead(), maxBytes: maxBytes);
}

/// Picker sizes may be stale (or zero on SAF). Check actual bytes/file/stream.
/// Callers must request withData:false so the picker does not allocate first.
Future<Uint8List?> readPickedFileBytesBounded(
  PlatformFile file, {
  required int maxBytes,
}) async {
  RangeError.checkNotNegative(maxBytes, 'maxBytes');
  final bytes = file.bytes;
  if (bytes != null) {
    if (bytes.length > maxBytes) throw FileReadLimitExceeded(maxBytes);
    return bytes;
  }
  final path = file.path;
  if (path != null) {
    return readFileBytesBounded(File(path), maxBytes: maxBytes);
  }
  final stream = file.readStream;
  return stream == null
      ? null
      : readByteStreamBounded(stream, maxBytes: maxBytes);
}

Future<String?> readPickedFileTextBounded(
  PlatformFile file, {
  required int maxBytes,
}) async {
  final bytes = await readPickedFileBytesBounded(file, maxBytes: maxBytes);
  return bytes == null ? null : utf8.decode(bytes);
}
