import 'dart:io';
import 'dart:typed_data';

/// A byte source the SENDER serves a large file from directly (the original file
/// on disk) — read + close closures over a [RandomAccessFile]. Reads are
/// SERIALIZED through an internal gate: the serve loop issues many reads and a
/// single-cursor RandomAccessFile throws "An async operation is currently
/// pending" under concurrent setPosition+read. The structural record matches
/// MessagingService's internal serve-source type, so it plugs straight in.
typedef VeilServeSource = ({
  Future<Uint8List> Function(int offset, int length) read,
  Future<void> Function() close,
});

/// Open [path] as a serialized serve source, or null if it can't be opened (the
/// file was moved/deleted, or a mobile cache/SAF path expired) — in which case
/// the offer can't be re-served and the sender must re-send.
Future<VeilServeSource?> veilSourceOpener(String path) async {
  final RandomAccessFile raf;
  try {
    raf = await File(path).open();
  } catch (_) {
    return null;
  }
  Future<void> gate = Future<void>.value();
  Future<Uint8List> read(int offset, int length) {
    final r = gate.then((_) => _readFully(raf, offset, length));
    gate = r.then((_) {}, onError: (_) {});
    return r;
  }

  return (read: read, close: raf.close);
}

/// Read EXACTLY [length] bytes at [offset], looping until satisfied or EOF
/// ([RandomAccessFile.read] may return fewer than asked on some platforms).
Future<Uint8List> _readFully(
    RandomAccessFile raf, int offset, int length) async {
  await raf.setPosition(offset);
  final out = BytesBuilder(copy: false);
  var remaining = length;
  while (remaining > 0) {
    final chunk = await raf.read(remaining);
    if (chunk.isEmpty) break; // EOF (source shorter than declared)
    out.add(chunk);
    remaining -= chunk.length;
  }
  return out.toBytes();
}
