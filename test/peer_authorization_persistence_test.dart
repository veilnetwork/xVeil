import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/storage.dart';
import 'package:xveil/domain/peer_authorization.dart';
import 'package:xveil/state/peer_authorization_persistence.dart';

PeerAuthorizationEntry _entry(int peer, {int length = 3000, int fill = 7}) =>
    PeerAuthorizationEntry(
      peer.toRadixString(16).padLeft(64, '0'),
      Uint8List(length)..fillRange(0, length, fill),
    );

Uint8List _key(PeerAuthorizationEntry entry, int chunk) => Uint8List.fromList([
  0x50,
  for (var i = 0; i < 64; i += 2)
    int.parse(entry.peer.substring(i, i + 2), radix: 16),
  chunk >> 8,
  chunk & 255,
]);

class _Native implements PeerAuthorizationStateHandle {
  var revision = 0;
  var exports = 0;
  var reads = 0;
  var rejectRestore = false;
  var rejectAck = false;
  List<PeerAuthorizationEntry> entries = [];
  final acks = <int>[];
  @override
  int peerAuthorizationVersion() {
    reads++;
    return revision;
  }

  @override
  PeerAuthorizationSnapshot exportPeerAuthorization() {
    exports++;
    return PeerAuthorizationSnapshot(revision, entries);
  }

  @override
  void restorePeerAuthorization(PeerAuthorizationSnapshot snapshot) {
    if (rejectRestore) throw const CorruptPeerAuthorizationState();
    entries = snapshot.entries;
    revision++;
  }

  @override
  void acknowledgePeerAuthorization(int revision) {
    if (rejectAck) throw StateError('checkpoint ACK failed');
    acks.add(revision);
  }

  void observe(PeerAuthorizationEntry entry) {
    entries = [entry];
    revision++;
  }
}

class _Store extends SyncWrappedAsyncKvLogStore {
  _Store(this.raw) : super(raw);
  final FakeKvLogStore raw;
  var fail = false;
  Completer<void>? entered;
  Completer<void>? release;
  @override
  Future<int> commit(List<KvLogOp> ops) async {
    entered?.complete();
    entered = null;
    final barrier = release;
    release = null;
    if (barrier != null) await barrier.future;
    if (fail) throw StateError('container unavailable');
    return super.commit(ops);
  }
}

class _NotifyingNative extends _Native
    implements PeerAuthorizationChangeSource {
  final changes = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get peerAuthorizationChanges => changes.stream;
}

class _RecordingStore extends _Store {
  _RecordingStore(super.raw);
  final commits = <List<KvLogOp>>[];
  int? failCommit;
  Future<void> Function()? afterCommit;

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    commits.add(List.of(ops));
    if (commits.length == failCommit) {
      throw StateError('injected authorization batch failure');
    }
    final result = await super.commit(ops);
    await afterCommit?.call();
    return result;
  }
}

void main() {
  test(
    'authorization hints checkpoint before the polling tick and coalesce',
    () {
      fakeAsync((clock) {
        final native = _NotifyingNative();
        final io = _Store(FakeKvLogStore());
        final owner = PeerAuthorizationPersistence(
          native: native,
          storage: HiddenVolumeStorage.fromAsyncStore(io),
        );
        owner.restore([]);
        owner.start();
        clock.flushMicrotasks();
        native.acks.clear();
        final exports = native.exports;
        final reads = native.reads;
        final entered = io.entered = Completer<void>();
        final release = io.release = Completer<void>();
        native.observe(_entry(1));
        native.changes.add(null);
        clock.flushMicrotasks();
        expect(
          entered.isCompleted,
          isTrue,
          reason: 'a native wake must not wait for the 1-second poll',
        );
        expect(native.acks, isEmpty, reason: 'the commit is still blocked');
        native.observe(_entry(1, fill: 9));
        for (var n = 0; n < 200; n++) {
          native.changes.add(null);
        }
        clock.flushMicrotasks();
        expect(native.exports - exports, 1);
        release.complete();
        clock.flushMicrotasks();
        expect(native.acks, [2, 3]);
        expect(
          native.exports - exports,
          2,
          reason: 'the revision learned during I/O needs its own checkpoint',
        );
        expect(
          native.reads - reads,
          2,
          reason: 'the burst must not queue 200 flush operations',
        );
        owner.close();
        clock.flushMicrotasks();
        native.changes.close();
        clock.flushMicrotasks();
      });
    },
  );

  test('notifier startup catches state learned before subscribing', () {
    fakeAsync((clock) {
      final native = _NotifyingNative();
      final owner = PeerAuthorizationPersistence(
        native: native,
        storage: HiddenVolumeStorage.fromStore(FakeKvLogStore()),
      );
      owner.restore([]);
      native.observe(_entry(1));
      native.changes.add(
        null,
      ); // No listener yet; the hint is intentionally lost.
      owner.start();
      clock.flushMicrotasks();
      expect(native.acks, [2]);
      owner.close();
      clock.flushMicrotasks();
      native.changes.close();
      clock.flushMicrotasks();
    });
  });

  test('failed wake checkpoint waits for the bounded polling retry', () {
    fakeAsync((clock) {
      final native = _NotifyingNative();
      final io = _Store(FakeKvLogStore());
      final owner = PeerAuthorizationPersistence(
        native: native,
        storage: HiddenVolumeStorage.fromAsyncStore(io),
      );
      owner.restore([]);
      owner.start();
      clock.flushMicrotasks();
      native.acks.clear();
      final before = native.exports;
      native.observe(_entry(1));
      io.fail = true;
      native.changes.add(null);
      clock.flushMicrotasks();
      expect(native.acks, isEmpty);
      expect(native.exports, before + 1);
      io.fail = false;
      for (var n = 0; n < 200; n++) {
        native.changes.add(null);
      }
      clock.flushMicrotasks();
      expect(
        native.exports,
        before + 1,
        reason: 'a hint burst must not busy-retry failed storage',
      );
      clock.elapse(const Duration(seconds: 1));
      expect(native.acks, [2]);
      owner.close();
      clock.flushMicrotasks();
      native.changes.close();
      clock.flushMicrotasks();
    });
  });

  test('close joins a hinted checkpoint and ignores later notifications', () async {
    final native = _NotifyingNative();
    final raw = FakeKvLogStore();
    final io = _Store(raw);
    final owner = PeerAuthorizationPersistence(
      native: native,
      storage: HiddenVolumeStorage.fromAsyncStore(io),
    );
    owner.restore([]);
    owner.start();
    await owner.flush();
    native.acks.clear();
    final entered = io.entered = Completer<void>();
    final release = io.release = Completer<void>();
    native.observe(_entry(1));
    native.changes.add(null);
    await entered.future;
    var closed = false;
    final closing = owner.close().then((_) => closed = true);
    native.observe(_entry(1, fill: 9));
    native.changes.add(null);
    expect(closed, isFalse);
    expect(native.acks, isEmpty);
    release.complete();
    await closing;
    expect(native.acks, [2, 3]);
    final reads = native.reads, committed = raw.commitSeq();
    native.observe(_entry(2));
    native.changes.add(null);
    await Future<void>.value();
    expect(native.reads, reads);
    expect(raw.commitSeq(), committed);
    await owner.close();
    await native.changes.close();
  });

  test('polling recovers a missed wake after the notification stream ends', () {
    fakeAsync((clock) {
      final native = _NotifyingNative();
      final owner = PeerAuthorizationPersistence(
        native: native,
        storage: HiddenVolumeStorage.fromStore(FakeKvLogStore()),
      );
      owner.restore([]);
      owner.start();
      clock.flushMicrotasks();
      native.changes.close();
      clock.flushMicrotasks();
      native.acks.clear();
      native.observe(_entry(1));
      clock.elapse(const Duration(seconds: 1));
      expect(native.acks, [2]);
      owner.close();
      clock.flushMicrotasks();
    });
  });

  test('polling-only owner waits for the next checkpoint tick', () {
    fakeAsync((clock) {
      final native = _Native();
      final owner = PeerAuthorizationPersistence(
        native: native,
        storage: HiddenVolumeStorage.fromStore(FakeKvLogStore()),
        pollEvery: const Duration(seconds: 1),
      );
      owner.restore([]);
      var primed = false;
      owner.flush().then((_) => primed = true);
      clock.flushMicrotasks();
      expect(primed, isTrue);
      native.acks.clear();
      owner.start();
      clock.elapse(const Duration(milliseconds: 1));
      native.observe(_entry(1));
      clock.elapse(const Duration(milliseconds: 998));
      expect(
        native.acks,
        isEmpty,
        reason: 'instant storage cannot remove the wait for a polling tick',
      );
      clock.elapse(const Duration(milliseconds: 1));
      expect(native.acks, [2]);
      var closed = false;
      owner.close().then((_) => closed = true);
      clock.flushMicrotasks();
      expect(closed, isTrue);
      final reads = native.reads;
      clock.elapse(const Duration(seconds: 2));
      expect(native.reads, reads);
    });
  });

  test('small authorization snapshots share one bounded commit', () async {
    final raw = FakeKvLogStore();
    final io = _RecordingStore(raw);
    final storage = HiddenVolumeStorage.fromAsyncStore(io);
    final entries = [for (var n = 1; n <= 11; n++) _entry(n)];
    await storage.replacePeerAuthorization(entries);
    expect(
      io.commits,
      hasLength(1),
      reason: 'independent documents need not pay one commit apiece',
    );
    expect(io.commits.single.length, lessThanOrEqualTo(64));
    expect(
      (await storage.loadPeerAuthorization()).map((e) => e.peer),
      unorderedEquals(entries.map((e) => e.peer)),
    );
    final committed = raw.commitSeq();
    await storage.replacePeerAuthorization(entries);
    expect(raw.commitSeq(), committed, reason: 'unchanged snapshot is a no-op');
  });

  test('bounded authorization batches never split a document', () async {
    final raw = FakeKvLogStore();
    final io = _RecordingStore(raw);
    final storage = HiddenVolumeStorage.fromAsyncStore(io);
    final entries = [
      for (var n = 1; n <= 20; n++)
        _entry(n, length: PeerAuthorizationEntry.maxDocumentBytes),
    ];
    await storage.replacePeerAuthorization(entries);
    expect(io.commits.length, greaterThan(1));
    final batchOf = <String, int>{};
    final chunkCount = <String, int>{};
    for (var n = 0; n < io.commits.length; n++) {
      final ops = io.commits[n];
      expect(ops.length, lessThanOrEqualTo(64));
      for (final op in ops.whereType<PutOp>()) {
        if (op.key.length != 35) continue;
        final peer = base64Encode(op.key.sublist(1, 33));
        expect(
          batchOf.putIfAbsent(peer, () => n),
          n,
          reason: 'one document crossed a durable batch boundary',
        );
        chunkCount.update(peer, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    expect(batchOf, hasLength(20));
    expect(chunkCount.values, everyElement(17));
    expect(
      (await storage.loadPeerAuthorization()).map((e) => e.document),
      everyElement(entries.first.document),
    );
  });

  test(
    'authorization eviction stays below restore budget after every commit',
    () async {
      final raw = FakeKvLogStore();
      final io = _RecordingStore(raw);
      final storage = HiddenVolumeStorage.fromAsyncStore(io);
      final cap = PeerAuthorizationEntry.maxEntries;
      await storage.replacePeerAuthorization([
        for (var n = 1; n <= cap; n++) _entry(n, length: 10),
      ]);
      io.commits.clear();
      io.afterCommit = () async {
        final reopened = HiddenVolumeStorage.fromStore(raw);
        expect(
          (await reopened.loadPeerAuthorization()).length,
          lessThanOrEqualTo(cap),
        );
      };
      final replacement = [
        for (var n = cap + 1; n <= cap * 2; n++) _entry(n, length: 10),
      ];
      await storage.replacePeerAuthorization(replacement);
      expect(
        io.commits.map((ops) => ops.length),
        everyElement(lessThanOrEqualTo(64)),
      );
      expect(
        (await storage.loadPeerAuthorization()).map((e) => e.peer),
        unorderedEquals(replacement.map((e) => e.peer)),
      );
    },
  );

  test(
    'failed authorization batch retains whole documents and withholds ACK',
    () async {
      final raw = FakeKvLogStore();
      final io = _RecordingStore(raw);
      final storage = HiddenVolumeStorage.fromAsyncStore(io);
      final old = [for (var n = 1; n <= 80; n++) _entry(n, length: 4500)];
      await storage.replacePeerAuthorization(old);
      final native = _Native();
      final owner = PeerAuthorizationPersistence(
        native: native,
        storage: storage,
      );
      owner.restore(old);
      native.entries = [for (var n = 1; n <= 80; n++) _entry(n, fill: 9)];
      native.revision++;
      io.commits.clear();
      io.failCommit = 2;
      await expectLater(owner.flush(), throwsStateError);
      expect(native.acks, isEmpty);
      final recovered = await HiddenVolumeStorage.fromStore(
        raw,
      ).loadPeerAuthorization();
      expect(recovered, hasLength(80));
      for (final e in recovered) {
        expect(
          e.document,
          anyOf(
            equals(old.first.document),
            equals(native.entries.first.document),
          ),
          reason: 'a document was left between versions',
        );
      }
      io.failCommit = null;
      await owner.flush();
      expect(native.acks, [2]);
      expect(
        (await storage.loadPeerAuthorization()).map((e) => e.document),
        everyElement(native.entries.first.document),
      );
      await owner.close();
    },
  );

  test('bounded chunks survive reopen and coexist with ratchet keys', () async {
    final raw = FakeKvLogStore();
    final storage = HiddenVolumeStorage.fromStore(raw);
    final entry = _entry(1, length: PeerAuthorizationEntry.maxDocumentBytes);
    final ratchetKey = Uint8List(kRatchetKeyLen + 2)
      ..fillRange(0, kRatchetKeyLen, 0x50);
    raw.commit([
      PutOp(Ns.ratchet, ratchetKey, Uint8List.fromList([0, 0, 0, 1, 9])),
    ]);
    await storage.replacePeerAuthorization([entry]);
    final after = raw.commitSeq();
    await storage.replacePeerAuthorization([entry]);
    expect(
      raw.commitSeq(),
      after,
      reason: 'unchanged snapshots must do no writes',
    );
    final reopened = HiddenVolumeStorage.fromStore(raw);
    expect(
      (await reopened.loadPeerAuthorization()).single.document,
      entry.document,
    );
    expect(await reopened.ratchetConversationKeys(), [
      ratchetKey.sublist(0, kRatchetKeyLen),
    ]);
    await reopened.purgeFileStore();
    await reopened.purgeMessageLog();
    expect(
      (await reopened.loadPeerAuthorization()).single.document,
      entry.document,
    );
    final smaller = _entry(1, length: 10, fill: 3);
    await reopened.replacePeerAuthorization([smaller]);
    expect(
      raw.count(Ns.ratchet),
      4,
      reason:
          'auth layout, cleanup budget, auth head and ratchet head; old tails removed',
    );
    expect(
      (await reopened.loadPeerAuthorization()).single.document,
      smaller.document,
    );
    await reopened.eraseSpace();
    expect(await reopened.loadPeerAuthorization(), isEmpty);
  });

  test(
    'missing, orphaned and malformed chunks fail closed without mutation',
    () async {
      for (final damage in [
        'head',
        'tail',
        'layout',
        'orphan',
        'length',
        'extra',
      ]) {
        final raw = FakeKvLogStore();
        final storage = HiddenVolumeStorage.fromStore(raw);
        final e = _entry(1);
        await storage.replacePeerAuthorization([e]);
        switch (damage) {
          case 'head':
            raw.commit([DeleteOp(Ns.ratchet, _key(e, 0))]);
          case 'tail':
            raw.commit([DeleteOp(Ns.ratchet, _key(e, 1))]);
          case 'layout':
            raw.commit([
              DeleteOp(Ns.ratchet, Uint8List.fromList([0x50])),
            ]);
          case 'orphan':
            raw.commit([PutOp(Ns.ratchet, _key(_entry(2), 1), Uint8List(1))]);
          case 'length':
            raw.commit([
              PutOp(
                Ns.ratchet,
                _key(e, 0),
                Uint8List.fromList([0xff, 0xff, 0xff, 0xff]),
              ),
            ]);
          case 'extra':
            raw.commit([PutOp(Ns.ratchet, _key(e, 5), Uint8List(1))]);
        }
        final seq = raw.commitSeq();
        await expectLater(
          storage.loadPeerAuthorization(),
          throwsA(isA<CorruptPeerAuthorizationState>()),
        );
        await expectLater(
          storage.replacePeerAuthorization([]),
          throwsA(isA<CorruptPeerAuthorizationState>()),
        );
        expect(raw.commitSeq(), seq, reason: damage);
      }
    },
  );

  test('storage freezes mutable input before queuing I/O', () async {
    final raw = FakeKvLogStore();
    final storage = HiddenVolumeStorage.fromStore(raw);
    final entry = _entry(3, length: 10);
    final expected = Uint8List.fromList(entry.document);
    final input = [entry];
    final write = storage.replacePeerAuthorization(input);
    entry.document.fillRange(0, 10, 9);
    input.clear();
    await write;
    expect((await storage.loadPeerAuthorization()).single.document, expected);
  });

  test('failed document replacement retains a complete old record', () async {
    final raw = FakeKvLogStore();
    final io = _Store(raw);
    final storage = HiddenVolumeStorage.fromAsyncStore(io);
    final old = _entry(1);
    await storage.replacePeerAuthorization([old]);
    io.fail = true;
    await expectLater(
      storage.replacePeerAuthorization([_entry(1, length: 50)]),
      throwsStateError,
    );
    expect(
      (await storage.loadPeerAuthorization()).single.document,
      old.document,
    );
    io.fail = false;
    await storage.replacePeerAuthorization([_entry(1, length: 50)]);
    expect((await storage.loadPeerAuthorization()).single.document.length, 50);
  });

  test(
    'checkpoint ACK follows commit; I/O failure retries and never ACKs',
    () async {
      final raw = FakeKvLogStore();
      final io = _Store(raw);
      final storage = HiddenVolumeStorage.fromAsyncStore(io);
      final native = _Native();
      final owner = PeerAuthorizationPersistence(
        native: native,
        storage: storage,
      );
      owner.restore([]);
      native.observe(_entry(4));
      io.fail = true;
      await expectLater(owner.flush(), throwsStateError);
      expect(native.acks, isEmpty);
      expect(await storage.loadPeerAuthorization(), isEmpty);
      io.fail = false;
      await owner.flush();
      expect(native.acks, [2]);
      expect(
        (await storage.loadPeerAuthorization()).single.peer,
        _entry(4).peer,
      );
      final seq = raw.commitSeq();
      await owner.flush();
      expect(raw.commitSeq(), seq);
      expect(native.exports, 2);
      await owner.close();
    },
  );

  test(
    'updates during I/O remain pending; close joins and saves newer revision',
    () async {
      final raw = FakeKvLogStore();
      final io = _Store(raw);
      final storage = HiddenVolumeStorage.fromAsyncStore(io);
      final native = _Native();
      final owner = PeerAuthorizationPersistence(
        native: native,
        storage: storage,
      );
      owner.restore([]);
      native.observe(_entry(1));
      final entered = io.entered = Completer<void>();
      final release = io.release = Completer<void>();
      final write = owner.flush();
      await entered.future;
      expect(native.acks, isEmpty);
      native.observe(_entry(2));
      final closing = owner.close();
      release.complete();
      await write;
      await closing;
      expect(native.acks, [2, 3]);
      expect(
        (await storage.loadPeerAuthorization()).single.peer,
        _entry(2).peer,
      );
      final reads = native.reads;
      await owner.close();
      await owner.flush();
      expect(
        native.reads,
        reads,
        reason: 'closed owner never touches native again',
      );
    },
  );

  test(
    'rejected restore cannot overwrite durable security state at teardown',
    () async {
      final raw = FakeKvLogStore();
      final storage = HiddenVolumeStorage.fromStore(raw);
      await storage.replacePeerAuthorization([_entry(1)]);
      final native = _Native()..rejectRestore = true;
      final owner = PeerAuthorizationPersistence(
        native: native,
        storage: storage,
      );
      expect(
        () => owner.restore([_entry(1)]),
        throwsA(isA<CorruptPeerAuthorizationState>()),
      );
      await owner.close();
      expect(native.exports, 0);
      expect(native.acks, isEmpty);
      expect(
        (await storage.loadPeerAuthorization()).single.peer,
        _entry(1).peer,
      );
    },
  );

  test(
    'periodic checkpoint stops cleanly and a rejected ACK is retried',
    () async {
      final raw = FakeKvLogStore();
      final native = _Native();
      final owner = PeerAuthorizationPersistence(
        native: native,
        storage: HiddenVolumeStorage.fromStore(raw),
        pollEvery: const Duration(milliseconds: 5),
      );
      owner.restore([]);
      native.observe(_entry(1));
      native.rejectAck = true;
      await expectLater(owner.flush(), throwsStateError);
      final seq = raw.commitSeq();
      native.rejectAck = false;
      await owner.flush();
      expect(
        raw.commitSeq(),
        seq,
        reason: 'ACK retry need not rewrite durable bytes',
      );
      owner.start();
      native.observe(_entry(2));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(native.acks.last, 3);
      await owner.close();
      final reads = native.reads;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(native.reads, reads);
    },
  );

  test(
    'snapshot decoder rejects unbounded/duplicate records without leaking input',
    () {
      final good = PeerAuthorizationSnapshot(1, [_entry(1)]).encode();
      expect(
        PeerAuthorizationSnapshot.decode(1, good).entries.single.document,
        _entry(1).document,
      );
      final secret = 'private sentinel';
      for (final bad in [
        Uint8List.fromList(utf8.encode(secret)),
        Uint8List.fromList(utf8.encode('{"version":2,"entries":[]}')),
        Uint8List.fromList(
          utf8.encode('{"version":1,"entries":[],"unknown":true}'),
        ),
      ]) {
        expect(
          () => PeerAuthorizationSnapshot.decode(1, bad),
          throwsA(
            isA<CorruptPeerAuthorizationState>().having(
              (e) => e.toString(),
              'redacted',
              isNot(contains(secret)),
            ),
          ),
        );
      }
      expect(
        () => PeerAuthorizationSnapshot(1, [_entry(1), _entry(1)]),
        throwsA(isA<CorruptPeerAuthorizationState>()),
      );
    },
  );
}
