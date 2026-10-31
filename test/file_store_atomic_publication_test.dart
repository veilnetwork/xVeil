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
  final reads = <String>[];
  String? failRead;
  int recordReads = 0;
  bool rejectPublication = false;

  @override
  Uint8List? readLog(int namespace, int logId) {
    if (namespace == Ns.fileChunks) recordReads++;
    return super.readLog(namespace, logId);
  }
  bool losePublicationReply = false;

  @override
  Uint8List? get(int namespace, Uint8List key) {
    final name = utf8.decode(key);
    reads.add(name);
    if (name == failRead) throw StateError('injected read failure');
    return super.get(namespace, key);
  }

  @override
  int commit(List<KvLogOp> ops) {
    commits.add(List.of(ops));
    if (rejectPublication &&
        ops.whereType<PutOp>().any(
          (op) => utf8.decode(op.key).startsWith('file:'),
        )) {
      throw StateError('injected publication failure');
    }
    final sequence = super.commit(ops);
    if (losePublicationReply &&
        ops.whereType<PutOp>().any(
          (op) => utf8.decode(op.key).startsWith('file:'),
        )) {
      losePublicationReply = false;
      throw StateError('injected lost commit reply');
    }
    return sequence;
  }
}

Map _gc(_RecordingStore raw) =>
    jsonDecode(utf8.decode(raw.get(Ns.settings, _key('file_chunk_gc'))!))
        as Map;

void main() {
  test(
    'streamed whole reads and identical stores reuse one manifest',
    () async {
      final raw = _RecordingStore();
      final files = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      final bytes = _bytes(6000);
      for (var index = 0; index < 2; index++) {
        await files.storeFilePiece(
          'stream',
          index,
          2,
          3000,
          6000,
          Uint8List.sublistView(bytes, index * 3000, (index + 1) * 3000),
        );
      }
      raw.reads.clear();
      expect(await files.loadFile('stream'), bytes);
      expect(raw.reads.where((key) => key == 'file:stream'), hasLength(1));
      raw.reads.clear();
      raw.commits.clear();
      await files.storeFile('stream', bytes);
      expect(raw.reads.where((key) => key == 'file:stream'), hasLength(1));
      expect(raw.commits, isEmpty);
      raw.reads.clear();
      raw.recordReads = 0;
      expect(await files.loadFile('stream', maxBytes: 5999), isNull);
      expect(
        raw.recordReads,
        0,
        reason: 'size ceiling still precedes data reads',
      );
      expect(raw.reads.where((key) => key == 'file:stream'), hasLength(1));
    },
  );

  test(
    'a resized streamed replacement never reads the prior payload',
    () async {
      final raw = _RecordingStore();
      final files = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      for (var index = 0; index < 2; index++) {
        await files.storeFilePiece(
          'stream',
          index,
          2,
          3000,
          6000,
          _bytes(3000),
        );
      }
      raw.reads.clear();
      raw.recordReads = 0;
      final replacement = _bytes(7000);
      await files.storeFile('stream', replacement);
      expect(raw.recordReads, 0);
      expect(raw.reads.where((key) => key == 'file:stream'), hasLength(1));
      expect(await files.loadFile('stream'), replacement);
    },
  );

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

      test(
        're-store reads its manifest once and still verifies stored bytes',
        () async {
          final original = _bytes(6000);
          await write('journal', original);
          final changed = Uint8List.fromList(original);
          changed[0] ^= 1;
          var priorLength = original.length;
          for (final replacement in [original, changed, _bytes(7000)]) {
            raw.reads.clear();
            raw.recordReads = 0;
            await write('journal', replacement);
            expect(
              raw.reads.where((key) => key == 'file:journal'),
              hasLength(1),
            );
            expect(
              raw.recordReads,
              replacement.length == priorLength ? greaterThan(0) : 0,
              reason:
                  'equal sizes need actual bytes; different sizes cannot be equal',
            );
            priorLength = replacement.length;
            expect(await read('journal'), replacement);
          }
        },
      );

      test(
        'a repeated write repairs missing old bytes before reporting success',
        () async {
          final original = _bytes(6000);
          await write('journal', original);
          raw.commit([DeleteLogOp(Ns.fileChunks, 2)]);
          expect(await read('journal'), isNull);
          raw.reads.clear();
          raw.commits.clear();
          await write('journal', original);
          expect(raw.reads.where((key) => key == 'file:journal'), hasLength(1));
          expect(
            raw.commits,
            isNotEmpty,
            reason: 'a missing chunk cannot be treated as a no-op',
          );
          expect(await read('journal'), original);
        },
      );

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
    'async replacement retires a small obsolete file in its publication',
    () async {
      final raw = _RecordingStore();
      final store = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      await store.storeFile('header', _bytes(100));
      await store.storeFile('old-tail', _bytes(9000));
      await store.storeFile('new-tail', _bytes(12000));
      raw.commits.clear();
      await store.storeFile(
        'header',
        _bytes(200),
        retireHints: ['old-tail', 'old-tail', 'unknown'],
      );
      expect(raw.commits, hasLength(2));
      expect(await store.loadFile('header'), _bytes(200));
      expect(await store.loadFile('new-tail'), _bytes(12000));
      expect(await store.loadFile('old-tail'), isNull);
      expect(await store.deleteFileOps('old-tail'), isEmpty);
      expect(_gc(raw)['live'], raw.count(Ns.fileChunks));
      expect(raw.commits.last, hasLength(8));
    },
  );

  test(
    'retirement failure preserves the old header and every referenced file',
    () async {
      final raw = _RecordingStore();
      final store = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      await store.storeFile('header', _bytes(100));
      await store.storeFile('old-tail', _bytes(9000));
      await store.storeFile('new-tail', _bytes(12000));
      final oldMeta = raw.get(Ns.settings, _key('file:old-tail'));
      raw.rejectPublication = true;
      raw.commits.clear();
      await expectLater(
        store.storeFile('header', _bytes(200), retireHints: ['old-tail']),
        throwsStateError,
      );
      expect(raw.commits, hasLength(2));
      expect(await store.loadFile('header'), _bytes(100));
      expect(await store.loadFile('old-tail'), _bytes(9000));
      expect(await store.loadFile('new-tail'), _bytes(12000));
      expect(raw.get(Ns.settings, _key('file:old-tail')), oldMeta);
      expect(_gc(raw)['live'], raw.count(Ns.fileChunks));
      raw.rejectPublication = false;
      await store.storeFile('header', _bytes(200), retireHints: ['old-tail']);
      expect(await store.loadFile('header'), _bytes(200));
      expect(await store.loadFile('old-tail'), isNull);
      expect(
        _gc(raw)['live'],
        raw.count(Ns.fileChunks) + 1,
        reason:
            'the existing failed-publication retry reuses one orphan id; '
            'GC remains a conservative overestimate, not an undercount',
      );
    },
  );

  test(
    'a lost publication reply leaves a complete retryable new state',
    () async {
      final raw = _RecordingStore();
      final store = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      await store.storeFile('header', _bytes(100));
      await store.storeFile('old-tail', _bytes(9000));
      await store.storeFile('new-tail', _bytes(12000));
      raw.losePublicationReply = true;
      await expectLater(
        store.storeFile('header', _bytes(200), retireHints: ['old-tail']),
        throwsStateError,
      );
      // New facade over the same durable store; no retained in-memory plans.
      final retry = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      expect(await retry.loadFile('header'), _bytes(200));
      expect(await retry.loadFile('old-tail'), isNull);
      expect(await retry.loadFile('new-tail'), _bytes(12000));
      raw.commits.clear();
      await retry.storeFile('header', _bytes(200), retireHints: ['old-tail']);
      expect(raw.commits, isEmpty);
      expect(await retry.deleteFileOps('old-tail'), isEmpty);
      expect(_gc(raw)['live'], raw.count(Ns.fileChunks));
    },
  );

  test('retirement budget admits whole files including all metadata', () async {
    for (final count in [59, 60]) {
      final raw = _RecordingStore();
      final store = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      await store.storeFile('header', _bytes(100));
      await store.storeFile('tail', _bytes(count * 3800));
      await store.storeFile('small', _bytes(1000));
      raw.commits.clear();
      await store.storeFile(
        'header',
        _bytes(200),
        retireHints: ['tail', 'small'],
      );
      expect(raw.commits, hasLength(2));
      expect(raw.commits.last.length, lessThanOrEqualTo(64));
      if (count == 59) {
        expect(raw.commits.last, hasLength(64));
        expect(await store.loadFile('tail'), isNull);
        expect(await store.loadFile('small'), _bytes(1000));
      } else {
        expect(await store.loadFile('tail'), _bytes(count * 3800));
        expect(await store.loadFile('small'), isNull);
      }
      expect(_gc(raw)['live'], raw.count(Ns.fileChunks));
      for (final ops in raw.commits) {
        expect(
          ops.whereType<AppendLogOp>().isNotEmpty &&
              ops.whereType<DeleteLogOp>().isNotEmpty,
          isFalse,
        );
      }
    }
  });

  test(
    'optional retirement skips invalid, streamed and unreadable files',
    () async {
      final raw = _RecordingStore();
      final store = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      await store.storeFile('header', _bytes(100));
      await store.storeFile('unreadable', _bytes(200));
      await store.storeFilePiece('stream', 0, 1, 100, 100, _bytes(100));
      raw.commit([
        PutOp(Ns.settings, _key('file:bad'), _key('not-json')),
        PutOp(
          Ns.settings,
          _key('file:huge'),
          _key('{"base":1,"count":1099511627776}'),
        ),
      PutOp(
        Ns.settings,
        _key('file:overflow'),
        _key('{"base":9223372036854775807,"count":2}'),
      ),
      PutOp(
        Ns.settings,
        _key('file:max-count'),
        _key('{"base":1,"count":9223372036854775807}'),
      ),
      ]);
      raw.failRead = 'file:unreadable';
      raw.reads.clear();
      await store.storeFile(
        'header',
        _bytes(300),
      retireHints: ['bad', 'huge', 'overflow', 'max-count', 'stream', 'unreadable'],
      );
      expect(raw.reads.where((key) => key.startsWith('filepiece:')), isEmpty);
      raw.failRead = null;
      expect(await store.loadFile('header'), _bytes(300));
      expect(await store.loadFile('unreadable'), _bytes(200));
      expect(await store.loadFile('stream'), _bytes(100));
      expect(raw.get(Ns.settings, _key('file:bad')), _key('not-json'));
      expect(raw.get(Ns.settings, _key('file:huge')), isNotNull);
    expect(raw.get(Ns.settings, _key('file:overflow')), isNotNull);
    expect(raw.get(Ns.settings, _key('file:max-count')), isNotNull);
    },
  );

  test(
    'at most 64 hints are read and an unchanged file defers cleanup',
    () async {
      final raw = _RecordingStore();
      final store = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      await store.storeFile('tail', _bytes(100));
      final hints = [for (var n = 0; n < 80; n++) 'missing-$n', 'tail'];
      raw.reads.clear();
      await store.storeFile('header', _bytes(200), retireHints: hints);
      expect(
        raw.reads.where((key) => key.startsWith('file:missing-')),
        hasLength(64),
      );
      expect(await store.loadFile('tail'), _bytes(100));
      raw.commits.clear();
      await store.storeFile('header', _bytes(200), retireHints: ['tail']);
      expect(
        raw.commits,
        isEmpty,
        reason: 'same bytes do not force a publication',
      );
      expect(await store.loadFile('tail'), _bytes(100));
      final cleanup = await store.deleteFileOps('tail');
      expect(
        cleanup,
        isNotEmpty,
        reason: 'caller must finish deferred cleanup',
      );
      raw.commit(cleanup);
      expect(await store.loadFile('tail'), isNull);
      await expectLater(
        store.storeFile('header', _bytes(200), retireHints: ['header']),
        throwsArgumentError,
      );
    },
  );

  test(
    'creation with retirement keeps append and delete commits separate',
    () async {
      final raw = _RecordingStore();
      final store = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
      await store.storeFile('old', _bytes(100));
      raw.commits.clear();
      await store.storeFile('new', _bytes(200), retireHints: ['old']);
      expect(raw.commits, hasLength(2));
      expect(raw.commits.first.whereType<DeleteLogOp>(), isEmpty);
      expect(raw.commits.last.whereType<AppendLogOp>(), isEmpty);
      expect(await store.loadFile('old'), isNull);
      expect(await store.loadFile('new'), _bytes(200));
      expect(_gc(raw)['live'], raw.count(Ns.fileChunks));
    },
  );

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
