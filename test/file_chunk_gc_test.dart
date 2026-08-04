import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/error_journal.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

/// Counts the two scans that made the chunk collector quadratic (audit XV-20):
/// [count] walks every leaf of a namespace with no cache, and a sweep walks the
/// whole settings namespace ([kvKeys]) plus every page of the chunk log.
class _CountingStore implements KvLogStore {
  _CountingStore(this._inner);

  final FakeKvLogStore _inner;

  /// Full-namespace leaf walks. One per stored chunk was the bug.
  int countCalls = 0;

  /// Orphan sweeps, measured at their first act.
  int sweepScans = 0;

  /// Pages of the chunk log walked by those sweeps.
  int logPages = 0;

  void resetCounters() {
    countCalls = 0;
    sweepScans = 0;
    logPages = 0;
  }

  @override
  int count(int namespace) {
    countCalls++;
    return _inner.count(namespace);
  }

  @override
  List<Uint8List> kvKeys(int namespace) {
    if (namespace == Ns.settings) sweepScans++;
    return _inner.kvKeys(namespace);
  }

  @override
  List<KvLogEntry> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) {
    if (namespace == Ns.fileChunks) logPages++;
    return _inner.iterLogRange(
      namespace: namespace,
      start: start,
      end: end,
      limit: limit,
    );
  }

  @override
  int commit(List<KvLogOp> ops) => _inner.commit(ops);
  @override
  Uint8List? get(int namespace, Uint8List key) => _inner.get(namespace, key);
  @override
  Uint8List? readLog(int namespace, int logId) =>
      _inner.readLog(namespace, logId);
  @override
  int eraseNamespace(int namespace) => _inner.eraseNamespace(namespace);
  @override
  void scrub() => _inner.scrub();
  @override
  Uint8List exportKeys() => _inner.exportKeys();
  @override
  void close() => _inner.close();
}

Uint8List _k(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List _patterned(int n) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) % 256));

/// An AGED store: [files] whole-file records of [perFile] chunks each, every
/// one of them LIVE (referenced by its metadata). This is the shape that made
/// the collector useless — nothing to reclaim, so the trigger never released.
///
/// Written straight to the backing store, exactly as an install predating the
/// durable accounting would look: no `file_chunk_gc` key at all.
void _seedLiveChunks(
  FakeKvLogStore raw, {
  required int files,
  required int perFile,
}) {
  var next = 1;
  for (var f = 0; f < files; f++) {
    final base = next;
    for (var start = 0; start < perFile; start += 512) {
      final end = start + 512 < perFile ? start + 512 : perFile;
      raw.commit([
        for (var i = start; i < end; i++)
          AppendLogOp(Ns.fileChunks, base + i, Uint8List(4)),
      ]);
    }
    next += perFile;
    raw.commit([
      PutOp(
        Ns.settings,
        _k('file:live$f'),
        _k(
          jsonEncode({
            'name': 'live$f.bin',
            'size': perFile * 4,
            'segments': [
              [base, perFile],
            ],
          }),
        ),
      ),
    ]);
  }
  raw.commit([PutOp(Ns.settings, _k('file_next_log'), _k('$next'))]);
}

void main() {
  late FakeKvLogStore raw;
  late _CountingStore store;
  late FileStore files;

  setUp(() {
    raw = FakeKvLogStore();
    store = _CountingStore(raw);
    files = FileStore(store);
    errorJournal.clear();
  });

  tearDown(errorJournal.clear);

  group('XV-20 chunk-index accounting', () {
    test(
      'a full store pays ONE scan for 20 writes, not one per written chunk',
      () {
        // 12 000 live chunks: at the high-water mark with nothing left to
        // reclaim. ~45 MB of small files, which is where this is actually
        // reached — a blob big enough to "cause" it routes to the on-disk
        // tier instead.
        _seedLiveChunks(raw, files: 12, perFile: 1000);
        // Plus a worthwhile pile of crash orphans, so the one sweep this test
        // allows has a HIGH yield and clears the low-yield back-off. The
        // hysteresis is then the only thing that can hold the trigger down,
        // which is the point: a probe that removes it must fail HERE.
        raw.commit([
          for (var id = 12001; id <= 12200; id++)
            AppendLogOp(Ns.fileChunks, id, Uint8List(4)),
        ]);
        raw.commit([PutOp(Ns.settings, _k('file_next_log'), _k('12201'))]);
        expect(raw.count(Ns.fileChunks), 12200);
        store.resetCounters();

        for (var i = 0; i < 20; i++) {
          files.storeFile('extra$i', _patterned(100));
        }

        // The durable counter is seeded from ONE leaf walk, then never again.
        expect(
          store.countCalls,
          1,
          reason: 'count() is a full leaf walk; it belongs off the write path',
        );
        // THE HYSTERESIS. The first write sweeps, finds every record live,
        // frees nothing — and the trigger must then RELEASE. Without a low
        // mark the condition stays true from the cheap counter just as it did
        // from the expensive one, and all 20 writes pay the double scan.
        expect(
          store.sweepScans,
          1,
          reason: 'the trigger must release after a sweep that freed nothing',
        );
        expect(store.logPages, lessThanOrEqualTo(25));

        for (var i = 0; i < 20; i++) {
          expect(files.loadFile('extra$i'), _patterned(100));
        }
      },
    );

    test('the fruitless sweep is reported once, not once per write', () {
      _seedLiveChunks(raw, files: 12, perFile: 1000);

      for (var i = 0; i < 20; i++) {
        files.storeFile('extra$i', _patterned(100));
      }

      final full = errorJournal.entries
          .where((e) => e.kind == 'storage-file-chunks-full')
          .toList();
      expect(full, hasLength(1));
      expect(full.single.count, 1, reason: 'reported once, not 20 times');
      expect(full.single.type, 'FileChunkIndexFull');
    });

    test('repeated sweeps of the same full store report once', () {
      // The public collector bypasses the trigger, so this is the one way a
      // still-full store can be swept several times over. It is still ONE
      // fill: saying so once is the report, saying it every time is noise
      // that evicts other failures from the bounded journal.
      _seedLiveChunks(raw, files: 12, perFile: 1000);
      for (var i = 0; i < 3; i++) {
        expect(files.reclaimOrphanedFileChunkIds(), 0);
      }

      final full = errorJournal.entries
          .where((e) => e.kind == 'storage-file-chunks-full')
          .toList();
      expect(full, hasLength(1));
      expect(full.single.count, 1, reason: 'three sweeps, one report');
    });

    test('freeing space below the low mark re-arms the sweep', () {
      _seedLiveChunks(raw, files: 12, perFile: 1000);
      files.storeFile('probe', _patterned(100)); // sweeps once, then disarms
      store.resetCounters();

      // Still disarmed while the store stays above the low mark.
      files.deleteFile('live0'); // 12 001 → 11 001 live
      files.storeFile('after-one-delete', _patterned(100));
      expect(store.sweepScans, 0);

      // Drop below the low mark: room exists again, so the collector must be
      // willing to look again once the store refills.
      files.deleteFile('live1');
      files.deleteFile('live2'); // → 9 002 live
      files.deleteFile('live3'); // → 8 002 live

      // Refill past the high mark with whole-cap files. The FIRST write that
      // crosses it is still held off by the low-yield back-off; the next one
      // is not.
      for (var i = 0; i < 4; i++) {
        files.storeFile('refill$i', _patterned(kMaxStoredFileBytes));
      }
      expect(
        store.sweepScans,
        0,
        reason: 'a sweep that freed nothing must not be repeated immediately',
      );

      files.storeFile('refill4', _patterned(kMaxStoredFileBytes));
      expect(
        store.sweepScans,
        1,
        reason: 'once the back-off expires a re-armed store sweeps again',
      );
    });

    test('a sweep reconciles the estimate with the truth', () {
      // 11 000 live + 1 200 crash-orphaned records (appended, never published).
      _seedLiveChunks(raw, files: 11, perFile: 1000);
      raw.commit([
        for (var id = 11001; id <= 12200; id++)
          AppendLogOp(Ns.fileChunks, id, Uint8List(4)),
      ]);
      raw.commit([PutOp(Ns.settings, _k('file_next_log'), _k('12201'))]);

      files.storeFile('fresh', _patterned(100));

      expect(raw.count(Ns.fileChunks), 11001, reason: 'orphans reclaimed');
      // A real yield leaves the collector armed and clears the back-off, so
      // nothing here should have been reported as a full store.
      expect(
        errorJournal.entries.where((e) => e.kind == 'storage-file-chunks-full'),
        isEmpty,
      );
    });

    test('accounting survives a crash between chunk and metadata commits', () {
      // Chunks are appended in their own commits; the metadata lands last. A
      // counter bumped only at the end would not see records written by a run
      // that died in between — which is exactly the population the collector
      // exists to reclaim.
      files.storeFile('a', _patterned(200000)); // ~53 records
      final gc = raw.get(Ns.settings, _k('file_chunk_gc'))!;
      final live = (jsonDecode(utf8.decode(gc)) as Map)['live'];
      expect(live, raw.count(Ns.fileChunks));
      store.resetCounters();
      // Reopening does not re-seed: the accounting is durable, in the volume.
      FileStore(store).storeFile('b', _patterned(1000));
      expect(store.countCalls, 0);
    });
  });

  group('XV-20 async twin', () {
    test('the async write path pays one seed walk, then none', () async {
      _seedLiveChunks(raw, files: 12, perFile: 1000);
      store.resetCounters();
      final async = AsyncFileStore(SyncWrappedAsyncKvLogStore(store));

      for (var i = 0; i < 10; i++) {
        await async.storeFilePiece('cid', i, 10, 100, 1000, _patterned(100));
      }

      expect(store.countCalls, 1);
      expect(store.sweepScans, 1);
    });

    test('concurrent sweeps share one scan (single flight)', () async {
      _seedLiveChunks(raw, files: 11, perFile: 1000);
      store.resetCounters();
      final backing = SyncWrappedAsyncKvLogStore(store);

      // Separate instances on purpose: callers build a throwaway
      // AsyncFileStore per call, so the guard cannot live on the instance.
      final results = await Future.wait([
        AsyncFileStore(backing).reclaimOrphanedFileChunkIds(),
        AsyncFileStore(backing).reclaimOrphanedFileChunkIds(),
        AsyncFileStore(backing).reclaimOrphanedFileChunkIds(),
      ]);

      expect(store.sweepScans, 1, reason: 'one settings walk, not three');
      expect(results, [0, 0, 0]);
    });

    test('a wholesale purge forgets the accounting', () async {
      _seedLiveChunks(raw, files: 12, perFile: 1000);
      final backing = SyncWrappedAsyncKvLogStore(store);
      await AsyncFileStore(backing).storeFile('probe', _patterned(100));
      store.resetCounters();

      raw.eraseNamespace(Ns.fileChunks);
      await AsyncFileStore(backing).forgetChunkAccounting();
      await AsyncFileStore(backing).storeFile('after', _patterned(100));

      // Re-seeded from the now-empty namespace, so the stale 12 000 cannot
      // keep the trigger armed against records that no longer exist.
      expect(store.countCalls, 1);
      expect(store.sweepScans, 0);
    });
  });
}
