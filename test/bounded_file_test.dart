import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/bounded_file.dart';
import 'package:xveil/domain/sovereign_recovery.dart';

class _GrowingFile implements File {
  bool cancelled = false;
  int chunks = 0;
  @override
  Future<int> length() async => 1;
  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    try {
      chunks++;
      yield [1, 2];
      chunks++;
      yield [3, 4];
      chunks++;
      yield [5, 6];
    } finally {
      cancelled = true;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test('size metadata does not replace the actual byte limit', () async {
    final small = PlatformFile(
      name: 'fixture',
      size: 9999999,
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    expect(await readPickedFileBytesBounded(small, maxBytes: 3), [1, 2, 3]);
    final large = PlatformFile(name: 'fixture', size: 0, bytes: Uint8List(4));
    await expectLater(
      readPickedFileBytesBounded(large, maxBytes: 3),
      throwsA(isA<FileReadLimitExceeded>()),
    );
  });

  test(
    'a file growing after stat is bounded and its stream is cancelled',
    () async {
      final file = _GrowingFile();
      await expectLater(
        readFileBytesBounded(file, maxBytes: 3),
        throwsA(isA<FileReadLimitExceeded>()),
      );
      expect(file.chunks, 2);
      expect(file.cancelled, isTrue);
    },
  );

  test(
    'stream chunks are copied before the producer reuses its buffer',
    () async {
      Stream<List<int>> reused() async* {
        final chunk = Uint8List.fromList([1]);
        yield chunk;
        chunk[0] = 2;
        yield chunk;
      }

      expect(await readByteStreamBounded(reused(), maxBytes: 2), [1, 2]);
    },
  );

  test('pathless picker streams accept the exact boundary', () async {
    final file = PlatformFile(
      name: 'fixture',
      size: 0,
      readStream: Stream.fromIterable([
        [1, 2],
        [3],
      ]),
    );
    expect(await readPickedFileBytesBounded(file, maxBytes: 3), [1, 2, 3]);
  });

  test(
    'a stale picker size cannot send an oversized file to readAsBytes',
    () async {
      final root = await Directory.systemTemp.createTemp('bounded-pick-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/fixture');
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(1025);
      await handle.close();
      await expectLater(
        readPickedFileBytesBounded(
          PlatformFile(name: 'fixture', size: 0, path: file.path),
          maxBytes: 1024,
        ),
        throwsA(isA<FileReadLimitExceeded>()),
      );
      await file.writeAsBytes([4, 5, 6]);
      expect(await readFileBytesBounded(file, maxBytes: 3), [4, 5, 6]);
    },
  );

  test(
    'every accepted Unicode certificate wrapper fits the file budget',
    () async {
      final bytes = Uint8List(38)..setRange(0, 5, [0x58, 0x56, 0x52, 0x43, 1]);
      final raw = SovereignRecoveryCertificate.fromBytes(bytes).toText();
      final text =
          '${'界' * (kMaxRecoveryCertificateTextChars - raw.length)}$raw';
      final encoded = Uint8List.fromList([
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode(text),
      ]);
      expect(encoded.length, greaterThan(kMaxRecoveryCertificateTextChars));
      final read = await readPickedFileTextBounded(
        PlatformFile(name: 'fixture', size: 0, bytes: encoded),
        maxBytes: kMaxRecoveryCertificateFileBytes,
      );
      expect(SovereignRecoveryCertificate.parse(read!).bytes, bytes);
    },
  );

  test('oversize errors contain neither source contents nor paths', () {
    expect(
      const FileReadLimitExceeded(123).toString(),
      'File exceeds the in-memory read limit',
    );
  });
}
