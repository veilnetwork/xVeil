import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/kv_log_store.dart';
import 'package:xveil/data/transport/loopback_transport.dart';
import 'package:xveil/domain/chat.dart';
import 'package:xveil/state/device_history_backfill.dart';
import 'package:xveil/state/messaging_core.dart';

NodeId _id(int value) => NodeId(Uint8List.fromList(List.filled(32, value)));

class _HeldDeleteStore extends SyncWrappedAsyncKvLogStore {
  _HeldDeleteStore(super.inner);
  final admitted = Completer<void>();
  final release = Completer<void>();

  @override
  Future<int> commit(List<KvLogOp> ops) async {
    if (ops.whereType<AppendLogOp>().any(
      (op) => (jsonDecode(utf8.decode(op.payload)) as Map)['op'] == 'del',
    )) {
      admitted.complete();
      await release.future;
    }
    return super.commit(ops);
  }
}

void main() {
  final me = _id(1), sibling = _id(3), identity = _id(9), peer = _id(2);
  late FakeKvLogStore backing;
  late HiddenVolumeStorage storage;
  late MessagingService messaging;

  MessagingService service(HiddenVolumeStorage s) =>
      MessagingService(LoopbackTransport(localNodeId: me), s)
        ..selfIdentityHex = (() async => identity.hex)
        ..isOwnDevice = ((id) async => id == sibling || id == identity);

  setUp(() {
    backing = FakeKvLogStore();
    storage = HiddenVolumeStorage.fromStore(backing);
    messaging = service(storage);
  });
  tearDown(() => messaging.dispose());

  Future<void> echo(
    String id,
    int ts, {
    String? author,
    bool file = false,
  }) async {
    await storage.appendMessage(
      Message(
        id: id,
        conversationId: peer.hex,
        direction: MessageDirection.outgoing,
        body: id,
        timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
        author: author ?? identity.hex,
        status: MessageStatus.delivered,
        fileId: file ? 'local-blob' : null,
        fileContentId: file ? 'offered-blob' : null,
        fileName: file ? 'sample.bin' : null,
        fileSize: file ? 1234 : null,
        replyToId: 'quoted',
        forwardedFrom: 'a label',
      ),
    );
  }

  Future<bool> original(String id, int seq, int ts, {String? author}) =>
      messaging.applyMirroredMessage(
        peer: peer,
        msgId: id,
        direction: MessageDirection.outgoing,
        body: 'original mirror must not overwrite current content',
        tsMs: ts,
        author: author ?? sibling.hex,
        seq: seq,
      );

  test(
    'peer echo first, canonical own mirror later repairs causal ordering',
    () async {
      // Receive in reverse order; the original writer's clock moved backwards.
      // Sorting only by timestamps would also fail this causal-order assertion.
      await echo('second', 1000);
      await echo('first', 2000);
      expect((await storage.loadMessages(peer.hex)).map((m) => m.id), [
        'second',
        'first',
      ]);
      expect(await original('first', 1, 2000), isTrue);
      expect(await original('second', 2, 1000), isTrue);
      final rows = await storage.loadMessages(peer.hex);
      expect(rows.map((m) => m.id), ['first', 'second']);
      expect(rows.map((m) => m.orderSeq), [1, 2]);
      expect(rows.every((m) => m.orderAuthor == sibling.hex), isTrue);
      expect(
        rows.map((m) => m.seq),
        [2, 1],
        reason: 'provisional raw bookkeeping is not authentic wire provenance',
      );
      expect(rows.every((m) => m.body == m.id), isTrue);
      expect(await original('first', 1, 2000), isFalse);

      // Backfill propagates canonical order; wire recovery NEVER promotes the
      // contact's echoed body to our or the sibling's authentic send stream.
      final mirror = deviceMirrorOf(peer.hex, rows.first);
      expect(mirror.event.payload['au'], sibling.hex);
      expect(mirror.event.payload['sq'], 1);
      expect(await storage.loadEventsSince(peer.hex, me.hex, 0), isEmpty);
      expect(await storage.loadEventsSince(peer.hex, sibling.hex, 0), isEmpty);
      expect(
        (await storage.conversationSync(peer.hex)).highWater[sibling.hex],
        isNull,
      );

      await storage.scrubDeleted();
      storage = HiddenVolumeStorage.fromStore(backing);
      final cold = await storage.loadMessages(peer.hex);
      expect(cold.map((m) => m.id), ['first', 'second']);
      expect(cold.map((m) => m.ordering), rows.map((m) => m.ordering));
    },
  );

  test(
    'repair preserves current edit, delivery state, file and annotations',
    () async {
      await echo('file', 1000, file: true);
      await storage.editMessage(peer.hex, 'file', 'latest edit', seq: 44);
      await storage.markMessageStatus(peer.hex, 'file', MessageStatus.failed);
      await storage.setReadMarker(peer.hex, 9876);
      expect(await original('file', 7, 1000), isTrue);
      await storage.editMessage(peer.hex, 'file', 'later edit', seq: 45);
      for (final s in [storage, HiddenVolumeStorage.fromStore(backing)]) {
        final row = (await s.loadMessageById(peer.hex, 'file'))!;
        expect(row.body, 'later edit');
        expect(row.edited, isTrue);
        expect(row.status, MessageStatus.failed);
        expect(await s.readMarker(peer.hex), 9876);
        expect(row.fileId, 'local-blob');
        expect(row.fileContentId, 'offered-blob');
        expect(row.fileName, 'sample.bin');
        expect(row.fileSize, 1234);
        expect(row.replyToId, 'quoted');
        expect(row.forwardedFrom, 'a label');
        expect(row.ordering, (author: sibling.hex, seq: 7));
        expect(
          (await s.loadMessageHistory(peer.hex, 'file')).map((v) => v.body),
          containsAll(['file', 'latest edit', 'later edit']),
        );
      }
    },
  );

  test(
    'only an original physical own-device position repairs a provisional echo',
    () async {
      await echo('held', 1000);
      for (final author in [identity.hex, peer.hex, _id(6).hex, 'invalid']) {
        expect(await original('held', 3, 1000, author: author), isFalse);
      }
      expect(
        await messaging.applyMirroredMessage(
          peer: peer,
          msgId: 'held',
          direction: MessageDirection.outgoing,
          body: 'no original sequence',
          tsMs: 1000,
          author: sibling.hex,
        ),
        isFalse,
      );
      expect(await original('held', kMaxWireSeq + 1, 1000), isFalse);
      expect(
        (await storage.loadMessageById(peer.hex, 'held'))!.ordering,
        isNull,
      );
      expect(await original('held', 3, 1000, author: me.hex), isTrue);
      // A later conflicting mirror cannot change a settled origin.
      expect(await original('held', 999, 1000), isFalse);
      expect((await storage.loadMessageById(peer.hex, 'held'))!.ordering, (
        author: me.hex,
        seq: 3,
      ));
    },
  );

  test(
    'authentic outgoing and incoming rows are not provisional echoes',
    () async {
      await echo('own', 1000, author: me.hex);
      await storage.appendMessage(
        Message(
          id: 'incoming',
          conversationId: peer.hex,
          direction: MessageDirection.incoming,
          body: 'received',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
          author: peer.hex,
        ),
      );
      for (final id in ['own', 'incoming']) {
        expect(await original(id, 50, 1000), isFalse);
        expect((await storage.loadMessageById(peer.hex, id))!.ordering, isNull);
      }
    },
  );

  test('deleted echo is not resurrected by a late canonical mirror', () async {
    await echo('gone', 1000);
    await storage.deleteMessage(peer.hex, 'gone');
    expect(await original('gone', 1, 1000), isFalse);
    expect(await storage.loadMessages(peer.hex), isEmpty);
    expect(await storage.isMessageDeleted(peer.hex, 'gone'), isTrue);
  });

  test(
    'legacy echo in the peer slot can adopt our original physical position',
    () async {
      messaging.selfIdentityHex = null;
      await echo('legacy', 1000, author: peer.hex);
      expect(await original('legacy', 8, 1000, author: me.hex), isTrue);
      final row = (await storage.loadMessageById(peer.hex, 'legacy'))!;
      expect(row.ordering, (author: me.hex, seq: 8));
      expect(row.author, peer.hex);
      expect(await storage.loadEventsSince(peer.hex, me.hex, 0), isEmpty);
    },
  );

  test(
    'ordering metadata cannot revive a cleared conversation after reopen',
    () async {
      await echo('cleared', 1000);
      expect(await original('cleared', 1, 1000), isTrue);
      await storage.emitClearConversation(peer, me.hex);
      await storage.scrubDeleted();
      for (final s in [storage, HiddenVolumeStorage.fromStore(backing)]) {
        expect(await s.loadMessages(peer.hex), isEmpty);
        expect(await s.loadMessageById(peer.hex, 'cleared'), isNull);
      }
    },
  );

  test(
    'delete already in flight wins a metadata-only repair, including after scrub',
    () async {
      final heldStore = _HeldDeleteStore(backing);
      storage = HiddenVolumeStorage.fromAsyncStore(heldStore);
      await messaging.dispose();
      messaging = service(storage);
      await echo('race', 1000);
      final deletion = storage.deleteMessage(peer.hex, 'race');
      await heldStore.admitted.future;
      try {
        expect(await original('race', 1, 1000), isTrue);
      } finally {
        heldStore.release.complete();
        await deletion;
      }
      await storage.scrubDeleted();
      for (final s in [storage, HiddenVolumeStorage.fromStore(backing)]) {
        expect(await s.loadMessageById(peer.hex, 'race'), isNull);
        expect(await s.isMessageDeleted(peer.hex, 'race'), isTrue);
        expect(await s.loadMessages(peer.hex), isEmpty);
      }
    },
  );
}
