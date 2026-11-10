import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/storage/message_batch_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/messaging.dart';

final _peer = NodeId(Uint8List(32)..fillRange(0, 32, 2));
final _other = NodeId(Uint8List(32)..fillRange(0, 32, 3));
String _shown(String conversation) => 'disap.shown.v1:$conversation';

class _Storage extends HiddenVolumeStorage {
  _Storage(this.first, this.next)
    : super(
        ({required password, required create}) =>
            utf8.decode(password) == 'first' ? first : next,
      );
  final FakeKvLogStore first, next;
  final entered = Completer<void>(), release = Completer<void>();
  bool holdShown = false, failShown = false;

  @override
  Future<String?> getSetting(String key) async {
    final value = await super.getSetting(key);
    if (holdShown && key == _shown(_peer.hex)) {
      holdShown = false;
      entered.complete();
      await release.future;
    }
    return value;
  }

  @override
  Future<void> putSetting(String key, String value) {
    if (failShown && key == _shown(_peer.hex)) {
      failShown = false;
      return Future.error(StateError('fixture shown-clock write refused'));
    }
    return super.putSetting(key, value);
  }
}

String? _raw(FakeKvLogStore store, String key) {
  final value = store.get(Ns.settings, Uint8List.fromList(utf8.encode(key)));
  return value == null ? null : utf8.decode(value);
}

Message _row(NodeId peer, int timestamp) => Message(
  id: 'row-$timestamp',
  conversationId: peer.hex,
  direction: MessageDirection.incoming,
  body: 'fixture body',
  timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
);

MessagingService _service(_Storage storage) => MessagingService(
  LoopbackTransport(localNodeId: NodeId(Uint8List(32)..fillRange(0, 32, 1))),
  storage,
  now: () => DateTime.fromMillisecondsSinceEpoch(60000),
);

void main() {
  test(
    'history admission can read the shown clock while a read mark waits for its scan',
    () {
      fakeAsync((time) {
        final storage = _Storage(FakeKvLogStore(), FakeKvLogStore());
        storage.open(password: 'first');
        time.flushMicrotasks();
        storage.appendMessage(_row(_peer, 1000));
        time.flushMicrotasks();
        storage.upsertContact(
          Contact(
            nodeId: _peer,
            status: ContactStatus.accepted,
            hideAfterReadSeconds: 30,
          ),
        );
        time.flushMicrotasks();
        final service = _service(storage);
        final entered = Completer<void>(), release = Completer<void>();
        List<PreparedMessageWrite>? published;
        storage
            .appendMissingMessageBatch(
              [
                Message(
                  id: 'pending-row',
                  conversationId: _peer.hex,
                  direction: MessageDirection.incoming,
                  body: 'pending history',
                  timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
                  author: _peer.hex,
                  seq: 2,
                  positionVerified: true,
                ),
              ],
              beforeCommit: () async {
                if (!entered.isCompleted) entered.complete();
                await release.future;
                await service.hiddenThroughTs(_peer);
              },
            )
            .then((value) => published = value);
        time.flushMicrotasks();
        expect(entered.isCompleted, isTrue);
        var marked = false;
        service.markRead(_peer.hex).then((_) => marked = true);
        time.flushMicrotasks();
        release.complete();
        time.flushMicrotasks();
        expect(published, [PreparedMessageWrite.appended]);
        expect(marked, isTrue);
        service.dispose();
        time.flushMicrotasks();
        storage.close();
        time.flushMicrotasks();
      });
    },
  );

  test('shown-state read is owned until messaging teardown finishes', () {
    fakeAsync((time) {
      final a = FakeKvLogStore(), b = FakeKvLogStore();
      final storage = _Storage(a, b);
      storage.open(password: 'first');
      time.flushMicrotasks();
      storage.appendMessage(_row(_peer, 1000));
      time.flushMicrotasks();
      final service = _service(storage);
      var notices = 0;
      service.onConversationRead = (_, _) => notices++;
      storage.holdShown = true;
      service.markRead(_peer.hex);
      time.flushMicrotasks();
      expect(storage.entered.isCompleted, isTrue);
      var switched = false;
      service
          .dispose()
          .then((_) => storage.open(password: 'next'))
          .then((ok) => switched = ok);
      time.flushMicrotasks();
      final switchedWhileHeld = switched;
      storage.release.complete();
      time.flushMicrotasks();
      storage.close();
      time.flushMicrotasks();
      expect(switched, isTrue);
      expect(_raw(b, 'set:${_shown(_peer.hex)}'), isNull);
      expect(switchedWhileHeld, isFalse);
      expect(notices, 0, reason: 'a retired owner cannot publish read notices');
    });
  });

  for (final action in ['local', 'mirrored', 'expiry']) {
    test('retired read-state owner refuses $action writes', () async {
      final a = FakeKvLogStore(), b = FakeKvLogStore();
      final storage = _Storage(a, b);
      await storage.open(password: 'first');
      await storage.appendMessage(_row(_peer, 1000));
      await storage.upsertContact(
        Contact(
          nodeId: _peer,
          status: ContactStatus.accepted,
          hideAfterReadSeconds: 30,
        ),
      );
      final clock = jsonEncode({
        'w': 0,
        'e': [
          [1000, 0],
        ],
      });
      await storage.putSetting(_shown(_peer.hex), clock);
      final service = _service(storage);
      await service.dispose();
      if (action == 'local') await service.markRead(_peer.hex);
      if (action == 'mirrored') {
        await service.applyMirroredReadMark(_peer.hex, 3000);
      }
      if (action == 'expiry') expect(await service.hiddenThroughTs(_peer), 0);
      expect(await storage.readMarker(_peer.hex), 0);
      expect(await storage.getSetting(_shown(_peer.hex)), clock);
      await storage.close();
    });
  }

  test(
    'overlapping read visits keep the newest showing and independent chats progress',
    () {
      fakeAsync((time) {
        final a = FakeKvLogStore(), b = FakeKvLogStore();
        final storage = _Storage(a, b);
        storage.open(password: 'first');
        time.flushMicrotasks();
        storage.appendMessage(_row(_peer, 1000));
        time.flushMicrotasks();
        storage.appendMessage(_row(_other, 3000));
        time.flushMicrotasks();
        final service = _service(storage);
        storage.holdShown = true;
        service.markRead(_peer.hex);
        time.flushMicrotasks();
        expect(storage.entered.isCompleted, isTrue);
        storage.appendMessage(_row(_peer, 2000));
        time.flushMicrotasks();
        service.markRead(_peer.hex);
        time.flushMicrotasks();
        var independent = false;
        service.markRead(_other.hex).then((_) => independent = true);
        time.flushMicrotasks();
        expect(independent, isTrue);
        storage.release.complete();
        time.flushMicrotasks();
        final state = jsonDecode(_raw(a, 'set:${_shown(_peer.hex)}')!) as Map;
        expect((state['e'] as List).last[0], 2000);
        service.dispose();
        time.flushMicrotasks();
        storage.close();
        time.flushMicrotasks();
      });
    },
  );

  test(
    'a shown-clock failure does not poison later reads or teardown',
    () async {
      final storage = _Storage(FakeKvLogStore(), FakeKvLogStore());
      await storage.open(password: 'first');
      await storage.appendMessage(_row(_peer, 1000));
      final service = _service(storage);
      storage.failShown = true;
      await service.markRead(_peer.hex);
      await service.markRead(_peer.hex);
      final state =
          jsonDecode((await storage.getSetting(_shown(_peer.hex)))!) as Map;
      expect((state['e'] as List).last[0], 1000);
      await service.dispose();
      await storage.close();
    },
  );
}
