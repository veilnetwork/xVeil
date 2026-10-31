import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';

Uint8List _bytes(int size, int seed) =>
    Uint8List.fromList(List.generate(size, (i) => (i * 17 + seed) % 251));
Uint8List _key(String value) => Uint8List.fromList(utf8.encode(value));

class _Store extends FakeKvLogStore {
  final commits = <List<KvLogOp>>[];
  int? failAt, loseAt;
  @override
  int commit(List<KvLogOp> ops) {
    commits.add(List.of(ops));
    if (commits.length == failAt) throw StateError('fixture commit failed');
    final result = super.commit(ops);
    if (commits.length == loseAt) throw StateError('fixture reply lost');
    return result;
  }
}

class _Held extends SyncWrappedAsyncKvLogStore {
  _Held(super.inner);
  bool hold = false;
  bool publicationOnly = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<int> commit(List<KvLogOp> ops) async {
    if (hold &&
        (!publicationOnly ||
            ops.whereType<PutOp>().any(
              (op) => utf8.decode(op.key) == 'file:header',
            ))) {
      hold = false;
      entered.complete();
      await release.future;
    }
    return super.commit(ops);
  }
}

void _accounting(_Store raw) {
  final state =
      jsonDecode(utf8.decode(raw.get(Ns.settings, _key('file_chunk_gc'))!))
          as Map;
  expect(state['live'], raw.count(Ns.fileChunks));
}

void main() {
  late _Store raw;
  late AsyncFileStore files;
  final first = StoredFileWrite('new-tail', _bytes(64000, 1), name: 'segment');
  final header = StoredFileWrite('header', _bytes(6000, 2), name: 'header');
  setUp(() async {
    raw = _Store();
    files = AsyncFileStore(SyncWrappedAsyncKvLogStore(raw));
    await files.storeFile('header', _bytes(4000, 3));
    await files.storeFile('old-tail', _bytes(9000, 4));
    raw.commits.clear();
  });

  test(
    'largest admitted data stage stays within the operation ceiling',
    () async {
      final a = StoredFileWrite('edge', _bytes(61 * 3800, 1));
      final b = StoredFileWrite('header', _bytes(3800, 2));
      expect(await files.tryStoreFilePair(a, b), isTrue);
      expect(raw.commits, hasLength(2));
      expect(raw.commits.first, hasLength(64));
      expect(raw.commits.last.length, lessThanOrEqualTo(64));
      expect(await files.loadFile(a.id), a.bytes);
      expect(await files.loadFile(b.id), b.bytes);
      _accounting(raw);
    },
  );

  test('a due orphan sweep is left to the ordinary writer', () async {
    raw.commit([
      PutOp(
        Ns.settings,
        _key('file_chunk_gc'),
        _key(
          jsonEncode({
            'live': 12000,
            'armed': true,
            'retryAt': 0,
            'full': false,
          }),
        ),
      ),
    ]);
    raw.commits.clear();
    expect(await files.tryStoreFilePair(first, header), isFalse);
    expect(raw.commits, isEmpty);
    expect(await files.loadFile('header'), _bytes(4000, 3));
    await files.storeFile(first.id, first.bytes);
    await files.storeFile(header.id, header.bytes);
    expect(await files.loadFile(first.id), first.bytes);
    expect(await files.loadFile(header.id), header.bytes);
    _accounting(raw);
  });

  test(
    'two-stage replacement publishes both files and retires the old tail',
    () async {
      expect(
        await files.tryStoreFilePair(first, header, retireHints: ['old-tail']),
        isTrue,
      );
      expect(raw.commits, hasLength(2));
      expect(await files.loadFile('new-tail'), first.bytes);
      expect(await files.loadFile('header'), header.bytes);
      expect(await files.loadFile('old-tail'), isNull);
      for (final ops in raw.commits) {
        expect(ops.length, lessThanOrEqualTo(64));
        expect(
          ops.whereType<AppendLogOp>().isNotEmpty &&
              ops.whereType<DeleteLogOp>().isNotEmpty,
          isFalse,
        );
      }
      expect(
        raw.commits.first.whereType<PutOp>().any(
          (op) => utf8.decode(op.key) == 'file_next_log',
        ),
        isTrue,
      );
      _accounting(raw);
    },
  );

  test(
    'new pair with no deletions publishes in one bounded atomic commit',
    () async {
      final fresh = StoredFileWrite('fresh-header', _bytes(100, 5));
      expect(await files.tryStoreFilePair(first, fresh), isTrue);
      expect(raw.commits, hasLength(1));
      expect(await files.loadFile(first.id), first.bytes);
      expect(await files.loadFile(fresh.id), fresh.bytes);
      _accounting(raw);
    },
  );

  for (final stage in [1, 2]) {
    for (final lostReply in [false, true]) {
      test(
        '${lostReply ? 'lost reply' : 'failure'} at stage $stage is safely retryable',
        () async {
          if (lostReply) {
            raw.loseAt = stage;
          } else {
            raw.failAt = stage;
          }
          await expectLater(
            files.tryStoreFilePair(first, header, retireHints: ['old-tail']),
            throwsStateError,
          );
          final published = lostReply && stage == 2;
          expect(
            await files.loadFile('header'),
            published ? header.bytes : _bytes(4000, 3),
          );
          expect(
            await files.loadFile('new-tail'),
            published ? first.bytes : isNull,
          );
          expect(
            await files.loadFile('old-tail'),
            published ? isNull : _bytes(9000, 4),
          );
          _accounting(raw);
          final cursor = raw.get(Ns.settings, _key('file_next_log'))!;
          raw.failAt = raw.loseAt = null;
          raw.commits.clear();
          final retry = await files.tryStoreFilePair(
            first,
            header,
            retireHints: ['old-tail'],
          );
          if (!retry) {
            // The published result of a lost final reply uses the normal
            // idempotent fallback; never promise pair admission for an old tail.
            await files.storeFile(first.id, first.bytes);
            await files.storeFile(
              header.id,
              header.bytes,
              retireHints: ['old-tail'],
            );
          }
          expect(await files.loadFile(first.id), first.bytes);
          expect(await files.loadFile(header.id), header.bytes);
          _accounting(raw);
          if (!published) {
            final next = raw.get(Ns.settings, _key('file_next_log'))!;
            expect(
              int.parse(utf8.decode(next)),
              greaterThan(int.parse(utf8.decode(cursor))),
            );
          }
        },
      );
    }
  }

  test('unsupported layouts and budgets decline before any write', () async {
    final cases = [
      (StoredFileWrite('old-tail', first.bytes), header),
      (StoredFileWrite('empty', Uint8List(0)), header),
      (
        StoredFileWrite('large', Uint8List(StoredFilePairWriter.maxBytes)),
        header,
      ),
      // Total bytes fit, but two partial records would exceed 62 records.
      (
        StoredFileWrite('edge', Uint8List(61 * 3800 + 1)),
        StoredFileWrite('h', Uint8List(3799)),
      ),
      (first, StoredFileWrite('header', _bytes(4000, 3))),
    ];
    for (final (a, b) in cases) {
      raw.commits.clear();
      expect(await files.tryStoreFilePair(a, b), isFalse);
      expect(raw.commits, isEmpty);
    }
    await files.storeFilePiece('stream', 0, 2, 2, 4, _bytes(2, 1));
    raw.commits.clear();
    expect(
      await files.tryStoreFilePair(
        first,
        StoredFileWrite('stream', header.bytes),
      ),
      isFalse,
    );
    expect(raw.commits, isEmpty);
    await expectLater(
      files.tryStoreFilePair(first, first),
      throwsArgumentError,
    );
    await expectLater(
      files.tryStoreFilePair(first, header, retireHints: [first.id]),
      throwsArgumentError,
    );
  });

  test(
    'oversized publication metadata uses fallback without deleting anything',
    () async {
      await files.storeFile('wide', _bytes(62 * 3800, 1));
      raw.commits.clear();
      expect(
        await files.tryStoreFilePair(
          first,
          StoredFileWrite('wide', header.bytes),
        ),
        isFalse,
      );
      expect(raw.commits, isEmpty);
      expect(await files.loadFile('wide'), _bytes(62 * 3800, 1));
    },
  );

  test(
    'tiered files and malformed tier keys cannot enter volume publication',
    () async {
      final dir = await Directory.systemTemp.createTemp('xv-pair-tier-');
      addTearDown(() => dir.delete(recursive: true));
      final storage = HiddenVolumeStorage.fromAsyncStore(
        SyncWrappedAsyncKvLogStore(raw),
      );
      addTearDown(storage.close);
      storage.useOnDiskTier(dir, minBytes: 1);
      await storage.storeFilePiece('disk', 0, 1, 2, 2, _bytes(2, 9));
      raw.commits.clear();
      expect(
        await storage.tryStoreFilePair(
          first,
          StoredFileWrite('disk', header.bytes),
        ),
        isFalse,
      );
      expect(raw.commits, isEmpty);
      raw.commit([
        PutOp(Ns.settings, _key('ondisk:new-tail'), _key('invalid-json')),
      ]);
      raw.commits.clear();
      expect(await storage.tryStoreFilePair(first, header), isFalse);
      expect(raw.commits, isEmpty);
      expect(await storage.loadFile('disk'), _bytes(2, 9));
    },
  );

  test('accepted pair pins copied input and finishes before close', () async {
    final held = _Held(raw)..hold = true;
    final storage = HiddenVolumeStorage.fromAsyncStore(held);
    final a = _bytes(8000, 1), b = _bytes(9000, 2);
    final aBefore = Uint8List.fromList(a), bBefore = Uint8List.fromList(b);
    final writing = storage.tryStoreFilePair(
      StoredFileWrite('new', a),
      StoredFileWrite('header', b),
    );
    await held.entered.future;
    final closing = storage.close();
    a.fillRange(0, a.length, 0);
    b.fillRange(0, b.length, 0);
    final refused = expectLater(
      storage.tryStoreFilePair(first, header),
      throwsStateError,
    );
    held.release.complete();
    expect(await writing, isTrue);
    await closing;
    await refused;
    expect(await files.loadFile('new'), aBefore);
    expect(await files.loadFile('header'), bBefore);
    _accounting(raw);
  });

  test(
    'readers retain the old complete view until publication commits',
    () async {
      final held = _Held(raw)
        ..hold = true
        ..publicationOnly = true;
      final storage = HiddenVolumeStorage.fromAsyncStore(held);
      addTearDown(storage.close);
      final writing = storage.tryStoreFilePair(
        first,
        header,
        retireHints: ['old-tail'],
      );
      await held.entered.future;
      try {
        expect(await storage.loadFile('header'), _bytes(4000, 3));
        expect(await storage.loadFile('old-tail'), _bytes(9000, 4));
        expect(await storage.loadFile('new-tail'), isNull);
        _accounting(raw);
      } finally {
        held.release.complete();
        expect(await writing, isTrue);
      }
      expect(await storage.loadFile('header'), header.bytes);
      expect(await storage.loadFile('new-tail'), first.bytes);
      expect(await storage.loadFile('old-tail'), isNull);
    },
  );

  test(
    'erase drains an accepted pair without resurrecting its files',
    () async {
      final held = _Held(raw)..hold = true;
      final storage = HiddenVolumeStorage.fromAsyncStore(held);
      addTearDown(storage.close);
      final writing = storage.tryStoreFilePair(first, header);
      await held.entered.future;
      final erasing = storage.eraseSpace();
      final refused = expectLater(
        storage.tryStoreFilePair(first, header),
        throwsStateError,
      );
      held.release.complete();
      expect(await writing, isTrue);
      await erasing;
      await refused;
      expect(await storage.loadFile(first.id), isNull);
      expect(await storage.loadFile(header.id), isNull);
      expect(raw.count(Ns.fileChunks), 0);
    },
  );
}
