import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

Uint8List _key(String value) => Uint8List.fromList(utf8.encode(value));
Uint8List _bytes(int length) {
  final random = Random(length);
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

class _RecordingStore extends FakeKvLogStore {
  final commits = <List<KvLogOp>>[];
  bool rejectPublication = false;

  @override
  int commit(List<KvLogOp> ops) {
    commits.add(List.of(ops));
    if (rejectPublication &&
        ops.whereType<PutOp>().any(
          (op) => utf8.decode(op.key).startsWith('file:'),
        )) {
      throw StateError('injected publication failure');
    }
    return super.commit(ops);
  }
}

Map _gc(_RecordingStore raw) =>
    jsonDecode(utf8.decode(raw.get(Ns.settings, _key('file_chunk_gc'))!))
        as Map;

void main() {
  for (final asynchronous in [false, true]) {
    group(asynchronous ? 'async' : 'sync', () {
      late _RecordingStore raw;
      late FileStore sync;
      late AsyncFileStore async;
      setUp(() {
        raw = _RecordingStore();
        sync = FileStore(raw);
        async = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      });
      Future<void> write(String id, Uint8List bytes) async {
        if (asynchronous) {
          await async.storeFile(id, bytes, name: 'fixture');
        } else {
          sync.storeFile(id, bytes, name: 'fixture');
        }
      }

      Future<Uint8List?> read(String id) async =>
          asynchronous ? await async.loadFile(id) : sync.loadFile(id);

      test('small creates and empty replacements publish atomically', () async {
        var previousLength = 0;
        for (final length in [0, 1, 64000, 70000, 0]) {
          raw.commits.clear();
          final data = _bytes(length);
          await write('journal', data);
          final atomic = length == 0 || previousLength == 0;
          expect(raw.commits, hasLength(atomic ? 1 : 2));
          if (atomic) expect(raw.commits.single.length, lessThanOrEqualTo(64));
          previousLength = length;
          expect(await read('journal'), data);
          expect(raw.count(Ns.fileChunks), (length + 3799) ~/ 3800);
          expect(_gc(raw)['live'], raw.count(Ns.fileChunks));
          raw.commits.clear();
          await write('journal', data);
          expect(raw.commits, isEmpty, reason: 'idempotent re-store');
        }
        await write('other', _bytes(9000));
        expect(await read('journal'), isEmpty);
        expect(await read('other'), _bytes(9000));
      });

      test(
        'failed small creation leaves no chunks or metadata changes',
        () async {
          await write('journal', _bytes(9000));
          final metadata = raw.get(Ns.settings, _key('file:journal'))!;
          final cursor = raw.get(Ns.settings, _key('file_next_log'))!;
          final accounting = raw.get(Ns.settings, _key('file_chunk_gc'))!;
          final before = raw.count(Ns.fileChunks);
          raw.commits.clear();
          raw.rejectPublication = true;
          await expectLater(write('fresh', _bytes(64000)), throwsStateError);
          expect(await read('journal'), _bytes(9000));
          expect(raw.count(Ns.fileChunks), before);
          expect(raw.get(Ns.settings, _key('file:journal')), metadata);
          expect(raw.get(Ns.settings, _key('file:fresh')), isNull);
          expect(raw.get(Ns.settings, _key('file_next_log')), cursor);
          expect(raw.get(Ns.settings, _key('file_chunk_gc')), accounting);
          expect(raw.commits, hasLength(1));
          raw.rejectPublication = false;
          raw.commits.clear();
          await write('fresh', _bytes(64000));
          expect(raw.commits, hasLength(1));
          expect(await read('fresh'), _bytes(64000));
          expect(await read('journal'), _bytes(9000));
          expect(_gc(raw)['live'], raw.count(Ns.fileChunks));
        },
      );

      test(
        'operation budget includes publication records and preserves namespace kinds',
        () async {
          for (final chunks in [61, 62]) {
            raw.commits.clear();
            await write('fresh-$chunks', _bytes(chunks * 3800));
            expect(raw.commits, hasLength(chunks == 61 ? 1 : 2));
            if (chunks == 61) expect(raw.commits.single, hasLength(64));
            expect(await read('fresh-$chunks'), _bytes(chunks * 3800));
          }
          for (final chunks in [30, 31]) {
            final id = 'replacement-$chunks';
            await write(id, _bytes(31 * 3800));
            raw.commits.clear();
            // Distinct length/content even when the chunk count stays 31.
            await write(id, _bytes(chunks * 3800 - 1));
            expect(
              raw.commits,
              hasLength(2),
              reason:
                  'nonempty replacements cannot mix log appends and deletes',
            );
            expect(await read(id), _bytes(chunks * 3800 - 1));
            expect(_gc(raw)['live'], raw.count(Ns.fileChunks));
          }
        },
      );

      test(
        'large fallback retains the old file if final publication fails',
        () async {
          await write('journal', _bytes(100));
          raw.rejectPublication = true;
          raw.commits.clear();
          await expectLater(
            write('journal', _bytes(100 * 3800)),
            throwsStateError,
          );
          expect(await read('journal'), _bytes(100));
          expect(raw.commits, hasLength(3));
          expect(raw.commits[0], hasLength(65));
          expect(raw.commits[1], hasLength(37));
          expect(
            _gc(raw)['live'],
            raw.count(Ns.fileChunks),
            reason: 'committed orphan chunks must remain counted',
          );
        },
      );
    });
  }

  test(
    'streamed replacements retain old pieces until final publication',
    () async {
      for (final oldChunks in [58, 59]) {
        final raw = _RecordingStore();
        final store = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
        final original = _bytes(oldChunks * 3800);
        await store.storeFilePiece(
          'stream',
          0,
          1,
          original.length,
          original.length,
          original,
        );
        final metadata = raw.get(Ns.settings, _key('file:stream'))!;
        raw.rejectPublication = true;
        await expectLater(
          store.storeFile('stream', _bytes(100)),
          throwsStateError,
        );
        expect(await store.loadFile('stream'), original);
        expect(raw.get(Ns.settings, _key('file:stream')), metadata);
        expect(raw.count(Ns.fileChunks), oldChunks + 1);
        expect(_gc(raw)['live'], oldChunks + 1);
        raw.rejectPublication = false;
        // Retry in a fresh store so the budget boundary is independent of orphans.
        final clean = _RecordingStore();
        final retry = AsyncFileStore(SyncWrappedAsyncKvLogStore(clean));
        await retry.storeFilePiece(
          'stream',
          0,
          1,
          original.length,
          original.length,
          original,
        );
        clean.commits.clear();
        await retry.storeFile('stream', _bytes(100));
        expect(clean.commits, hasLength(2));
        expect(await retry.loadFile('stream'), _bytes(100));
        expect(clean.get(Ns.settings, _key('filepiece:stream:0')), isNull);
        expect(clean.count(Ns.fileChunks), 1);
        expect(_gc(clean)['live'], 1);
      }
    },
  );
}
