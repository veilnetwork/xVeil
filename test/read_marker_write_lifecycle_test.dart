import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/domain/chat.dart';

const _conversation = 'read-position-fixture';
const _latest = 2000;

enum _Kind { markRead, setReadMarker }

Future<void> _write(HiddenVolumeStorage storage, _Kind kind) => switch (kind) {
  _Kind.markRead => storage.markRead(_conversation),
  _Kind.setReadMarker => storage.setReadMarker(_conversation, _latest),
};

class _Store extends SyncWrappedAsyncKvLogStore {
  _Store(this.raw) : super(raw);
  final FakeKvLogStore raw;
  final entered = Completer<void>(), release = Completer<void>();
  bool hold = false, closed = false, failNext = false, loseNextReply = false;
  final markers = <int>[];

  @override
  Future<Uint8List?> get(int namespace, Uint8List key) async {
    final value = await super.get(namespace, key);
    if (hold &&
        namespace == Ns.settings &&
        utf8.decode(key) == 'read:$_conversation') {
      hold = false;
      entered.complete();
      await release.future;
    }
    return value;
  }

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    if (closed) throw StateError('closed fixture store');
    final writes = ops.whereType<PutOp>().where(
      (op) =>
          op.namespace == Ns.settings &&
          utf8.decode(op.key).startsWith('read:'),
    );
    if (writes.isNotEmpty && failNext) {
      failNext = false;
      throw StateError('fixture marker commit refused');
    }
    markers.addAll(writes.map((op) => int.parse(utf8.decode(op.value))));
    final result = await super.commit(ops);
    if (writes.isNotEmpty && loseNextReply) {
      loseNextReply = false;
      throw StateError('fixture marker commit reply lost');
    }
    return result;
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

int _marker(_Store store) {
  final raw = store.raw.get(
    Ns.settings,
    Uint8List.fromList(utf8.encode('read:$_conversation')),
  );
  return raw == null ? 0 : int.parse(utf8.decode(raw));
}

Future<String> _outcome(Future<void> work) =>
    work.then((_) => 'ok', onError: (Object _) => 'error');

Message _message() => Message(
  id: 'last-row',
  conversationId: _conversation,
  direction: MessageDirection.incoming,
  body: 'fixture body',
  timestamp: DateTime.fromMillisecondsSinceEpoch(_latest),
  author: 'fixture-author',
  seq: 1,
);

void main() {
  for (final kind in _Kind.values) {
    group(kind.name, () {
      test('concurrent identical marks need one durable write', () async {
        final raw = _Store(FakeKvLogStore());
        final storage = HiddenVolumeStorage.fromAsyncStore(raw);
        addTearDown(storage.close);
        await storage.appendMessage(_message());
        await Future.wait([for (var i = 0; i < 16; i++) _write(storage, kind)]);
        expect(_marker(raw), _latest);
        expect(raw.markers, [_latest]);
      });

      test('an older completion cannot lower a newer read position', () async {
        final raw = _Store(FakeKvLogStore());
        final storage = HiddenVolumeStorage.fromAsyncStore(raw);
        addTearDown(storage.close);
        await storage.appendMessage(_message());
        raw.hold = true;
        final first = _outcome(_write(storage, kind));
        await raw.entered.future;
        final second = _outcome(storage.setReadMarker(_conversation, 3000));
        try {
          // An unrelated conversation must not queue behind this held read.
          await storage.setReadMarker('independent', 17);
          expect(await storage.readMarker('independent'), 17);
        } finally {
          raw.release.complete();
          await Future.wait([first, second]);
        }
        expect([await first, await second], ['ok', 'ok']);
        expect(await storage.readMarker(_conversation), 3000);
      });

      test('accepted read mark stays with its original identity', () {
        fakeAsync((time) {
          final a = _Store(FakeKvLogStore()), b = _Store(FakeKvLogStore());
          final storage = HiddenVolumeStorage.async(
            ({required password, required create}) async =>
                utf8.decode(password) == 'first' ? a : b,
          );
          storage.open(password: 'first');
          time.flushMicrotasks();
          storage.appendMessage(_message());
          time.flushMicrotasks();
          a.hold = true;
          String? result;
          _outcome(_write(storage, kind)).then((value) => result = value);
          time.flushMicrotasks();
          expect(a.entered.isCompleted, isTrue);
          bool? reopened;
          storage.open(password: 'next').then((value) => reopened = value);
          time.flushMicrotasks();
          a.release.complete();
          time.flushMicrotasks();
          storage.close();
          time.flushMicrotasks();
          expect(reopened, isTrue);
          expect(result, 'ok');
          expect(
            _marker(b),
            0,
            reason: 'the next identity must not inherit a read mark',
          );
          expect(_marker(a), _latest);
          expect(a.closed && b.closed, isTrue);
        });
      });

      for (final erase in [false, true]) {
        test(
          'accepted read mark drains before ${erase ? 'erase' : 'close'}',
          () {
            fakeAsync((time) {
              final raw = _Store(FakeKvLogStore());
              final storage = HiddenVolumeStorage.fromAsyncStore(raw);
              storage.appendMessage(_message());
              time.flushMicrotasks();
              raw.hold = true;
              final outcomes = <String>[];
              _outcome(_write(storage, kind)).then(outcomes.add);
              time.flushMicrotasks();
              expect(raw.entered.isCompleted, isTrue);
              var done = false;
              (erase ? storage.eraseSpace() : storage.close()).then(
                (_) => done = true,
              );
              time.flushMicrotasks();
              final finishedWhileHeld = done;
              _outcome(_write(storage, kind)).then(outcomes.add);
              time.flushMicrotasks();
              raw.release.complete();
              time.flushMicrotasks();
              if (erase) {
                storage.close();
                time.flushMicrotasks();
              }
              expect(finishedWhileHeld, isFalse);
              expect(done, isTrue);
              expect(outcomes, unorderedEquals(['ok', 'error']));
              expect(_marker(raw), erase ? 0 : _latest);
              expect(raw.closed, isTrue);
            });
          },
        );
      }

      for (final lostReply in [false, true]) {
        test(
          'failed ${lostReply ? 'reply' : 'commit'} leaves the next mark usable',
          () async {
            final raw = _Store(FakeKvLogStore());
            final storage = HiddenVolumeStorage.fromAsyncStore(raw);
            addTearDown(storage.close);
            await storage.appendMessage(_message());
            raw.failNext = !lostReply;
            raw.loseNextReply = lostReply;
            final first = _outcome(_write(storage, kind));
            final second = _outcome(_write(storage, kind));
            expect(await first, 'error');
            expect(await second, 'ok');
            expect(_marker(raw), _latest);
            expect(raw.markers, [_latest]);
          },
        );
      }
    });
  }
}
