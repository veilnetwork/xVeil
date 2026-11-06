import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/file_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/roster.dart';
import 'package:xveil/domain/identity.dart';

Uint8List _key(String value) => Uint8List.fromList(utf8.encode(value));
const _rosterKey = 'master:roster';
const _fileKey = 'file:master:roster.v2';

List<RosterEntry> _rows(int count, {int tag = 1}) => [
  for (var i = 0; i < count; i++)
    RosterEntry(
      label: 'synthetic $tag $i',
      spaceKeys: Uint8List(64)..fillRange(0, 64, (tag + i) % 256),
      anonymous: i.isEven,
    ),
];

Uint8List _encode(List<RosterEntry> rows) => _key(
  jsonEncode([
    for (final row in rows)
      {
        'l': row.label,
        'k': base64Encode(row.spaceKeys),
        if (row.anonymous) 'a': 1,
      },
  ]),
);

class _Store extends SyncWrappedAsyncKvLogStore {
  _Store(this.raw) : super(raw);
  final KvLogStore raw;
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = false, closed = false, failRetire = false, failClear = false;
  bool failPublication = false;
  bool failLegacyRead = false;
  int commits = 0;

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) async {
    final value = await super.get(namespace, key);
    if (failLegacyRead &&
        namespace == Ns.settings &&
        utf8.decode(key) == _rosterKey) {
      throw StateError('refused legacy roster read');
    }
    if (hold && namespace == Ns.settings && utf8.decode(key) == _fileKey) {
      hold = false;
      entered.complete();
      await release.future;
    }
    return value;
  }

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    if (closed) throw StateError('closed fixture store');
    if (failPublication &&
        ops.whereType<PutOp>().any(
          (op) =>
              op.namespace == Ns.settings && utf8.decode(op.key) == _fileKey,
        )) {
      failPublication = false;
      throw StateError('refused roster file publication');
    }
    if (failRetire &&
        ops.whereType<DeleteLogOp>().any(
          (op) => op.namespace == Ns.fileChunks,
        )) {
      failRetire = false;
      throw StateError('refused roster retirement');
    }
    if (failClear &&
        ops.any(
          (op) => switch (op) {
            DeleteOp(:final namespace, :final key) =>
              namespace == Ns.settings && utf8.decode(key) == _rosterKey,
            PutOp(:final namespace, :final key, :final value) =>
              namespace == Ns.settings &&
                  utf8.decode(key) == _rosterKey &&
                  value.isEmpty,
            _ => false,
          },
        )) {
      failClear = false;
      throw StateError('refused stale roster cleanup');
    }
    final result = await super.commit(ops);
    commits++;
    return result;
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

Future<String> _outcome(Future<void> operation) =>
    operation.then((_) => 'ok', onError: (_) => 'error');

T _finish<T>(Future<T> operation, FakeAsync time) {
  var done = false;
  late T value;
  Object? error;
  operation.then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  time.flushMicrotasks();
  expect(done, isTrue);
  if (error != null) throw error!;
  return value;
}

void _expectRoster(List<RosterEntry>? actual, List<RosterEntry> expected) {
  expect(actual, isNotNull);
  expect(actual!.map((e) => e.label), expected.map((e) => e.label));
  expect(actual.map((e) => e.anonymous), expected.map((e) => e.anonymous));
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i].spaceKeys, expected[i].spaceKeys);
  }
}

void main() {
  final native = Platform.environment['XVEIL_NATIVE_ROSTER_LIFECYCLE'] == '1';
  Directory? directory;
  final owned = <_Store>[];
  var serial = 0;
  setUp(() async {
    if (native) {
      expect(
        ensureHiddenVolumeLoaded(
          dylibPath: Platform.environment['XVEIL_HV_DYLIB'],
        ),
        isTrue,
      );
      directory = await Directory.systemTemp.createTemp('xveil-roster-life-');
    }
  });
  tearDown(() async {
    for (final store in owned) {
      if (!store.closed) await store.close();
    }
    owned.clear();
    await directory?.delete(recursive: true);
    directory = null;
  });
  _Store createStore() {
    final KvLogStore raw = native
        ? HvKvLogStore(
            hv.HvSpace.create(
              path: '${directory!.path}/fixture-${serial++}.hv',
              password: _key('synthetic-roster-only'),
              argon: hv.ArgonPreset.min,
            ),
          )
        : FakeKvLogStore();
    final store = _Store(raw);
    owned.add(store);
    return store;
  }

  for (final size in [1, 24]) {
    group('rows=$size', () {
      test(
        'primary read errors propagate while an optional shadow cannot hide a valid file',
        () async {
          final raw = createStore();
          final storage = HiddenVolumeStorage.fromAsyncStore(raw);
          addTearDown(storage.close);
          await storage.saveRoster(_rows(size));
          raw.failLegacyRead = true;
          if (size == 1) {
            await expectLater(storage.loadRoster(), throwsStateError);
          } else {
            _expectRoster(await storage.loadRoster(), _rows(size));
            await storage.saveRoster(_rows(size, tag: 80));
            _expectRoster(await storage.loadRoster(), _rows(size, tag: 80));
          }
        },
      );

      test(
        'a pending reader cannot stall publication or mistake retirement for damage',
        () {
          fakeAsync((time) {
            final raw = createStore();
            final storage = HiddenVolumeStorage.fromAsyncStore(raw);
            _finish(storage.saveRoster(_rows(size)), time);
            raw.hold = true;
            final read = storage.loadRoster();
            time.flushMicrotasks();
            expect(raw.entered.isCompleted, isTrue);
            var saved = false;
            final write = _outcome(storage.saveRoster(_rows(1, tag: 80))).then((
              value,
            ) {
              saved = true;
              return value;
            });
            time.flushMicrotasks();
            final completedBeforeRelease = saved;
            raw.release.complete();
            time.flushMicrotasks();
            final readValue = _finish(read, time),
                writeResult = _finish(write, time);
            _finish(storage.close(), time);
            expect(
              completedBeforeRelease,
              isTrue,
              reason:
                  'accepted publication must not depend on a retired read reply',
            );
            expect(writeResult, 'ok');
            _expectRoster(readValue, _rows(1, tag: 80));
          });
        },
      );

      test('queued save freezes the entries and their key bytes', () async {
        final raw = createStore()..hold = true;
        final storage = HiddenVolumeStorage.fromAsyncStore(raw);
        addTearDown(storage.close);
        final entries = _rows(size);
        final save = storage.saveRoster(entries);
        await raw.entered.future;
        entries.first.spaceKeys.fillRange(0, 64, 200);
        entries.addAll(_rows(1, tag: 80));
        raw.release.complete();
        await save;
        _expectRoster(await storage.loadRoster(), _rows(size));
      });
      test('round trip and sequential no-op preserve every key', () async {
        final raw = createStore();
        final storage = HiddenVolumeStorage.fromAsyncStore(raw);
        addTearDown(storage.close);
        await storage.saveRoster(_rows(size));
        final commits = raw.commits;
        _expectRoster(await storage.loadRoster(), _rows(size));
        await storage.saveRoster(_rows(size));
        expect(raw.commits, commits);
        expect(await storage.hasFile('master:roster.v2'), size > 1);
      });
      test('a suspended save cannot publish into the next container', () {
        fakeAsync((time) {
          final a = createStore(), b = createStore();
          final storage = HiddenVolumeStorage.async(
            ({required password, required create}) async =>
                utf8.decode(password) == 'a' ? a : b,
          );
          expect(_finish(storage.open(password: 'a'), time), isTrue);
          a.hold = true;
          final write = _outcome(storage.saveRoster(_rows(size)));
          time.flushMicrotasks();
          expect(a.entered.isCompleted, isTrue);
          final next = storage.open(password: 'b');
          time.flushMicrotasks();
          a.release.complete();
          time.flushMicrotasks();
          expect(_finish(next, time), isTrue);
          final result = _finish(write, time);
          final loaded = _finish(storage.loadRoster(), time);
          _finish(storage.close(), time);
          expect(result, 'ok');
          expect(loaded, isNull, reason: 'B must not inherit the keys of A');
          expect(a.closed && b.closed, isTrue);
        });
      });

      test('an old read cannot borrow the next container roster', () {
        fakeAsync((time) {
          final a = createStore(), b = createStore();
          b.raw.commit([
            PutOp(Ns.settings, _key(_rosterKey), _encode(_rows(1, tag: 80))),
          ]);
          final storage = HiddenVolumeStorage.async(
            ({required password, required create}) async =>
                utf8.decode(password) == 'a' ? a : b,
          );
          expect(_finish(storage.open(password: 'a'), time), isTrue);
          _finish(storage.saveRoster(_rows(size)), time);
          a.hold = true;
          final oldRead = storage.loadRoster().then(
            (_) => 'borrowed',
            onError: (_) => 'refused',
          );
          time.flushMicrotasks();
          expect(a.entered.isCompleted, isTrue);
          final next = storage.open(password: 'b');
          time.flushMicrotasks();
          a.release.complete();
          time.flushMicrotasks();
          expect(_finish(next, time), isTrue);
          final result = _finish(oldRead, time);
          final current = _finish(storage.loadRoster(), time);
          _finish(storage.close(), time);
          expect(result, 'refused');
          _expectRoster(current, _rows(1, tag: 80));
        });
      });

      test('concurrent identical saves publish once', () async {
        final raw = createStore();
        final storage = HiddenVolumeStorage.fromAsyncStore(raw);
        addTearDown(storage.close);
        await Future.wait([
          for (var i = 0; i < 16; i++) storage.saveRoster(_rows(size)),
        ]);
        _expectRoster(await storage.loadRoster(), _rows(size));
        expect(raw.commits, 1);
      });

      for (final erase in [false, true]) {
        test('accepted save drains before ${erase ? 'erase' : 'close'}', () {
          fakeAsync((time) {
            final raw = createStore()..hold = true;
            final storage = HiddenVolumeStorage.fromAsyncStore(raw);
            final write = _outcome(storage.saveRoster(_rows(size)));
            time.flushMicrotasks();
            expect(raw.entered.isCompleted, isTrue);
            var done = false;
            final maintenance = erase ? storage.eraseSpace() : storage.close();
            maintenance.then((_) => done = true);
            time.flushMicrotasks();
            final endedEarly = done;
            final late = _outcome(storage.saveRoster(_rows(size, tag: 50)));
            time.flushMicrotasks();
            raw.release.complete();
            time.flushMicrotasks();
            final outcomes = [_finish(write, time), _finish(late, time)];
            _finish(maintenance, time);
            if (erase) {
              expect(_finish(storage.loadRoster(), time), isNull);
              _finish(storage.close(), time);
            }
            expect(endedEarly, isFalse);
            expect(outcomes, ['ok', 'error']);
            expect(raw.closed, isTrue);
          });
        });
      }
    });
  }

  for (final erase in [false, true]) {
    test(
      'an obsolete read cannot stall fresh reads after ${erase ? 'erase' : 'reopen'}',
      () {
        fakeAsync((time) {
          final a = createStore(), b = createStore();
          b.raw.commit([
            PutOp(Ns.settings, _key(_rosterKey), _encode(_rows(1, tag: 80))),
          ]);
          final storage = HiddenVolumeStorage.async(
            ({required password, required create}) async =>
                utf8.decode(password) == 'a' ? a : b,
          );
          expect(_finish(storage.open(password: 'a'), time), isTrue);
          _finish(storage.saveRoster(_rows(1)), time);
          a.hold = true;
          final oldRead = storage.loadRoster().then(
            (_) => 'borrowed',
            onError: (_) => 'refused',
          );
          time.flushMicrotasks();
          expect(a.entered.isCompleted, isTrue);
          _finish(erase ? storage.eraseSpace() : storage.close(), time);
          if (!erase) {
            expect(_finish(storage.open(password: 'b'), time), isTrue);
          }
          var freshDone = false;
          final fresh = storage.loadRoster().then((value) {
            freshDone = true;
            return value;
          });
          time.flushMicrotasks();
          final completedBeforeRelease = freshDone;
          a.release.complete();
          time.flushMicrotasks();
          final value = _finish(fresh, time),
              oldResult = _finish(oldRead, time);
          _finish(storage.close(), time);
          expect(
            completedBeforeRelease,
            isTrue,
            reason: 'the retired reader must not own the new queue',
          );
          expect(oldResult, 'refused');
          if (erase) {
            expect(value, isNull);
          } else {
            _expectRoster(value, _rows(1, tag: 80));
          }
        });
      },
    );
  }

  test('legacy empty file marker retains the setting roster', () async {
    final raw = createStore();
    final storage = HiddenVolumeStorage.fromAsyncStore(raw);
    addTearDown(storage.close);
    await AsyncFileStore(raw).storeFile('master:roster.v2', Uint8List(0));
    raw.raw.commit([PutOp(Ns.settings, _key(_rosterKey), _encode(_rows(1)))]);
    _expectRoster(await storage.loadRoster(), _rows(1));
  });

  test(
    'an empty roster remains a master rather than a plain identity',
    () async {
      final raw = createStore();
      final storage = HiddenVolumeStorage.fromAsyncStore(raw);
      addTearDown(storage.close);
      await storage.saveRoster(_rows(24));
      await storage.saveRoster([]);
      _expectRoster(await storage.loadRoster(), []);
    },
  );

  test(
    'an unexpected external descriptor cannot discard the master keys',
    () async {
      final raw = createStore();
      final storage = HiddenVolumeStorage.fromAsyncStore(raw);
      addTearDown(storage.close);
      final old = _encode(_rows(1));
      raw.raw.commit([
        PutOp(Ns.settings, _key(_rosterKey), old),
        PutOp(Ns.settings, _key('ondisk:master:roster.v2'), _key('{}')),
      ]);
      expect(await _outcome(storage.saveRoster(_rows(1, tag: 90))), 'error');
      expect(raw.raw.get(Ns.settings, _key(_rosterKey)), old);
    },
  );

  test(
    'persisted keys survive file promotion, shrink and a fresh child unlock',
    () async {
      final path = '${directory!.path}/master-child.hv';
      HiddenVolumeStorage make() => HiddenVolumeStorage(
        hvSpaceOpener(path, argon: hv.ArgonPreset.min),
        keysOpener: hvKeysSpaceOpener(path),
      );
      final child = make();
      addTearDown(child.close);
      expect(
        await child.open(password: 'child', createIfMissing: true),
        isTrue,
      );
      await child.saveProfile(
        const UserProfile(displayName: 'Synthetic child'),
      );
      final keys = await child.exportSpaceKeys();
      await child.close();
      final master = make();
      addTearDown(master.close);
      expect(
        await master.open(password: 'master', createIfMissing: true),
        isTrue,
      );
      final entries = [
        RosterEntry(label: 'child', spaceKeys: keys),
        ..._rows(23),
      ];
      await master.saveRoster(entries);
      expect(await master.hasFile('master:roster.v2'), isTrue);
      await master.close();
      final reopened = make();
      addTearDown(reopened.close);
      expect(await reopened.open(password: 'master'), isTrue);
      _expectRoster(await reopened.loadRoster(), entries);
      await reopened.saveRoster([entries.first]);
      await reopened.close();
      final small = make();
      addTearDown(small.close);
      expect(await small.open(password: 'master'), isTrue);
      final saved = await small.loadRoster();
      _expectRoster(saved, [entries.first]);
      await small.close();
      final unlocked = make();
      addTearDown(unlocked.close);
      expect(await unlocked.openWithKeys(saved!.single.spaceKeys), isTrue);
      expect((await unlocked.loadProfile())?.displayName, 'Synthetic child');
      await unlocked.close();
    },
    skip: !native ? 'enable the verified native roster lifecycle probe' : false,
  );

  test(
    'failed multi-commit publication preserves the previous roster',
    () async {
      final raw = createStore();
      final storage = HiddenVolumeStorage.fromAsyncStore(raw);
      addTearDown(storage.close);
      await storage.saveRoster(_rows(1));
      raw.failPublication = true;
      final entries = _rows(2400);
      expect(_encode(entries).length, greaterThan(64 * 3800));
      expect(await _outcome(storage.saveRoster(entries)), 'error');
      expect(
        raw.raw.count(Ns.fileChunks),
        greaterThan(0),
        reason: 'the failure must occur after durable data chunks',
      );
      _expectRoster(await storage.loadRoster(), _rows(1));
      await storage.saveRoster(entries);
      _expectRoster(await storage.loadRoster(), entries);
      await storage.saveRoster(_rows(1));
      _expectRoster(await storage.loadRoster(), _rows(1));
    },
  );

  test('failed file retirement cannot acknowledge a smaller roster', () async {
    final raw = createStore();
    final storage = HiddenVolumeStorage.fromAsyncStore(raw);
    addTearDown(storage.close);
    await storage.saveRoster(_rows(24));
    final before = raw.raw.get(Ns.settings, _key(_rosterKey));
    raw.failRetire = true;
    final result = await _outcome(storage.saveRoster(_rows(1, tag: 40)));
    final unchanged = raw.raw.get(Ns.settings, _key(_rosterKey));
    _expectRoster(await storage.loadRoster(), _rows(24));
    await storage.saveRoster(_rows(1, tag: 40));
    _expectRoster(await storage.loadRoster(), _rows(1, tag: 40));
    expect(result, 'error');
    expect(unchanged, before);
    expect(await storage.hasFile('master:roster.v2'), isFalse);
  });

  test(
    'retry after large publication completes stale setting cleanup',
    () async {
      final raw = createStore();
      final storage = HiddenVolumeStorage.fromAsyncStore(raw);
      addTearDown(storage.close);
      await storage.saveRoster(_rows(1));
      raw.failClear = true;
      final result = await _outcome(storage.saveRoster(_rows(24, tag: 40)));
      final chunks = raw.raw.count(Ns.fileChunks);
      _expectRoster(await storage.loadRoster(), _rows(24, tag: 40));
      expect(raw.raw.get(Ns.settings, _key(_rosterKey)), isNotNull);
      await storage.saveRoster(_rows(24, tag: 40));
      expect(raw.raw.get(Ns.settings, _key(_rosterKey)), isNull);
      expect(raw.raw.count(Ns.fileChunks), chunks);
      expect(result, 'ok');
    },
  );

  for (final missingChunk in [false, true]) {
    test(
      'unreadable roster file cannot fall back to a stale smaller copy: missing=$missingChunk',
      () async {
        final raw = createStore();
        final storage = HiddenVolumeStorage.fromAsyncStore(raw);
        addTearDown(storage.close);
        await storage.saveRoster(_rows(24));
        final stale = _encode(_rows(1, tag: 80));
        raw.raw.commit([PutOp(Ns.settings, _key(_rosterKey), stale)]);
        if (missingChunk) {
          final first = raw.raw
              .iterLogRange(namespace: Ns.fileChunks, limit: 1)
              .single;
          raw.raw.commit([DeleteLogOp(Ns.fileChunks, first.logId)]);
        } else {
          raw.raw.commit([PutOp(Ns.settings, _key(_fileKey), _key('{broken'))]);
        }
        final result = await _outcome(storage.saveRoster(_rows(1, tag: 90)));
        expect(result, 'error');
        expect(raw.raw.get(Ns.settings, _key(_rosterKey)), stale);
      },
    );
  }
}
