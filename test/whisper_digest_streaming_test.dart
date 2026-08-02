import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/whisper_model_store.dart';

/// The model file is ~57 MiB and was hashed with `readAsBytesSync` — the whole
/// thing in the heap at once, synchronously, on whatever isolate ran it. That
/// is a spike big enough to matter on exactly the low-end devices the
/// downloadable model exists for (audit XV-21).
///
/// Streaming only helps if it computes the SAME digest, and the digest gates
/// whether the file is kept: get it wrong and a good download is deleted as
/// corrupt, or a corrupt one is installed.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('whisper_digest_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<File> write(Uint8List bytes) async {
    final f = File('${tmp.path}/blob.bin');
    await f.writeAsBytes(bytes);
    return f;
  }

  test('matches the whole-file digest across many read chunks', () async {
    // Comfortably more than one read chunk, so the chunked conversion is
    // actually exercised — a single-chunk file would pass either way.
    final bytes = Uint8List.fromList(
      List<int>.generate(3 * 1024 * 1024, (i) => (i * 31 + 7) & 0xFF),
    );
    final f = await write(bytes);

    expect(
      await sha256OfFileStreaming(f),
      sha256.convert(bytes).toString(),
      reason: 'the digest decides whether the download is kept',
    );
  });

  test('an empty file still yields the empty digest, not an error', () async {
    final f = await write(Uint8List(0));
    expect(await sha256OfFileStreaming(f), sha256.convert(<int>[]).toString());
  });
}
