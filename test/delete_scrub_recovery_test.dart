import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

class _Store extends FakeKvLogStore {
  int scrubAttempts = 0;
  bool refuseScrub = false;
  int closes = 0;
  bool refuseDeletion = false;
  bool refuseMarkerClear = false;

  @override
  int commit(List<KvLogOp> ops) {
    if (refuseDeletion &&
        ops.any(
          (op) =>
              op is AppendLogOp &&
              utf8.decode(op.payload).contains('"op":"del"'),
        )) {
      throw StateError('fixture atomic deletion refusal');
    }
    if (refuseMarkerClear &&
        ops.any(
          (op) =>
              op is DeleteOp &&
              utf8.decode(op.key).startsWith('storage.message_delete_scrub.'),
        )) {
      throw StateError('fixture marker clear refusal');
    }
    return super.commit(ops);
  }

  @override
  void scrub() {
    scrubAttempts++;
    if (refuseScrub) throw StateError('fixture scrub refusal');
    super.scrub();
  }

  @override
  void close() {
    closes++;
    super.close();
  }
}

class _HeldScrub extends SyncWrappedAsyncKvLogStore {
  _HeldScrub(super.inner);
  bool held = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> scrub() async {
    if (held) {
      held = false;
      entered.complete();
      await release.future;
    }
    await super.scrub();
  }
}

void main() {
  final peer = NodeId(Uint8List.fromList(List.filled(32, 2)));
  Future<void> post(HiddenVolumeStorage storage) => storage.appendMessage(
    Message(
      id: 'target',
      conversationId: peer.hex,
      direction: MessageDirection.incoming,
      body: 'fixture body',
      timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
    ),
  );
  HiddenVolumeStorage handle(_Store store) => HiddenVolumeStorage(
    ({required Uint8List password, required bool create}) => store,
    keysOpener: (_) => store,
  );

  test(
    'replayed mirror finishes scrub after the tombstone committed',
    () async {
      final raw = _Store();
      final storage = handle(raw);
      await storage.open(password: 'fixture');
      final messaging = MessagingService(LoopbackTransport(), storage);
      addTearDown(() async {
        await messaging.dispose();
        await storage.close();
      });
      await post(storage);
      raw.refuseScrub = true;
      await messaging.applyMirroredDelete(peer: peer, msgId: 'target');
      expect(raw.scrubAttempts, 1);
      raw.refuseScrub = false;
      await messaging.applyMirroredDelete(peer: peer, msgId: 'target');
      expect(raw.scrubAttempts, 2);
      expect(await storage.loadMessages(peer.hex), isEmpty);
      await messaging.applyMirroredDelete(peer: peer, msgId: 'target');
      expect(
        raw.scrubAttempts,
        2,
        reason: 'clean historical tombstones must not vacuum again',
      );
    },
  );

  test(
    'normal read after tombstone leaves the explicit scrub to its caller',
    () async {
      final raw = _Store();
      final storage = handle(raw);
      await storage.open(password: 'fixture');
      await post(storage);
      await storage.deleteMessage(peer.hex, 'target');
      expect(await storage.loadMessages(peer.hex), isEmpty);
      expect(raw.scrubAttempts, 0);
      await storage.scrubDeleted();
      expect(raw.scrubAttempts, 1);
      await storage.close();
    },
  );

  test(
    'a warm history cache cannot hide a failed scrub from the next read',
    () async {
      final raw = _Store();
      final storage = handle(raw);
      await storage.open(password: 'fixture');
      await post(storage);
      await storage.deleteMessage(peer.hex, 'target');
      expect(await storage.loadMessages(peer.hex), isEmpty);
      raw.refuseScrub = true;
      await expectLater(storage.scrubDeleted(), throwsStateError);
      raw.refuseScrub = false;
      expect(await storage.loadMessages(peer.hex), isEmpty);
      expect(raw.scrubAttempts, 2);
      await storage.close();
    },
  );

  for (final mode in ['password', 'keys', 'view', 'async-view']) {
    test('unfinished deletion resumes through $mode after restart', () async {
      final raw = _Store();
      final first = handle(raw);
      await first.open(password: 'fixture');
      await post(first);
      await first.deleteMessage(peer.hex, 'target');
      // Simulated process stop between the durable tombstone and the vacuum.
      await first.close();
      final recovered = mode == 'view'
          ? HiddenVolumeStorage.fromStore(raw)
          : mode == 'async-view'
          ? HiddenVolumeStorage.fromAsyncStore(SyncWrappedAsyncKvLogStore(raw))
          : handle(raw);
      addTearDown(recovered.close);
      if (mode == 'password') await recovered.open(password: 'fixture');
      if (mode == 'keys') await recovered.openWithKeys(Uint8List(64));
      expect(await recovered.isMessageDeleted(peer.hex, 'target'), isTrue);
      expect(raw.scrubAttempts, 1);
      expect(await recovered.loadMessages(peer.hex), isEmpty);
      expect(raw.scrubAttempts, 1);
    });
  }

  test('failed lazy view recovery stays pending for its next read', () async {
    final raw = _Store();
    final first = handle(raw);
    await first.open(password: 'fixture');
    await post(first);
    await first.deleteMessage(peer.hex, 'target');
    await first.close();
    final view = HiddenVolumeStorage.fromStore(raw);
    raw.refuseScrub = true;
    await expectLater(view.loadMessages(peer.hex), throwsStateError);
    raw.refuseScrub = false;
    expect(await view.loadMessages(peer.hex), isEmpty);
    expect(raw.scrubAttempts, 2);
    await view.close();
  });

  test(
    'failed recovery releases the opened handle and permits retry',
    () async {
      final raw = _Store();
      final first = handle(raw);
      await first.open(password: 'fixture');
      await post(first);
      await first.deleteMessage(peer.hex, 'target');
      await first.close();
      raw.refuseScrub = true;
      final retry = handle(raw);
      await expectLater(retry.open(password: 'fixture'), throwsStateError);
      expect(retry.isOpen, isFalse);
      expect(raw.closes, 2);
      raw.refuseScrub = false;
      expect(await retry.open(password: 'fixture'), isTrue);
      expect(await retry.isMessageDeleted(peer.hex, 'target'), isTrue);
      expect(raw.scrubAttempts, 2);
      await retry.close();
    },
  );

  test(
    'failed tombstone transaction cannot leave a dirty marker alone',
    () async {
      final raw = _Store();
      final first = handle(raw);
      await first.open(password: 'fixture');
      await post(first);
      raw.refuseDeletion = true;
      await expectLater(
        first.deleteMessage(peer.hex, 'target'),
        throwsStateError,
      );
      await first.close();
      raw.refuseDeletion = false;
      final reopened = handle(raw);
      await reopened.open(password: 'fixture');
      expect(
        (await reopened.loadMessages(peer.hex)).single.body,
        'fixture body',
      );
      expect(raw.scrubAttempts, 0);
      await reopened.close();
    },
  );

  test(
    'marker removal failure leaves recovery retryable across restart',
    () async {
      final raw = _Store();
      final first = handle(raw);
      await first.open(password: 'fixture');
      await post(first);
      await first.deleteMessage(peer.hex, 'target');
      raw.refuseMarkerClear = true;
      await expectLater(first.scrubDeleted(), throwsStateError);
      await first.close();
      raw.refuseMarkerClear = false;
      final reopened = handle(raw);
      await reopened.open(password: 'fixture');
      expect(raw.scrubAttempts, 2);
      expect(await reopened.loadMessages(peer.hex), isEmpty);
      await reopened.close();
      final clean = handle(raw);
      await clean.open(password: 'fixture');
      expect(raw.scrubAttempts, 2);
      await clean.close();
    },
  );

  test(
    'concurrent deletion cannot lose its marker behind an older vacuum',
    () async {
      final raw = _Store();
      // Both the held asynchronous view and the reopened handle share raw bytes.
      final held = _HeldScrub(raw);
      final first = HiddenVolumeStorage.fromAsyncStore(held);
      await post(first);
      await first.appendMessage(
        Message(
          id: 'second',
          conversationId: peer.hex,
          direction: MessageDirection.incoming,
          body: 'another fixture body',
          timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
        ),
      );
      await first.deleteMessage(peer.hex, 'target');
      held.held = true;
      final vacuum = first.scrubDeleted();
      await held.entered.future;
      final deleting = first.deleteMessage(peer.hex, 'second');
      held.release.complete();
      await Future.wait([vacuum, deleting]);
      final beforeReopen = raw.scrubAttempts;
      await first.close();
      final reopened = handle(raw);
      await reopened.open(password: 'fixture');
      expect(raw.scrubAttempts, beforeReopen + 1);
      expect(await reopened.loadMessages(peer.hex), isEmpty);
      await reopened.close();
    },
  );
}
