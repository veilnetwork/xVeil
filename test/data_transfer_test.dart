import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/data_transfer.dart';

/// A KDF cost nobody would ship, so the tests do not pay for the real one.
/// The archive carries its own parameters, which is exactly what lets this
/// work — and what the test at the end checks.
TransferSeal cheap() => TransferSeal(
  salt: Uint8List.fromList(List<int>.generate(16, (i) => i)),
  memoryKib: 1024,
  iterations: 1,
  parallelism: 1,
  chunkBytes: 64 * 1024,
);

TransferHeader headerFor({
  bool keys = false,
  bool files = false,
  Map<String, int> counts = const {},
  int fileBytes = 0,
}) => TransferHeader(
  createdMs: 1757000000000,
  nodeIdHex: 'aabbccdd',
  includesIdentity: keys,
  includesFiles: files,
  counts: counts,
  fileBytes: fileBytes,
);

Future<Uint8List> write(
  List<TransferRecord> records, {
  String? password,
  TransferHeader? header,
}) async {
  final out = BytesBuilder();
  final w = await DataTransferWriter.open(
    sink: (b) async => out.add(b),
    header: header ?? headerFor(),
    password: password,
    cost: password == null ? null : cheap(),
  );
  for (final r in records) {
    await w.add(r);
  }
  await w.close();
  return out.takeBytes();
}

Future<List<TransferRecord>> read(Uint8List bytes, {String? password}) async {
  final r = await DataTransferReader.open(Stream.value(bytes));
  return r.records(password: password).toList();
}

Uint8List body(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('open archive', () {
    test('records come back exactly as they went in', () async {
      final archive = await write([
        const TransferRecord(
          kind: TransferRecordKind.sync,
          meta: {'b': '{"v":1,"k":"contactUp","id":"peer","ts":7,"p":{}}'},
        ),
        TransferRecord(
          kind: TransferRecordKind.file,
          meta: const {'id': 'f1', 'name': 'note.txt'},
          payload: body('hello file'),
        ),
      ]);

      final got = await read(archive);
      expect(got, hasLength(2));
      expect(got[0].kind, TransferRecordKind.sync);
      expect(got[0].meta['b'], contains('contactUp'));
      expect(got[1].kind, TransferRecordKind.file);
      expect(got[1].meta['id'], 'f1');
      expect(utf8.decode(got[1].payload!), 'hello file');
    });

    test('the header is readable without reading the body', () async {
      final archive = await write([
        const TransferRecord(kind: TransferRecordKind.profile, meta: {'n': 1}),
      ], header: headerFor(keys: true, counts: {'sync': 12}, fileBytes: 99));

      final r = await DataTransferReader.open(Stream.value(archive));
      expect(r.header.nodeIdHex, 'aabbccdd');
      expect(r.header.includesIdentity, isTrue);
      expect(r.header.counts['sync'], 12);
      expect(r.header.fileBytes, 99);
      expect(r.header.isSealed, isFalse);
    });

    test('a file that is not one of ours is refused by its first line', () async {
      await expectLater(
        DataTransferReader.open(Stream.value(body('not an archive at all\n'))),
        throwsA(
          isA<TransferException>().having(
            (e) => e.failure,
            'failure',
            TransferFailure.notAnArchive,
          ),
        ),
      );
    });

    test('a later format generation says so, rather than "not ours"', () async {
      await expectLater(
        DataTransferReader.open(Stream.value(body('XVEILBK9\n{}\n'))),
        throwsA(
          isA<TransferException>().having(
            (e) => e.failure,
            'failure',
            TransferFailure.unsupportedVersion,
          ),
        ),
      );
    });
  });

  group('sealed archive', () {
    test('the right password gives the records back', () async {
      final archive = await write([
        TransferRecord(
          kind: TransferRecordKind.file,
          meta: const {'id': 'f1'},
          payload: body('secret bytes'),
        ),
      ], password: 'correct horse');

      final got = await read(archive, password: 'correct horse');
      expect(got, hasLength(1));
      expect(utf8.decode(got.single.payload!), 'secret bytes');
    });

    test('the body really is sealed — the plaintext is not in the file', () async {
      final archive = await write([
        TransferRecord(
          kind: TransferRecordKind.file,
          meta: const {'id': 'f1'},
          payload: body('the-quick-brown-fox'),
        ),
      ], password: 'pw');

      expect(
        utf8.decode(archive, allowMalformed: true),
        isNot(contains('the-quick-brown-fox')),
      );
      // The header, though, stays readable: that is the point of it.
      expect(utf8.decode(archive, allowMalformed: true), contains('aabbccdd'));
    });

    test('a wrong password is named as such, not as damage', () async {
      final archive = await write([
        const TransferRecord(kind: TransferRecordKind.profile),
      ], password: 'right');

      await expectLater(
        read(archive, password: 'wrong'),
        throwsA(
          isA<TransferException>().having(
            (e) => e.failure,
            'failure',
            TransferFailure.badPassword,
          ),
        ),
      );
    });

    test('a sealed archive read without a password says it needs one', () async {
      final archive = await write([
        const TransferRecord(kind: TransferRecordKind.profile),
      ], password: 'pw');

      await expectLater(
        read(archive),
        throwsA(
          isA<TransferException>().having(
            (e) => e.failure,
            'failure',
            TransferFailure.badPassword,
          ),
        ),
      );
    });

    test('editing the header breaks the body it describes', () async {
      final archive = await write([
        const TransferRecord(kind: TransferRecordKind.profile),
      ], header: headerFor(keys: false), password: 'pw');

      // Flip the claim "no keys inside" to "keys inside" — the lie a reader
      // would act on. Patched in the BYTES, same length, so nothing else about
      // the file changes: the header is authenticated as associated data, so
      // the body no longer opens.
      final needle = utf8.encode('"keys":false');
      final replacement = utf8.encode('"keys":true '); // same length
      var at = -1;
      for (var i = 0; i + needle.length <= archive.length; i++) {
        var hit = true;
        for (var j = 0; j < needle.length; j++) {
          if (archive[i + j] != needle[j]) {
            hit = false;
            break;
          }
        }
        if (hit) {
          at = i;
          break;
        }
      }
      expect(at, greaterThan(0), reason: 'the header should say keys:false');
      final edited = Uint8List.fromList(archive);
      edited.setRange(at, at + replacement.length, replacement);

      await expectLater(
        read(edited, password: 'pw'),
        throwsA(isA<TransferException>()),
      );
    });

    test('payloads larger than one chunk survive the round trip', () async {
      // Three chunks and a bit, at the cheap chunk size.
      final big = Uint8List(64 * 1024 * 3 + 777);
      for (var i = 0; i < big.length; i++) {
        big[i] = i & 0xff;
      }
      final archive = await write([
        TransferRecord(
          kind: TransferRecordKind.file,
          meta: const {'id': 'big'},
          payload: big,
        ),
      ], password: 'pw');

      final got = await read(archive, password: 'pw');
      expect(got.single.payload, equals(big));
    });
  });

  group('truncation', () {
    test('a cut sealed archive is refused, not read as short', () async {
      final big = Uint8List(64 * 1024 * 2);
      final archive = await write([
        TransferRecord(
          kind: TransferRecordKind.file,
          meta: const {'id': 'big'},
          payload: big,
        ),
      ], password: 'pw');

      final cut = Uint8List.sublistView(archive, 0, archive.length ~/ 2);
      await expectLater(
        read(cut, password: 'pw'),
        throwsA(
          isA<TransferException>().having(
            (e) => e.failure,
            'failure',
            TransferFailure.truncated,
          ),
        ),
      );
    });

    test('a cut open archive is refused too — the end marker is what says so',
        () async {
      final archive = await write([
        TransferRecord(
          kind: TransferRecordKind.file,
          meta: const {'id': 'f'},
          payload: body('0123456789' * 100),
        ),
      ]);

      final cut = Uint8List.sublistView(archive, 0, archive.length - 40);
      await expectLater(
        read(cut),
        throwsA(
          isA<TransferException>().having(
            (e) => e.failure,
            'failure',
            TransferFailure.truncated,
          ),
        ),
      );
    });
  });

  test('an archive that stops on a record boundary is refused', () async {
    // The nasty shape: every record in the file is COMPLETE, the file simply
    // ends. Nothing is half-read, so no length check can notice — only the
    // absent end marker says the rest was lost. Cutting mid-payload is caught
    // by the payload length and proves nothing about this.
    final out = BytesBuilder()
      ..add(utf8.encode('$kDataTransferMagic\n'))
      ..add(utf8.encode('${jsonEncode(headerFor().toJson())}\n'))
      ..add(utf8.encode('{"k":"file","id":"one","n":3}\n'))
      ..add(utf8.encode('abc'))
      ..add(utf8.encode('{"k":"file","id":"two","n":3}\n'))
      ..add(utf8.encode('def'));

    await expectLater(
      read(out.takeBytes()),
      throwsA(
        isA<TransferException>().having(
          (e) => e.failure,
          'failure',
          TransferFailure.truncated,
        ),
      ),
    );
  });

  test('a record from a newer vocabulary is skipped, and the rest still reads',
      () async {
    // Hand-built, because the writer cannot emit a kind it does not have.
    final out = BytesBuilder()
      ..add(utf8.encode('$kDataTransferMagic\n'))
      ..add(utf8.encode('${jsonEncode(headerFor().toJson())}\n'))
      ..add(utf8.encode('{"k":"fromTheFuture","n":5}\n'))
      ..add(utf8.encode('12345'))
      ..add(utf8.encode('{"k":"file","id":"after","n":3}\n'))
      ..add(utf8.encode('abc'))
      ..add(utf8.encode('{"k":"end"}\n'));

    final got = await read(out.takeBytes());
    expect(got, hasLength(1));
    expect(got.single.meta['id'], 'after');
    expect(utf8.decode(got.single.payload!), 'abc');
  });

  test('an archive carries the cost it was written with, so it still opens',
      () async {
    final archive = await write([
      const TransferRecord(kind: TransferRecordKind.profile),
    ], password: 'pw');

    final r = await DataTransferReader.open(Stream.value(archive));
    expect(r.header.seal!.memoryKib, cheap().memoryKib);
    expect(r.header.seal!.iterations, cheap().iterations);
    // And reading it uses those, not today's constants.
    expect(await r.records(password: 'pw').toList(), hasLength(1));
  });
}
