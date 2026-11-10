import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/domain/event.dart';

class _HeldErasureStore extends SyncWrappedAsyncKvLogStore {
  _HeldErasureStore(this.raw) : super(raw);
  final FakeKvLogStore raw;
  final entered = Completer<void>(), release = Completer<void>();
  bool holdKeys = false,
      holdRange = false,
      closed = false,
      refuseDelete = false,
      refuseVoid = false;

  @override
  Future<int> commit(List<KvLogOp> ops) {
    if (refuseVoid &&
        ops.whereType<AppendLogOp>().any(
          (op) =>
              (jsonDecode(utf8.decode(op.payload)) as Map)['k'] ==
              EventKind.void_.index,
        )) {
      refuseVoid = false;
      return Future.error(StateError('fixture void refused'));
    }
    if (refuseDelete &&
        ops.whereType<AppendLogOp>().any(
          (op) => (jsonDecode(utf8.decode(op.payload)) as Map)['op'] == 'del',
        )) {
      refuseDelete = false;
      return Future.error(StateError('fixture deletion refused'));
    }
    return super.commit(ops);
  }

  @override
  Future<List<KvLogEntry>> iterLogRange({
    required int namespace,
    int? start,
    int? end,
    required int limit,
  }) async {
    final rows = await super.iterLogRange(
      namespace: namespace,
      start: start,
      end: end,
      limit: limit,
    );
    if (holdRange &&
        namespace >= Ns.messageLogShardFirst &&
        namespace <= Ns.messageLogShardLast) {
      holdRange = false;
      entered.complete();
      await release.future;
    }
    return rows;
  }

  @override
  Future<List<Uint8List>> kvKeys(int namespace) async {
    if (holdKeys && namespace == Ns.settings) {
      holdKeys = false;
      entered.complete();
      await release.future;
    }
    if (closed) throw StateError('fixture store closed');
    return super.kvKeys(namespace);
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

enum _Erasure { delete, clear, prune }

void main() {
  final firstPeer = NodeId(Uint8List(32)..fillRange(0, 32, 1));
  final nextPeer = NodeId(Uint8List(32)..fillRange(0, 32, 2));
  Message row(NodeId peer, String id, String body) => Message(
    id: id,
    conversationId: peer.hex,
    direction: MessageDirection.incoming,
    body: body,
    timestamp: DateTime.utc(2020),
    author: peer.hex,
    seq: 1,
  );

  Future<Object?> erase(HiddenVolumeStorage storage, _Erasure kind) =>
      switch (kind) {
        _Erasure.delete => storage.deleteMessage(firstPeer.hex, 'old-row'),
        _Erasure.clear => storage.clearMessages(firstPeer),
        _Erasure.prune => storage.pruneConversationBefore(
          firstPeer,
          DateTime.utc(2021),
        ),
      };

  test(
    'accepted void cannot enter another identity after its preparation read',
    () {
      fakeAsync((time) {
        final first = _HeldErasureStore(FakeKvLogStore());
        final next = _HeldErasureStore(FakeKvLogStore());
        final storage = HiddenVolumeStorage.async(({
          required password,
          required create,
        }) async {
          final result = utf8.decode(password) == 'first' ? first : next;
          result.closed = false;
          return result;
        });
        storage.open(password: 'next');
        time.flushMicrotasks();
        storage.appendMessage(row(nextPeer, 'next-row', 'next-space-body'));
        time.flushMicrotasks();
        storage.open(password: 'first');
        time.flushMicrotasks();
        storage.appendMessage(row(firstPeer, 'old-row', 'first-space-body'));
        time.flushMicrotasks();
        first.holdRange = true;
        String? outcome;
        storage
            .applyRemoteVoid(firstPeer.hex, firstPeer.hex, 2)
            .then(
              (_) => outcome = 'ok',
              onError: (Object _) => outcome = 'error',
            );
        time.flushMicrotasks();
        expect(first.entered.isCompleted, isTrue);
        bool? opened;
        storage.open(password: 'next').then((ok) => opened = ok);
        time.flushMicrotasks();
        final openedBeforeRelease = opened;
        first.release.complete();
        time.flushMicrotasks();
        expect(opened, isTrue);
        List<int>? foreign;
        storage
            .loadEventsSince(firstPeer.hex, firstPeer.hex, 0)
            .then((events) => foreign = [for (final e in events) e.seq]);
        time.flushMicrotasks();
        Message? kept;
        storage.loadMessageById(nextPeer.hex, 'next-row').then((m) => kept = m);
        time.flushMicrotasks();
        storage.close();
        time.flushMicrotasks();
        expect(
          foreign,
          isEmpty,
          reason:
              'an older identity must not leave gap-fill metadata in the new space',
        );
        expect(kept?.body, 'next-space-body');
        expect(openedBeforeRelease, isNull);
        expect(outcome, 'ok');
      });
    },
  );

  test('concurrent copies of one void consume one log slot', () {
    fakeAsync((time) {
      final raw = _HeldErasureStore(FakeKvLogStore());
      final storage = HiddenVolumeStorage.fromAsyncStore(raw);
      storage.appendMessage(row(firstPeer, 'old-row', 'first-space-body'));
      time.flushMicrotasks();
      raw.holdRange = true;
      final first = storage.applyRemoteVoid(firstPeer.hex, firstPeer.hex, 2);
      time.flushMicrotasks();
      expect(raw.entered.isCompleted, isTrue);
      final second = storage.applyRemoteVoid(firstPeer.hex, firstPeer.hex, 2);
      time.flushMicrotasks();
      raw.release.complete();
      var done = false;
      Future.wait([first, second]).then((_) => done = true);
      time.flushMicrotasks();
      expect(done, isTrue);
      List<int>? seqs;
      storage
          .loadEventsSince(firstPeer.hex, firstPeer.hex, 1)
          .then((events) => seqs = [for (final e in events) e.seq]);
      time.flushMicrotasks();
      storage.close();
      time.flushMicrotasks();
      expect(seqs, [
        2,
      ], reason: 'the idempotency read and write must share the stream turn');
    });
  });

  test('a pending void does not block a different author', () {
    fakeAsync((time) {
      final raw = _HeldErasureStore(FakeKvLogStore());
      final storage = HiddenVolumeStorage.fromAsyncStore(raw);
      storage.appendMessage(row(firstPeer, 'old-row', 'first-space-body'));
      time.flushMicrotasks();
      raw.holdRange = true;
      final first = storage.applyRemoteVoid(firstPeer.hex, firstPeer.hex, 2);
      time.flushMicrotasks();
      expect(raw.entered.isCompleted, isTrue);
      var otherDone = false;
      storage
          .applyRemoteVoid(firstPeer.hex, nextPeer.hex, 1)
          .then((_) => otherDone = true);
      time.flushMicrotasks();
      final doneBeforeRelease = otherDone;
      raw.release.complete();
      var firstDone = false;
      first.then((_) => firstDone = true);
      time.flushMicrotasks();
      expect(firstDone && otherDone, isTrue);
      List<int>? seqs;
      storage
          .loadEventsSince(firstPeer.hex, nextPeer.hex, 0)
          .then((events) => seqs = [for (final e in events) e.seq]);
      time.flushMicrotasks();
      storage.close();
      time.flushMicrotasks();
      expect(doneBeforeRelease, isTrue);
      expect(seqs, [1]);
    });
  });

  for (final erasing in [false, true]) {
    test(
      'accepted void drains before ${erasing ? 'erase' : 'close'} and refuses late voids',
      () {
        fakeAsync((time) {
          final raw = _HeldErasureStore(FakeKvLogStore());
          final storage = HiddenVolumeStorage.fromAsyncStore(raw);
          storage.appendMessage(row(firstPeer, 'old-row', 'first-space-body'));
          time.flushMicrotasks();
          raw.holdRange = true;
          String? accepted, late;
          storage
              .applyRemoteVoid(firstPeer.hex, firstPeer.hex, 2)
              .then(
                (_) => accepted = 'ok',
                onError: (Object _) => accepted = 'error',
              );
          time.flushMicrotasks();
          expect(raw.entered.isCompleted, isTrue);
          var done = false;
          final maintenance = erasing ? storage.eraseSpace() : storage.close();
          maintenance.then((_) => done = true);
          time.flushMicrotasks();
          expect(done, isFalse);
          storage
              .applyRemoteVoid(firstPeer.hex, nextPeer.hex, 1)
              .then((_) => late = 'ok', onError: (Object _) => late = 'error');
          time.flushMicrotasks();
          expect(late, 'error');
          raw.release.complete();
          time.flushMicrotasks();
          expect(accepted, 'ok');
          expect(done, isTrue);
          if (erasing) {
            expect([
              for (
                var ns = Ns.messageLogShardFirst;
                ns <= Ns.messageLogShardLast;
                ns++
              )
                raw.raw.count(ns),
            ], everyElement(0));
          }
          storage.close();
          time.flushMicrotasks();
          expect(raw.closed, isTrue);
        });
      },
    );
  }

  test(
    'failed accepted void releases close without acknowledging the slot',
    () {
      fakeAsync((time) {
        final raw = _HeldErasureStore(FakeKvLogStore());
        final storage = HiddenVolumeStorage.fromAsyncStore(raw);
        storage.appendMessage(row(firstPeer, 'old-row', 'first-space-body'));
        time.flushMicrotasks();
        raw.holdRange = true;
        raw.refuseVoid = true;
        String? outcome;
        storage
            .applyRemoteVoid(firstPeer.hex, firstPeer.hex, 2)
            .then(
              (_) => outcome = 'ok',
              onError: (Object _) => outcome = 'error',
            );
        time.flushMicrotasks();
        expect(raw.entered.isCompleted, isTrue);
        var closed = false;
        storage.close().then((_) => closed = true);
        time.flushMicrotasks();
        expect(closed, isFalse);
        raw.release.complete();
        time.flushMicrotasks();
        expect(outcome, 'error');
        expect(closed && raw.closed, isTrue);
        expect([
          for (
            var ns = Ns.messageLogShardFirst;
            ns <= Ns.messageLogShardLast;
            ns++
          )
            for (final e in raw.raw.iterLogRange(namespace: ns, limit: 1000))
              jsonDecode(utf8.decode(e.payload)),
        ], everyElement(isNot(containsPair('k', EventKind.void_.index))));
      });
    },
  );

  for (final kind in _Erasure.values) {
    test('accepted ${kind.name} cannot rewrite the next opened identity', () {
      fakeAsync((time) {
        final first = _HeldErasureStore(FakeKvLogStore());
        final next = _HeldErasureStore(FakeKvLogStore());
        final storage = HiddenVolumeStorage.async(({
          required password,
          required create,
        }) async {
          final result = utf8.decode(password) == 'first' ? first : next;
          result.closed = false;
          return result;
        });
        bool? opened;
        storage.open(password: 'next').then((v) => opened = v);
        time.flushMicrotasks();
        expect(opened, isTrue);
        storage.appendMessage(row(nextPeer, 'next-row', 'next-space-body'));
        time.flushMicrotasks();
        opened = null;
        storage.open(password: 'first').then((v) => opened = v);
        time.flushMicrotasks();
        expect(opened, isTrue);
        storage.appendMessage(row(firstPeer, 'old-row', 'first-space-body'));
        time.flushMicrotasks();
        storage.loadMessages(firstPeer.hex);
        time.flushMicrotasks();
        first.holdKeys = kind != _Erasure.prune;
        first.holdRange = kind == _Erasure.prune;
        String? outcome;
        erase(
          storage,
          kind,
        ).then((_) => outcome = 'ok', onError: (Object _) => outcome = 'error');
        time.flushMicrotasks();
        expect(first.entered.isCompleted, isTrue);
        opened = null;
        storage.open(password: 'next').then((v) => opened = v);
        time.flushMicrotasks();
        final openedBeforeRelease = opened;
        first.release.complete();
        time.flushMicrotasks();
        expect(opened, isTrue);
        Message? kept;
        storage.loadMessageById(nextPeer.hex, 'next-row').then((v) => kept = v);
        time.flushMicrotasks();
        storage.close();
        time.flushMicrotasks();
        expect(
          kept?.body,
          'next-space-body',
          reason: 'the old erasure must not tombstone a reused log slot',
        );
        expect(
          openedBeforeRelease,
          isNull,
          reason: 'accepted erasures must drain before changing spaces',
        );
        expect(outcome, 'ok');
        expect(first.closed && next.closed, isTrue);
      });
    });

    for (final erasing in [false, true]) {
      test('accepted ${kind.name} drains before ${erasing ? 'erase' : 'close'} '
          'and late erasures are refused', () {
        fakeAsync((time) {
          final raw = _HeldErasureStore(FakeKvLogStore());
          final storage = HiddenVolumeStorage.fromAsyncStore(raw);
          storage.appendMessage(row(firstPeer, 'old-row', 'first-space-body'));
          time.flushMicrotasks();
          storage.loadMessages(firstPeer.hex);
          time.flushMicrotasks();
          raw.holdKeys = kind != _Erasure.prune;
          raw.holdRange = kind == _Erasure.prune;
          String? accepted, late;
          erase(storage, kind).then(
            (_) => accepted = 'ok',
            onError: (Object _) => accepted = 'error',
          );
          time.flushMicrotasks();
          expect(raw.entered.isCompleted, isTrue);
          var done = false;
          final maintenance = erasing ? storage.eraseSpace() : storage.close();
          maintenance.then((_) => done = true);
          time.flushMicrotasks();
          expect(done, isFalse);
          erase(
            storage,
            kind,
          ).then((_) => late = 'ok', onError: (Object _) => late = 'error');
          time.flushMicrotasks();
          expect(late, 'error');
          raw.release.complete();
          time.flushMicrotasks();
          expect(accepted, 'ok');
          expect(done, isTrue);
          if (erasing) {
            expect([
              for (
                var ns = Ns.messageLogShardFirst;
                ns <= Ns.messageLogShardLast;
                ns++
              )
                raw.raw.count(ns),
            ], everyElement(0));
          }
          storage.close();
          time.flushMicrotasks();
          expect(raw.closed, isTrue);
        });
      });
    }
  }

  test('a failed accepted erasure releases close and the next space', () {
    fakeAsync((time) {
      final first = _HeldErasureStore(FakeKvLogStore());
      final next = _HeldErasureStore(FakeKvLogStore());
      final storage = HiddenVolumeStorage.async(({
        required password,
        required create,
      }) async {
        final result = utf8.decode(password) == 'first' ? first : next;
        result.closed = false;
        return result;
      });
      storage.open(password: 'first');
      time.flushMicrotasks();
      storage.appendMessage(row(firstPeer, 'old-row', 'first-space-body'));
      time.flushMicrotasks();
      storage.loadMessages(firstPeer.hex);
      time.flushMicrotasks();
      first.holdKeys = true;
      first.refuseDelete = true;
      String? result;
      storage
          .deleteMessage(firstPeer.hex, 'old-row')
          .then((_) => result = 'ok', onError: (Object _) => result = 'error');
      time.flushMicrotasks();
      expect(first.entered.isCompleted, isTrue);
      bool? opened;
      storage.open(password: 'next').then((v) => opened = v);
      time.flushMicrotasks();
      expect(opened, isNull);
      first.release.complete();
      time.flushMicrotasks();
      expect(result, 'error');
      expect(opened, isTrue);
      storage.appendMessage(row(nextPeer, 'next-row', 'next-space-body'));
      time.flushMicrotasks();
      Message? kept;
      storage.loadMessageById(nextPeer.hex, 'next-row').then((v) => kept = v);
      time.flushMicrotasks();
      expect(kept?.body, 'next-space-body');
      storage.close();
      time.flushMicrotasks();
      expect(first.closed && next.closed, isTrue);
    });
  });
}
